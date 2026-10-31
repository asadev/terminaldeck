using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Mcp;

public interface IDeckSessionStarter
{
  // Implements the entire sessions.start contract, including briefs and precise resume.
  ValueTask<SessionDefinition> PrepareAsync(JsonElement arguments, AccountProfile? account, CancellationToken cancellationToken);
}
public interface IAccountHomeRemoval
{
  ValueTask DeleteAsync(AccountProfile account, CancellationToken cancellationToken);
}
public sealed record DeckDevice(string Id, string Name, string Platform, string State);
public interface IDeckDeviceDirectory { IReadOnlyList<DeckDevice> Read(); }

public static class DeckCoreTools
{
  public static void RegisterSessions(McpDoor door, SessionKeeper keeper, AccountService accounts, IDeckSessionStarter? starter = null)
  {
    door.Register("sessions.list", (c, a, ct) => Result(keeper.List().Where(s => c.Has("sessions", s.Definition.Id) && (Text(a, "cwd") is not { } folder || s.Definition.Cwd == folder)).Select(View)));
    door.Register("sessions.get", (c, a, ct) => { var id = Required(a, "sessionId"); c.Require("sessions", id); return Result(View(keeper.Get(id))); });
    door.Register("sessions.screen", (c, a, ct) => { var id = Required(a, "sessionId"); c.Require("sessions", id); return Result(new { screen = keeper.Get(id).Replay, source = "terminal-replay", partial = true }); });
    door.Register("sessions.rename", async (c, a, ct) =>
    {
      var id = Required(a, "sessionId"); c.Require("sessions", id); await c.EnsureCurrentAsync(ct);
      await keeper.RenameAsync(id, Required(a, "title", empty: true), ct); return JsonSerializer.SerializeToElement(new { renamed = true });
    });
    door.Register("sessions.send", async (c, a, ct) =>
    {
      var id = Required(a, "sessionId"); c.Require("sessions", id); var text = Required(a, "text", empty: true);
      if (text.Length > 4000 || text.Any(char.IsControl)) throw new McpRefusal("Use at most 4000 printable characters. Use sessions.keys for control keys.");
      var bytes = Encoding.UTF8.GetBytes(text + (a.TryGetProperty("submit", out var submit) && !submit.GetBoolean() ? "" : "\r"));
      await c.EnsureCurrentAsync(ct); await keeper.WriteAsync(id, keeper.Instance, bytes, ct);
      return JsonSerializer.SerializeToElement(new { sentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() });
    });
    door.Register("sessions.keys", async (c, a, ct) =>
    {
      var id = Required(a, "sessionId"); c.Require("sessions", id);
      var keys = a.GetProperty("keys").EnumerateArray().Select(k => k.GetString()!).ToArray();
      if (keys.Length > 100) throw new McpRefusal("Send at most 100 keys at a time.");
      var bytes = Encoding.UTF8.GetBytes(string.Concat(keys.Select(Key)));
      await c.EnsureCurrentAsync(ct); await keeper.WriteAsync(id, keeper.Instance, bytes, ct);
      return JsonSerializer.SerializeToElement(new { sentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() });
    });
    door.Register("sessions.stop", async (c, a, ct) =>
    {
      var id = Required(a, "sessionId"); c.Require("sessions", id); await c.EnsureCurrentAsync(ct);
      await keeper.StopAsync(id, keeper.Instance, ct); return JsonSerializer.SerializeToElement(new { stopped = true });
    });
    if (starter is not null) door.Register("sessions.start", async (c, a, ct) =>
    {
      var folder = Required(a, "cwd"); c.Require("folders", folder);
      var provider = Text(a, "provider") ?? "claude"; var accountName = Text(a, "account");
      AccountProfile? account = accountName is null ? provider == "shell" ? null : accounts.Preferred(provider, folder) : accounts.Get(accountName);
      if (account is not null) { c.Require("accounts", account.Id); account = await accounts.RequireSignedInAsync(account.Id, ct); }
      if (provider != "shell" && account is null) throw new McpRefusal("Choose a signed-in account before starting this session.");
      var definition = await starter.PrepareAsync(a, account, ct);
      if (definition.Cwd != folder || account is not null && (definition.AccountId != account.Id || definition.AccountHome != account.HomeId || definition.Provider != account.Provider))
        throw new McpRefusal("The session launch did not match the chosen folder and account.");
      await c.EnsureCurrentAsync(ct); var row = await keeper.CreateAsync(definition, ct); c.NoteStarted(row.Definition.Id);
      return JsonSerializer.SerializeToElement(View(row));
    });
  }
  public static void RegisterAccounts(McpDoor door, AccountService accounts, SessionKeeper keeper, IAccountHomeRemoval? files = null)
  {
    door.Register("accounts.list", (c, a, ct) => Result(accounts.List(Text(a, "agent")).Where(p => c.Has("accounts", p.Id)).Select(AccountView)));
    door.Register("accounts.status", async (c, a, ct) =>
    {
      var id = Required(a, "accountId"); c.Require("accounts", id);
      var row = a.TryGetProperty("refresh", out var refresh) && refresh.GetBoolean() ? await accounts.RefreshAsync(id, ct) : accounts.Get(id);
      if (a.TryGetProperty("installation", out var installation) && installation.GetBoolean()) return JsonSerializer.SerializeToElement(new { account = AccountView(row), installation = await accounts.InstallationAsync(id, ct) });
      return JsonSerializer.SerializeToElement(AccountView(row));
    });
    door.Register("accounts.create", async (c, a, ct) =>
    {
      c.Require("settings", "accounts"); await c.EnsureCurrentAsync(ct);
      return JsonSerializer.SerializeToElement(AccountView(await accounts.CreateAsync(Text(a, "agent") ?? "claude", Required(a, "name"), cancellationToken: ct)));
    });
    door.Register("accounts.rename", async (c, a, ct) =>
    {
      var id = Required(a, "accountId"); c.Require("accounts", id); await c.EnsureCurrentAsync(ct); await accounts.RenameAsync(id, Required(a, "name"), ct); return JsonSerializer.SerializeToElement(new { renamed = true });
    });
    door.Register("accounts.sign_in", async (c, a, ct) =>
    {
      var id = Required(a, "accountId"); var folder = Required(a, "folder"); c.Require("accounts", id); c.Require("folders", folder); await c.EnsureCurrentAsync(ct);
      try { await accounts.SignInAsync(id, folder, ct); } catch (SignInCancelledException) { return JsonSerializer.SerializeToElement(new { cancelled = true }); } return JsonSerializer.SerializeToElement(new { account = AccountView(accounts.Get(id)), message = accounts.Get(id).SignedIn ? "Signed in." : "Not signed in. Your conversation and draft are kept." });
    });
    door.Register("accounts.sign_out", async (c, a, ct) =>
    {
      var id = Required(a, "accountId"); c.Require("accounts", id); await c.EnsureCurrentAsync(ct); await accounts.SignOutAsync(id, ct); return JsonSerializer.SerializeToElement(new { signedOut = true });
    });
    door.Register("accounts.share_history", async (c, a, ct) =>
    {
      var id = Required(a, "accountId"); c.Require("accounts", id); await c.EnsureCurrentAsync(ct); await accounts.ShareHistoryAsync(id, a.GetProperty("share").GetBoolean(), ct); return JsonSerializer.SerializeToElement(new { saved = true });
    });
    door.Register("accounts.set_default", async (c, a, ct) =>
    {
      c.Require("settings", "accounts"); var id = Text(a, "accountId"); var folder = Text(a, "projectPath");
      if (folder is not null) c.Require("folders", folder);
      if (id is null)
      {
        foreach (var provider in new[] { "claude", "codex", "gemini" }) { await c.EnsureCurrentAsync(ct); await accounts.SetDefaultAsync(provider, null, folder, ct); }
      }
      else { c.Require("accounts", id); var row = accounts.Get(id); await c.EnsureCurrentAsync(ct); await accounts.SetDefaultAsync(row.Provider, row.Id, folder, ct); }
      return JsonSerializer.SerializeToElement(new { saved = true });
    });
    // File deletion is advertised only when the complete file-lifetime adapter is present.
    if (files is not null) door.Register("accounts.delete", async (c, a, ct) =>
    {
      var id = Required(a, "accountId"); c.Require("accounts", id); var row = accounts.Get(id);
      if (keeper.List().Any(s => s.Definition.AccountId == row.Id && s.State != SessionState.Exited)) throw new McpRefusal("This account is still used by a session. Switch that session first.");
      await c.EnsureCurrentAsync(ct);
      if (a.TryGetProperty("deleteFiles", out var delete) && delete.GetBoolean()) await files.DeleteAsync(row, ct);
      await accounts.DeleteAsync(row.Id, account => keeper.List().Any(s => s.Definition.AccountId == account && s.State != SessionState.Exited), ct);
      return JsonSerializer.SerializeToElement(new { deleted = true });
    });
    door.Register("agents.models", async (c, a, ct) =>
    {
      var id = Required(a, "sessionId"); c.Require("sessions", id); var row = keeper.Get(id);
      if (row.Definition.AccountId is not { } account) throw new McpRefusal("This session has no AI account or model list.");
      c.Require("accounts", account); return JsonSerializer.SerializeToElement(await accounts.ModelsAsync(account, cancellationToken: ct));
    });
  }
  public static void RegisterDeviceReads(McpDoor door, DeviceTrust trust, IDeckDeviceDirectory devices)
  {
    door.Register("devices.list", (c, a, ct) => Result(devices.Read().Where(d => c.Has("devices", d.Id))));
    door.Register("remote.status", (c, a, ct) =>
    {
      c.Require("settings", "remote");
      return Result(new { devices = trust.List().Where(d => c.Has("devices", d.Id)), pairingOpen = trust.Pairing.IsOpen, service = "not-started", tailscale = "not-available" });
    });
  }
  public static void RegisterManager(McpDoor door, McpManager manager)
  {
    door.Register("mcp.list", async (c, a, ct) => JsonSerializer.SerializeToElement((await manager.ListAsync(ct)).Where(s => c.Has("mcp", s.Id) && (s.Scope == "user" || Text(a, "projectPath") is not { } folder || s.Folder is { } own && McpCallerScopes.Within(own, folder) && McpCallerScopes.Within(folder, own)))));
    door.Register("mcp.add", async (c, a, ct) =>
    {
      // A project's private server belongs to that project's folder grant; an app-wide (user) server is a Settings change.
      var input = ServerInput(a); if (input.Scope == "user") c.Require("settings", "mcp"); else c.Require("folders", input.Folder ?? "");
      manager.Preview(input); await c.EnsureCurrentAsync(ct); return JsonSerializer.SerializeToElement(await manager.AddAsync(input, ct));
    });
    door.Register("mcp.edit", async (c, a, ct) =>
    {
      var id = manager.ResolveId(Required(a, "name"), Required(a, "scope"), Text(a, "projectPath")); c.Require("mcp", id);
      var patch = a.GetProperty("next");
      if (Text(patch, "scope") is { } scope && scope != Required(a, "scope")) c.Require("settings", "mcp");
      await c.EnsureCurrentAsync(ct); await manager.EditPatchAsync(id, patch, ct); return JsonSerializer.SerializeToElement(new { edited = true });
    });
    door.Register("mcp.remove", async (c, a, ct) =>
    {
      var id = manager.ResolveId(Required(a, "name"), Required(a, "scope"), Text(a, "projectPath")); c.Require("mcp", id); await c.EnsureCurrentAsync(ct); await manager.RemoveAsync(id, ct); return JsonSerializer.SerializeToElement(new { removed = true });
    });
    door.Register("mcp.connect", async (c, a, ct) =>
    {
      var id = Required(a, "serverId"); c.Require("mcp", id); await c.EnsureCurrentAsync(ct); return JsonSerializer.SerializeToElement(new { tools = a.TryGetProperty("test", out var test) && test.GetBoolean() ? await manager.TestAsync(id, ct) : await manager.ConnectAsync(id, ct) });
    });
    door.Register("mcp.disconnect", async (c, a, ct) =>
    {
      var id = Required(a, "serverId"); c.Require("mcp", id); await c.EnsureCurrentAsync(ct); await manager.DisconnectAsync(id, ct); return JsonSerializer.SerializeToElement(new { disconnected = true });
    });
    door.Register("mcp.call", async (c, a, ct) =>
    {
      var id = Required(a, "serverId"); c.Require("mcp", id); await c.EnsureCurrentAsync(ct);
      return await manager.CallAsync(id, Required(a, "tool"), a.TryGetProperty("arguments", out var args) ? args : JsonSerializer.SerializeToElement(new { }), ct);
    });
    door.Register("mcp.export", async (c, a, ct) =>
    {
      var id = manager.ResolveId(Required(a, "name"), Required(a, "scope"), Text(a, "projectPath")); c.Require("mcp", id); return await manager.ExportAsync(id, ct);
    });
    door.Register("mcp.import", (c, a, ct) =>
    {
      c.Require("settings", "mcp"); using var document = JsonDocument.Parse(Required(a, "text"));
      var servers = document.RootElement.GetProperty("mcpServers");
      if (servers.ValueKind != JsonValueKind.Object || servers.EnumerateObject().Count() > 64) throw new McpRefusal("This MCP import is unusable.");
      return Result(new { preview = servers.EnumerateObject().Select(p => new { name = p.Name, hasCommand = p.Value.TryGetProperty("command", out _), hasUrl = p.Value.TryGetProperty("url", out _) }), applied = false, redacted = true });
    });
  }
  public static McpServerInput ServerInput(JsonElement a) => new()
  {
    Name = Required(a, "name"), Scope = Required(a, "scope"), Transport = Required(a, "transport"), Folder = Text(a, "projectPath"), Command = Text(a, "command"), Url = Text(a, "url"),
    Environment = Strings(a, "env"), Headers = Strings(a, "headers")
  };
  private static Dictionary<string, string> Strings(JsonElement a, string key) => a.TryGetProperty(key, out var value) ? value.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString() ?? throw new McpRefusal("Environment and header values must be text.")) : [];
  internal static string? Text(JsonElement a, string key) => a.TryGetProperty(key, out var value) ? value.GetString() : null;
  internal static string Required(JsonElement a, string key, bool empty = false) => Text(a, key) is { } value && (empty || !string.IsNullOrWhiteSpace(value)) ? value : throw new McpRefusal("Choose a value for " + key + ".");
  private static ValueTask<JsonElement> Result(object value) => ValueTask.FromResult(JsonSerializer.SerializeToElement(value));
  private static object AccountView(AccountProfile a) => new { id = a.Id, provider = a.Provider, name = a.Name, email = a.Email, signedIn = a.SignedIn, authentication = a.Authentication.ToString(), shareHistory = a.ShareHistory };
  private static object View(SessionRecord s) => new { id = s.Definition.Id, provider = s.Definition.Provider, cwd = s.Definition.Cwd, title = s.Definition.Title, accountId = s.Definition.AccountId, status = s.State.ToString(), createdAt = s.CreatedAt, exitCode = s.ExitCode };
  private static string Key(string key) => key.ToLowerInvariant() switch
  {
    "enter" or "return" => "\r", "escape" or "esc" => "\u001b", "tab" => "\t", "backspace" => "\u007f", "delete" => "\u001b[3~", "up" => "\u001b[A", "down" => "\u001b[B", "right" => "\u001b[C", "left" => "\u001b[D", "ctrl-c" => "\u0003", "ctrl-d" => "\u0004",
    _ => key.Length == 1 && !char.IsControl(key[0]) ? key : throw new McpRefusal("That key is not supported.")
  };
}
