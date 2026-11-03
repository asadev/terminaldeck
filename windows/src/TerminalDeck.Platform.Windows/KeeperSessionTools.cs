using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Platform.Windows;

// App composition passes its existing permission door. There is no second
// approval prompt, new bearer token or implicit all-access caller here.
public static class KeeperSessionTools
{
  public static void Register(McpDoor door, KeeperClient client)
    => Register(door, () => client);
  public static void Register(McpDoor door, Func<KeeperClient> current)
  {
    async ValueTask<SessionRecord> Get(McpCallContext context, JsonElement arguments, CancellationToken ct)
    {
      var id = arguments.GetProperty("sessionId").GetString() ?? throw new McpRefusal("Choose a session.");
      context.Require("sessions", id);
      return (await current().ListAsync(ct)).Sessions?.SingleOrDefault(s => s.Definition.Id == id) ?? throw new McpRefusal("This session was not found.");
    }
    door.Register("sessions.list", async (c, a, ct) => JsonSerializer.SerializeToElement((await current().ListAsync(ct)).Sessions!
      .Where(s => c.Has("sessions", s.Definition.Id) && SessionRows.InFolder(a, s.Definition.Cwd)).Select(View)));
    door.Register("sessions.get", async (c, a, ct) => JsonSerializer.SerializeToElement(View(await Get(c, a, ct))));
    door.Register("sessions.screen", async (c, a, ct) => JsonSerializer.SerializeToElement(new { screen = (await Get(c, a, ct)).Replay, source = "terminal-replay", partial = true }));
    door.Register("sessions.rename", async (c, a, ct) =>
    {
      var row = await Get(c, a, ct); await c.EnsureCurrentAsync(ct); await current().RenameAsync(row.Definition.Id, a.GetProperty("title").GetString()!, ct);
      return JsonSerializer.SerializeToElement(new { renamed = true });
    });
    door.Register("sessions.send", async (c, a, ct) =>
    {
      var row = await Get(c, a, ct); var text = a.GetProperty("text").GetString()!;
      if (text.Length > 4000 || text.Any(char.IsControl)) throw new McpRefusal("Use at most 4000 printable characters. Use sessions.keys for control keys.");
      await c.EnsureCurrentAsync(ct); await current().WriteAsync(row.Definition.Id, Encoding.UTF8.GetBytes(text + (a.TryGetProperty("submit", out var submit) && !submit.GetBoolean() ? "" : "\r")), ct);
      return JsonSerializer.SerializeToElement(new { sentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() });
    });
    door.Register("sessions.keys", async (c, a, ct) =>
    {
      var row = await Get(c, a, ct); var keys = a.GetProperty("keys").EnumerateArray().Select(k => k.GetString()!).ToArray();
      if (keys.Length > 100) throw new McpRefusal("Send at most 100 keys at a time.");
      var text = string.Concat(keys.Select(Key)); await c.EnsureCurrentAsync(ct); await current().WriteAsync(row.Definition.Id, Encoding.UTF8.GetBytes(text), ct);
      return JsonSerializer.SerializeToElement(new { sentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() });
    });
    door.Register("sessions.stop", async (c, a, ct) =>
    {
      var row = await Get(c, a, ct); await c.EnsureCurrentAsync(ct); await current().StopAsync(row.Definition.Id, ct); return JsonSerializer.SerializeToElement(new { stopped = true });
    });
    // sessions.start stays with the complete Core account/brief/resume planner:
    // do not advertise a second, reduced launch contract from this transport.
  }
  private static object View(SessionRecord row) => new { id = row.Definition.Id, provider = row.Definition.Provider, mode = "terminal", cwd = row.Definition.Cwd, title = row.Definition.Title, accountId = row.Definition.AccountId, status = row.State.ToString(), createdAt = row.CreatedAt, exitCode = row.ExitCode };
  private static string Key(string key) => key.ToLowerInvariant() switch
  {
    "enter" or "return" => "\r", "escape" or "esc" => "\u001b", "tab" => "\t", "backspace" => "\u007f", "delete" => "\u001b[3~", "up" => "\u001b[A", "down" => "\u001b[B", "right" => "\u001b[C", "left" => "\u001b[D", "ctrl-c" => "\u0003", "ctrl-d" => "\u0004",
    _ => key.Length == 1 && !char.IsControl(key[0]) ? key : throw new McpRefusal("That key is not supported.")
  };
}
