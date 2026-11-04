using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

public sealed class WindowsProviderLaunchPlanner(AppDataRoot root, string toolsDirectory)
{
  public static string? FindPowerShell7(IReadOnlyDictionary<string, string> environment)
  {
    var folders = environment.TryGetValue("PATH", out var path) ? path.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Where(Path.IsPathFullyQualified) : [];
    return folders.Append(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7")).Select(folder => Path.Combine(folder, "pwsh.exe")).FirstOrDefault(File.Exists);
  }
  public ProcessLaunch Plan(SessionRecord session, bool resume)
  {
    var definition = session.Definition; definition.Validate();
    if (!Directory.Exists(definition.Cwd)) throw new ArgumentException("Choose an existing working folder.");
    var environment = Accounts.WindowsAiEnvironment.Read();
    if (CustomTerminalProviders.IsKey(definition.Provider))
    {
      var custom = WindowsCustomTerminalProviders.Open(root).Plan(definition, environment);
      var customEnvironment = new Dictionary<string, string>(custom.Environment, StringComparer.OrdinalIgnoreCase);
      foreach (var pair in ProjectMcpEnvironment.Read(root, definition.Cwd)) customEnvironment[pair.Key] = pair.Value;
      customEnvironment["DECK_SESSION_ID"] = definition.Id;
      return custom with { Environment = customEnvironment };
    }
    if (definition.Provider == "shell")
    {
      var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
      var executable = definition.Shell switch
      {
        TerminalShells.CommandPrompt => Path.Combine(system, "cmd.exe"),
        TerminalShells.PowerShell7 => FindPowerShell7(environment) ?? throw new ArgumentException("PowerShell 7 is not installed. Choose another shell in Settings → General."),
        _ => Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe")
      };
      return new(executable, definition.Shell == TerminalShells.CommandPrompt ? [] : ["-NoLogo", "-NoProfile"], environment, definition.Cwd);
    }
    if (definition.AccountId is null || !Guid.TryParseExact(definition.AccountId, "N", out _))
      throw new ArgumentException("Choose an isolated account before starting this AI.");
    // Core keeps a stable account row while deduplicating a newly signed-in
    // home. Resolve that opaque HomeId, not the surviving account row id.
    var homeId = definition.AccountHome ?? definition.AccountId;
    if (!Guid.TryParseExact(homeId, "N", out _)) throw new ArgumentException("Choose an account home belonging to this app.");
    var home = AccountHome(definition.Provider, homeId);
    if (homeId != TerminalDeck.Core.Accounts.AccountHomes.ExistingLogin) WindowsPrivateDirectory.Ensure(home);
    // Do not allow inherited API keys or config pointers to cross account homes.
    environment = TerminalDeck.Core.Accounts.AccountEnvironment.Apply(definition.Provider, home, environment);
    // An API-key account adds its own key (from Windows Credential Manager) and endpoint.
    var api = Accounts.WindowsApiAccountLaunch.Apply(root, definition.Provider, homeId, environment);
    environment = new Dictionary<string, string>(api.Environment, StringComparer.OrdinalIgnoreCase);
    foreach (var (name, value) in ProjectMcpEnvironment.Read(root, definition.Cwd)) environment[name] = value;
    environment["DECK_SESSION_ID"] = definition.Id;
    var arguments = new List<string>(api.Arguments);
    if (definition.Purpose == "sign-in")
    {
      if (definition.Provider == "claude") arguments.AddRange(["auth", "login"]);
      else if (definition.Provider == "codex") arguments.Add("login");
    }
    if (resume)
    {
      var conversation = definition.ConversationId ?? throw new ArgumentException("This conversation cannot be resumed without its saved identity.");
      if (definition.Provider == "codex") arguments.Add("resume"); else arguments.Add("--resume");
      arguments.Add(conversation);
    }
    // A new Claude conversation this app named (the keeper saves it), so a restart resumes it.
    else if (definition.Provider == "claude" && definition.Purpose is null && definition.ConversationId is { } declared && Guid.TryParse(declared, out _))
      arguments.AddRange(["--session-id", declared]);
    // A launch with no model of its own uses the app-wide choice (Opus 5.5 · Extra high
    // out of the box). Sign-in runs carry no model at all.
    if (definition.Purpose is null && definition.Model is null)
    {
      var (model, effort) = TerminalDeck.Core.Settings.LaunchDefaults.For(definition.Provider, root);
      definition = definition with { Model = model.Length > 0 ? model : null, Effort = definition.Effort ?? effort };
    }
    if (definition.Model is not null) arguments.AddRange(["--model", definition.Model]);
    if (definition.Effort is not null)
    {
      if (definition.Provider == "codex") arguments.InsertRange(0, ["-c", "model_reasoning_effort=\"" + definition.Effort + "\""]);
      else if (definition.Provider == "claude") arguments.AddRange(["--effort", definition.Effort]);
      else throw new ArgumentException("This AI does not expose an effort switch here.");
    }
    if (definition.Permission is not null)
    {
      if (definition.Provider == "claude") arguments.AddRange(["--permission-mode", definition.Permission switch { "plan" => "plan", "auto" => "auto", "acceptEdits" => "acceptEdits", "bypass" => "bypassPermissions", _ => "default" }]);
      else if (definition.Provider == "codex") arguments.InsertRange(0, ["--ask-for-approval", definition.Permission switch { "auto" => "on-request", "acceptEdits" or "bypass" => "never", _ => "untrusted" },
        "--sandbox", definition.Permission switch { "plan" => "read-only", "bypass" => "danger-full-access", _ => "workspace-write" }]);
      else arguments.AddRange(["--approval-mode", definition.Permission switch { "plan" => "plan", "auto" or "acceptEdits" => "auto_edit", "bypass" => "yolo", _ => "default" }]);
    }
    if (definition.Provider == "claude" && definition.Purpose != "sign-in") arguments.InsertRange(0, ExtraFolderArguments(definition.Cwd));
    if (definition.InitialPrompt is not null && !resume) arguments.Add(definition.InitialPrompt);
    return Resolve(definition.Provider, arguments, environment, definition.Cwd);
  }
  public ProcessLaunch Resolve(string provider, IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string> environment, string cwd)
  {
    // Codex's OS credential backend can be shared across homes. Pin this child
    // to the selected home's auth.json for status, sign-in and normal sessions.
    if (provider == "codex" && !UsesExistingLogin(provider, environment)) arguments = new[] { "-c", "cli_auth_credentials_store=\"file\"" }.Concat(arguments).ToArray();
    var fresh = Accounts.WindowsAiEnvironment.Read();
    var launchEnvironment = new Dictionary<string, string>(environment, StringComparer.OrdinalIgnoreCase) { ["PATH"] = fresh["PATH"] };
    var search = Accounts.WindowsAiEnvironment.Search(toolsDirectory, fresh);
    (string Executable, string[] Prefix) resolved;
    // An explicit app-owned tools tree (also used by isolated fixtures) wins
    // before normal discovery. Never accidentally replace a fixture with a real CLI.
    try { resolved = InstalledAiResolver.Resolve(provider, new([toolsDirectory], [Path.Combine(toolsDirectory, "node_modules")], search.NodeDirectories)); }
    catch (IOException) { resolved = InstalledAiResolver.Resolve(provider, search); }
    return new(resolved.Executable, resolved.Prefix.Concat(arguments).ToArray(), launchEnvironment, cwd);
  }
  // A project's other folders (the home folder holds the team's .claude): Claude
  // loads their skills and may work in them. "--add-dir=" keeps the variadic option
  // from swallowing a following prompt.
  public IReadOnlyList<string> ExtraFolderArguments(string cwd) =>
    TerminalDeck.Core.Projects.ProjectStartFolders.ExtraFolders(root, cwd).Select(f => f.Replace('/', '\\')).Where(Directory.Exists).Select(f => "--add-dir=" + f).ToArray();
  public string AccountHome(string provider, string homeId) => TerminalDeck.Core.Accounts.AccountHomes.Resolve(root, provider, homeId,
    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), StableChannel.IsStable(AppContext.BaseDirectory));
  private bool UsesExistingLogin(string provider, IReadOnlyDictionary<string, string> environment) =>
    StableChannel.IsStable(AppContext.BaseDirectory) && environment.GetValueOrDefault("CODEX_HOME") == AccountHome(provider, TerminalDeck.Core.Accounts.AccountHomes.ExistingLogin);
  public static string BundledToolsDirectory => Path.Combine(AppContext.BaseDirectory, "ai");
}
