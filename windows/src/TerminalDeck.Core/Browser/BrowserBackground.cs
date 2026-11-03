using System.Collections.Concurrent;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Browser;

public sealed partial class BrowserModel
{
  public Func<McpGrant, string> ResolveDriverName { get; set; } = DriverLabel;
  private readonly ConcurrentDictionary<string, string> callerSelections = new();
  private readonly ConcurrentDictionary<string, string> drivers = new();
  public string? CallerSelection(string caller) => callerSelections.TryGetValue(caller, out var id) && Read().Tabs.Any(t => t.Id == id) ? id : null;
  public void SelectForCaller(string caller, string id) { _ = Get(id); if (callerSelections.Count >= 128 && !callerSelections.ContainsKey(caller)) callerSelections.TryRemove(callerSelections.Keys.First(), out _); callerSelections[caller] = id; }
  public void SetDriver(string id, string name) { _ = Get(id); drivers[id] = new string(name.Where(c => !char.IsControl(c)).Take(100).ToArray()); }
  public string? Driver(string id) => drivers.TryGetValue(id, out var name) ? name : null;
  public void ClearDriver(string id) => drivers.TryRemove(id, out _);
  public static string DriverLabel(McpGrant grant)
  {
    if (!string.IsNullOrWhiteSpace(grant.SeatId)) return grant.SeatId == "orchestrator" ? "Hoot" : grant.SeatId;
    return grant.OwnerApplication ? "You" : grant.SessionId is { } session ? "Session " + session[..Math.Min(8, session.Length)] : "Agent " + grant.CallerId[..Math.Min(40, grant.CallerId.Length)];
  }
}
