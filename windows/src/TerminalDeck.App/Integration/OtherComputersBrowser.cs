using System.Collections.Concurrent;
using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Integration;

public sealed partial class OtherComputersService
{
  private McpDoor? browserDoor;
  private readonly ConcurrentDictionary<(string Computer, string Session), McpRegistration> browserCallers = new();
  private readonly SemaphoreSlim browserCalls = new(8, 8);
  public bool DrivesBrowser(string id) => saved.TryGetValue(id, out var row) && row.DrivesWindows;
  public void BindBrowserDoor(McpDoor door)
  {
    browserDoor = door;
    _ = ConnectSavedAsync();
  }
  private async Task ConnectSavedAsync()
  {
    foreach (var id in saved.Keys)
    {
      if (lifetime.IsCancellationRequested) return;
      try { await ConnectAsync(id, lifetime.Token); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { }
    }
  }
  public async Task SetBrowserConsentAsync(string id, bool allowed)
  {
    await mutations.WaitAsync();
    try
    {
      if (!saved.TryGetValue(id, out var row)) throw new ArgumentException("Choose a paired computer.");
      saved[id] = row with { DrivesWindows = allowed };
      try { Save(); } catch { saved[id] = row; throw; }
      if (!allowed) RevokeBrowser(id);
    }
    finally { mutations.Release(); }
    Changed?.Invoke();
  }
  private void RevokeBrowser(string id)
  {
    foreach (var caller in browserCallers.Where(c => c.Key.Computer == id))
      if (browserCallers.TryRemove(caller.Key, out var registration)) browserDoor?.Revoke(registration.Id);
  }
  private async Task ServeBrowserAsync(string id, JsonElement frame, CancellationToken ct)
  {
    var request = Text(frame, "id", "");
    if (request.Length is < 1 or > 64) return;
    bool entered = false;
    try
    {
      if (!await browserCalls.WaitAsync(0, ct)) throw new McpRefusal("Too many browser calls are pending.");
      entered = true;
      var session = Text(frame, "session", "");
      bool Allowed() => DrivesBrowser(id) && List().Any(c => c.Id == id && c.State == "Online") && Services(id).Sessions.Any(s => Text(s, "id", "") == session);
      if (!Allowed() || browserDoor is not { } door) throw new McpRefusal("Allow this computer's sessions to use browser windows here first.");
      var tools = new[] { "browser.open", "browser.close", "browser.windows", "browser.page", "browser.read", "browser.step", "browser.batch", "browser.profiles", "browser.history", "browser.workspace.read", "browser.workspace.change" };
      var tool = Text(frame, "tool", "").Replace('_', '.');
      if (!tools.Contains(tool)) throw new McpRefusal("This is not a supported browser tool.");
      var registration = browserCallers.GetOrAdd((id, session), _ => door.RegisterCaller(new("computer:" + id + ":" + session, null, id, true, AiPermissionMode.Ask, tools, [McpTier.Read, McpTier.Act, McpTier.Alter], ["browser:*", "origins:*", "windows:*", "sessions:*", "profiles:*", "settings:browser", "settings:workspace"], DateTimeOffset.UtcNow.AddHours(8), OwnerApplication: true), (_, _, _, _, _) => ValueTask.FromResult(Allowed())));
      var encoded = Text(frame, "args", "");
      if (System.Text.Encoding.UTF8.GetByteCount(encoded) > 16384) throw new McpRefusal("Browser arguments are too large.");
      using var arguments = JsonDocument.Parse(encoded);
      var answer = await door.CallAsync(registration.Id, tool, arguments.RootElement, ct);
      var body = answer.GetRawText();
      if (System.Text.Encoding.UTF8.GetByteCount(body) > 49152) throw new McpRefusal("The browser answer is too large for this connection. Ask for a smaller selector or text limit.");
      await SendAsync(id, new { t = "window.result", id = request, ok = true, body }, ct);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      try { await SendAsync(id, new { t = "window.result", id = request, ok = false, body = JsonSerializer.Serialize(new { message = ex.Message }) }, ct); } catch (Exception sendError) when (sendError is not OutOfMemoryException) { }
    }
    finally { if (entered) browserCalls.Release(); }
  }
}
