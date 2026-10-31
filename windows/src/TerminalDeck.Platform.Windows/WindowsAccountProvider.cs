using System.Diagnostics;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

// Test/additional accounts use explicit private homes. Only stable Default may
// follow the user’s existing CLI home. Credential contents are never logged.
public sealed class WindowsAccountProvider(string provider, AppDataRoot root, string toolsDirectory,
  Func<AccountProfile, string, Task> signIn, TerminalDeck.Platform.Windows.Accounts.IGeminiAccountReadiness? geminiReadiness = null) : IAccountProvider, IAccountSignInEvents, IAccountInstallation, IDisposable
{
  private readonly Accounts.WindowsSignInWatch signIns = new();
  public event Func<string, CancellationToken, ValueTask>? SignInCompleted;
  public string Provider => provider;
  public async ValueTask<ProviderInstallation> InstallationAsync(AccountProfile account, CancellationToken ct)
  {
    var planner = new WindowsProviderLaunchPlanner(root, toolsDirectory);
    ProcessLaunch launch;
    try
    {
      var isolated = planner.Plan(new(new(Guid.NewGuid().ToString(), provider, root.DirectoryPath, "Installation status", account.Id, account.HomeId), "installation-status", SessionState.Starting), false);
      launch = planner.Resolve(provider, ["--version"], isolated.Environment, root.DirectoryPath);
    }
    catch (TerminalDeck.Core.Platform.ProviderUnavailableException) { return new(false, null, DateTimeOffset.UtcNow, "Not installed. Install this AI’s Windows CLI, then read installation again."); }
    try
    {
      var result = await RunAsync(launch, ct);
      var version = System.Text.RegularExpressions.Regex.Match(result.Output, @"\b\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?\b");
      return new(true, result.Code == 0 && version.Success ? version.Value : null, DateTimeOffset.UtcNow,
        result.Code == 0 && version.Success ? "Installed. Sign-in readiness is shown for each account below." : "Installed, but the version could not be read. Try again.");
    }
    catch (Exception ex) when (ex is IOException or System.ComponentModel.Win32Exception or OperationCanceledException && !ct.IsCancellationRequested)
    { return new(true, null, DateTimeOffset.UtcNow, "Installed, but the version check could not finish. Try again."); }
  }
  public async ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct)
  {
    if (!Guid.TryParseExact(account.HomeId, "N", out _) || account.Provider != provider) throw new ArgumentException("Choose an account belonging to this AI.");
    var home = new WindowsProviderLaunchPlanner(root, toolsDirectory).AccountHome(provider, account.HomeId);
    if (account.HomeId != AccountHomes.ExistingLogin) WindowsPrivateDirectory.Ensure(home);
    if (provider == "gemini")
    {
      var config = Path.Combine(home, ".gemini");
      var tokens = ReadObject(Path.Combine(config, "oauth_creds.json"));
      var accounts = ReadObject(Path.Combine(config, "google_accounts.json"));
      if (tokens is null || accounts is null || !HasText(tokens.Value, "refresh_token") && !HasText(tokens.Value, "access_token")) return new(false, null);
      var settings = ReadObject(Path.Combine(config, "settings.json"));
      // authenticate changes provider auth type, which would discard a different
      // login. A Google account status check must never switch authentication.
      if (settings is { } saved && saved.TryGetProperty("security", out var security) && security.ValueKind == JsonValueKind.Object &&
          security.TryGetProperty("auth", out var authSettings) && authSettings.ValueKind == JsonValueKind.Object &&
          authSettings.TryGetProperty("selectedType", out var selected) && selected.ValueKind == JsonValueKind.String &&
          selected.GetString() is { Length: > 0 } method && method != "oauth-personal") return new(false, null);
      var probePlanner = new WindowsProviderLaunchPlanner(root, toolsDirectory);
      var isolated = probePlanner.Plan(new(new(Guid.NewGuid().ToString(), provider, home, "Account status", account.Id, account.HomeId), "status", SessionState.Starting), false);
      var probe = probePlanner.Resolve(provider, ["--acp"], isolated.Environment, home);
      if (!await (geminiReadiness ?? new TerminalDeck.Platform.Windows.Accounts.GeminiAccountReadiness()).VerifyAsync(probe, ct)) return new(false, null);
      // The provider may have refreshed both files. Only its verified account is
      // used for the label; the access-token timestamp is never a sign-out test.
      accounts = ReadObject(Path.Combine(config, "google_accounts.json"));
      var email = accounts is { } verified && verified.TryGetProperty("active", out var active) && active.ValueKind == JsonValueKind.String ? active.GetString() : null;

      return new(!string.IsNullOrWhiteSpace(email), email);
    }
    var planner = new WindowsProviderLaunchPlanner(root, toolsDirectory);
    var launch = planner.Plan(new(new(Guid.NewGuid().ToString(), provider, root.DirectoryPath, "Account status", account.Id, account.HomeId), "status", SessionState.Starting), false);
    launch = planner.Resolve(provider, provider == "claude" ? ["auth", "status", "--json"] : ["login", "status"], launch.Environment, launch.WorkingDirectory);
    var result = await RunAsync(launch, ct);
    if (result.Code != 0) return new(false, null);
    if (provider == "claude")
    {
      try
      {
        using var status = JsonDocument.Parse(result.Output);
        var data = status.RootElement;
        var email = data.TryGetProperty("email", out var address) ? address.GetString() : null;
        var plan = data.TryGetProperty("subscriptionType", out var subscription) && subscription.ValueKind == JsonValueKind.String ? subscription.GetString() : null;
        return new(data.TryGetProperty("loggedIn", out var signed) && signed.GetBoolean() && !string.IsNullOrWhiteSpace(email), email, plan);
      }
      catch (JsonException) { return new(false, null); }
    }
    if (!(result.Output + result.Error).Contains("Logged in using ChatGPT", StringComparison.OrdinalIgnoreCase)) return new(false, null);
    var accountLaunch = planner.Resolve(provider, ["app-server"], launch.Environment, launch.WorkingDirectory);
    var identities = await Accounts.WindowsModelDiscovery.DiscoverAsync(provider, accountLaunch, ct, accountOnly: true);
    var identity = identities.FirstOrDefault(i => i.Id == "account");
    return new(identity is not null, identity?.Name, identities.FirstOrDefault(i => i.Id == "plan")?.Name);
  }
  private static bool HasText(JsonElement value, string name) => value.ValueKind == JsonValueKind.Object &&
    value.TryGetProperty(name, out var part) && part.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(part.GetString());
  private static JsonElement? ReadObject(string path)
  {
    if (!File.Exists(path)) return null;
    if (new FileInfo(path).Length > 256 * 1024 || File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint)) throw new IOException("The isolated account status file could not be read safely.");
    try { using var document = JsonDocument.Parse(File.ReadAllBytes(path)); return document.RootElement.ValueKind == JsonValueKind.Object ? document.RootElement.Clone() : null; }
    catch (JsonException) { return null; }
  }
  private static async Task<(int Code, string Output, string Error)> RunAsync(ProcessLaunch launch, CancellationToken ct)
  {
    var start = new ProcessStartInfo(launch.Executable) { WorkingDirectory = launch.WorkingDirectory, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
    foreach (var argument in launch.Arguments) start.ArgumentList.Add(argument);
    start.Environment.Clear(); foreach (var (name, value) in launch.Environment) start.Environment[name] = value;
    using var process = Process.Start(start) ?? throw new IOException("This AI's status command could not start.");
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(20));
    async Task<string> ReadAsync(StreamReader reader)
    {
      var output = new StringBuilder(); var buffer = new char[2048]; int count;
      while ((count = await reader.ReadAsync(buffer.AsMemory(), deadline.Token)) != 0)
      { if (output.Length + count > 256 * 1024) throw new IOException("This AI's status reply is too large."); output.Append(buffer, 0, count); }
      return output.ToString();
    }
    try
    {
      var output = ReadAsync(process.StandardOutput); var error = ReadAsync(process.StandardError);
      await process.WaitForExitAsync(deadline.Token);
      return (process.ExitCode, await output, await error);
    }
    finally { if (!process.HasExited) process.Kill(entireProcessTree: true); }
  }
  public async ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct)
  {
    if (account.Provider != provider || !Guid.TryParseExact(account.HomeId, "N", out _)) throw new ArgumentException("Choose an isolated account for this AI.");
    var home = new WindowsProviderLaunchPlanner(root, toolsDirectory).AccountHome(provider, account.HomeId); if (account.HomeId != AccountHomes.ExistingLogin) WindowsPrivateDirectory.Ensure(home);
    if (provider == "gemini" && (await StatusAsync(account, ct)).SignedIn)
    {
      // Gemini signs in through its normal terminal. An already-ready home
      // would open an idle prompt instead of a login, so keep its verified login.
      if (SignInCompleted is { } readyHandlers)
        foreach (var handler in readyHandlers.GetInvocationList().Cast<Func<string, CancellationToken, ValueTask>>()) await handler(account.Id, ct);
      return;
    }
    Directory.CreateDirectory(home);
    var watch = signIns.Begin(account.Id, provider == "gemini" ? Path.Combine(home, ".gemini") : home, async () =>
    {
      using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(70));
      if (!(await StatusAsync(account, deadline.Token)).SignedIn) return false;
      if (SignInCompleted is { } handlers)
        foreach (var handler in handlers.GetInvocationList().Cast<Func<string, CancellationToken, ValueTask>>()) await handler(account.Id, deadline.Token);
      return true;
    });
    try
    {
      ct.ThrowIfCancellationRequested(); await signIn(account, home);
      if (SignInCompleted is { } handlers)
        foreach (var handler in handlers.GetInvocationList().Cast<Func<string, CancellationToken, ValueTask>>()) await handler(account.Id, ct);
    }
    finally { watch.Dispose(); }
  }
  public void Dispose() => signIns.Dispose();
  public async ValueTask SignOutAsync(AccountProfile account, CancellationToken ct)
  {
    if (account.Provider != provider || !Guid.TryParseExact(account.HomeId, "N", out _)) throw new ArgumentException("Choose an isolated account.");
    var home = new WindowsProviderLaunchPlanner(root, toolsDirectory).AccountHome(provider, account.HomeId);
    if (provider == "gemini")
    {
      foreach (var name in new[] { "oauth_creds.json", "google_accounts.json" })
      {
        var path = Path.Combine(home, ".gemini", name); _ = ReadObject(path);
        if (File.Exists(path)) File.Delete(path);
      }
      return;
    }
    var planner = new WindowsProviderLaunchPlanner(root, toolsDirectory);
    var launch = planner.Plan(new(new(Guid.NewGuid().ToString(), provider, root.DirectoryPath, "Sign out", account.Id, account.HomeId), "sign-out", SessionState.Starting), false);
    launch = planner.Resolve(provider, provider == "claude" ? ["auth", "logout"] : ["logout"], launch.Environment, launch.WorkingDirectory);
    if ((await RunAsync(launch, ct)).Code != 0) throw new IOException("The provider could not finish signing out. Refresh the account before trying again.");
  }
  public async ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct)
  {
    if (account.Provider != provider || !Guid.TryParseExact(account.HomeId, "N", out _)) throw new ArgumentException("Choose an isolated account for this AI.");
    var planner = new WindowsProviderLaunchPlanner(root, toolsDirectory);
    var home = new WindowsProviderLaunchPlanner(root, toolsDirectory).AccountHome(provider, account.HomeId);
    if (account.HomeId != AccountHomes.ExistingLogin) WindowsPrivateDirectory.Ensure(home);
    var launch = planner.Plan(new(new(Guid.NewGuid().ToString(), provider, home, "Check models", account.Id, account.HomeId), "models", SessionState.Starting), false);
    launch = planner.Resolve(provider, Accounts.WindowsModelDiscovery.Arguments(provider), launch.Environment, home);
    var models = await Accounts.WindowsModelDiscovery.DiscoverAsync(provider, launch, ct);
    return provider == "codex" ? Accounts.WindowsModelDiscovery.WithCodexCapacities(models, home) : models;
  }
}
