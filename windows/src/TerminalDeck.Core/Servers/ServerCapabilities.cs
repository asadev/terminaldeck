using System.Text.Json;

namespace TerminalDeck.Core.Servers;

public sealed record ServerCodingAi(string Provider, string Name, bool Installed, string Path, string Version, string SignIn,
  bool CanInstall, string? Why, bool CanRemove, bool CanSignIn = true, bool CanSignOut = true);
public sealed record ServerCodingAiAction(string Message, string? SessionId = null);
public sealed record ServerWebsite(string Id, string Name, string Detail, string? Url);
// Only these typed operations cross the keeper session boundary. There is no
// caller-supplied remote command or path to substitute at launch time.
public sealed record ServerCodingTask(string Provider, string Action)
{
  public string? AttemptId { get; init; }
  public void Validate()
  {
    if (AttemptId is not null && (Provider != "claude" || Action != "signin" || !Guid.TryParseExact(AttemptId, "N", out _))) throw new ServerRefusal("Choose a valid private sign-in attempt.");
    if (Provider is not ("claude" or "codex" or "gemini") || Action is not ("install" or "signin" or "signout" or "remove") || Provider == "gemini" && Action == "signout") throw new ServerRefusal("Choose a supported coding AI setup action.");
  }
  public string RemoteCommand()
  {
    Validate();
    var body = Action switch
    {
      "install" => ServerCodingScripts.Install(Provider),
      "remove" => ServerCodingScripts.Remove(Provider),
      _ => AttemptId is { } attempt ? ServerSigninScripts.Login(attempt) : ServerCodingScripts.Login(Provider, Action == "signout")
    };
    // ssh runs this only after authentication. A visible login shell remains
    // available when setup finishes, matching the owning SSH session lifetime.
    return "sh -c " + ServerValidation.Quote(body + "\nresult=$?; printf '\\nSetup finished (exit %s).\\n' \"$result\"; exec \"${SHELL:-/bin/sh}\" -l");
  }
}

public sealed partial class ServerService
{
  public ServerSigninAttempts? SigninAttempts { get; set; }
  public async ValueTask<IReadOnlyList<ServerCodingAi>> CodingAisAsync(string id, ServerCaller caller, CancellationToken ct = default)
  {
    await caller.RecheckAsync(ct); var server = Get(id, caller);
    var output = await RunAsync(server, new("python3 -c " + ServerValidation.Quote(ServerCodingScripts.Inventory), MaxOutputBytes: 65536), ct);
    await caller.RecheckAsync(ct); _ = Get(id, caller);
    try
    {
      if (output.Output.Length > 65536) throw new IOException("The coding AI inventory is too large.");
      var rows = JsonSerializer.Deserialize<ServerCodingAi[]>(output.Output, CapabilityJson) ?? throw new IOException("The coding AI inventory is unreadable.");
      if (rows.Length != 3 || rows.Select(r => r?.Provider).Distinct().Count() != 3) throw new IOException("The coding AI inventory is incomplete.");
      foreach (var row in rows)
      {
        if (row is null || row.Name is null || row.Path is null || row.Version is null || row.Provider is not ("claude" or "codex" or "gemini") || row.SignIn is not ("yes" or "no" or "unknown") || row.Name.Length > 80 || row.Path.Length > 4096 || row.Version.Length > 200 || row.Why?.Length > 1000 || row.Path.Any(char.IsControl) || row.Installed && !row.Path.StartsWith('/')) throw new IOException("The coding AI inventory is unreadable.");
      }
      return rows.Select(row => row with { Version = ServerText.Mask(row.Version) }).ToArray();
    }
    catch (JsonException) { throw new IOException("The coding AI inventory is unreadable."); }
  }
  public async ValueTask<ServerCodingAiAction> ChangeCodingAiAsync(string id, string provider, string action, ServerCaller caller, CancellationToken ct = default)
  {
    var task = new ServerCodingTask(provider, action) { AttemptId = provider == "claude" && action == "signin" && SigninAttempts is not null ? Guid.NewGuid().ToString("N") : null }; task.Validate();
    ServerValidation.CanChange(Get(id, caller), caller);
    if (terminal?.SupportsCodingTasks != true) throw new ServerRefusal("Connect the server terminal before setting up a coding AI.");
    var row = (await CodingAisAsync(id, caller, ct)).Single(r => r.Provider == provider);
    void Offered(ServerCodingAi current)
    {
      if (action == "install" ? !current.CanInstall : !current.Installed || action == "remove" && !current.CanRemove || action == "signin" && !current.CanSignIn || action == "signout" && !current.CanSignOut)
        throw new ServerRefusal(current.Why ?? "That coding AI setup action is not available. Refresh this server.");
    }
    Offered(row); string? session = null;
    await ChangeAsync(id, caller, action + " coding AI", row.Name + " in this SSH user's home folder; credentials stay on the server. A visible SSH terminal runs the fixed provider command.", false, action == "remove", async current =>
    {
      var fresh = (await CodingAisAsync(id, caller, ct)).Single(r => r.Provider == provider); Offered(fresh);
      if (fresh.Path != row.Path || fresh.Installed != row.Installed || fresh.Version != row.Version) throw new ServerRefusal("This coding AI changed while approval was open. Refresh the server.");
      await caller.RecheckAsync(ct);
      session = await terminal.OpenAsync(new(current) { CodingTask = task }, ct);
    }, ct);
    if (task.AttemptId is not null && session is not null) SigninAttempts?.Start(new(Get(id, caller), task, session, caller));
    return new((task.AttemptId is not null ? "Claude sign-in is starting. Its private callback opens your browser when ready; the server terminal remains available for manual sign-in." : action == "signin" ? provider == "codex" ? "Open the Codex device address printed in the server terminal and enter its one-time code." : "Finish signing in in the server terminal: open the address it prints and enter the code it requests." : "Continue " + action + " for " + row.Name + " in the server terminal.") + " Refresh Coding AIs when it finishes.", session);
  }
  public async ValueTask<IReadOnlyList<ServerWebsite>> WebsitesAsync(string id, ServerCaller caller, CancellationToken ct = default)
  {
    await caller.RecheckAsync(ct); var server = Get(id, caller);
    var output = await RunAsync(server, new("python3 -c " + ServerValidation.Quote(ServerWebsiteScripts.Inventory), MaxOutputBytes: 65536), ct);
    await caller.RecheckAsync(ct); _ = Get(id, caller);
    try
    {
      if (output.Output.Length > 65536) throw new IOException("The website inventory is too large.");
      var rows = JsonSerializer.Deserialize<ServerWebsite[]>(output.Output, CapabilityJson) ?? throw new IOException("The website inventory is unreadable.");
      if (rows.Length > 100 || rows.Select(r => r?.Id).Distinct().Count() != rows.Length) throw new IOException("The website inventory is too large or duplicated.");
      foreach (var row in rows)
      {
        if (row is null || row.Name is null || row.Detail is null || row.Name.Length is < 1 or > 253 || row.Id != "site:" + row.Name || row.Detail.Length > 300 || row.Name.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('.' or '-' or '*')) || row.Url is not null && (!Uri.TryCreate(row.Url, UriKind.Absolute, out var address) || address.Scheme is not ("http" or "https") || !string.Equals(address.Host, row.Name, StringComparison.OrdinalIgnoreCase) || address.UserInfo.Length > 0 || address.Query.Length > 0 || address.Fragment.Length > 0 || !address.IsDefaultPort || address.AbsolutePath != "/")) throw new IOException("The website inventory returned an invalid address.");
      }
      return rows;
    }
    catch (JsonException) { throw new IOException("The website inventory is unreadable."); }
  }
  public async ValueTask<ServerWebsite> WebsiteAsync(string id, string siteId, ServerCaller caller, CancellationToken ct = default) =>
    (await WebsitesAsync(id, caller, ct)).SingleOrDefault(s => s.Id == siteId) ?? throw new ServerRefusal("That website is no longer in this server's current inventory.");
  private static readonly JsonSerializerOptions CapabilityJson = new() { PropertyNameCaseInsensitive = true };
}
