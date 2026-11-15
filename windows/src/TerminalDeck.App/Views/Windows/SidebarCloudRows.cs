using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Shell;

// The side panel's session rows (DESIGN-SESSION-ROWS.md SR-1 to SR-8, which replaces DESIGN-WINDOWS-CLOUD.md section 4's
// row): a row is a thin outline type icon and the session's name, one line; the small orange dot only when the session
// needs him. Sessions on his other machines join the same "Sessions" list, one row per session, never twice. Plain .NET
// (no window): the rules are tested in Core.Tests.

/// One session on another of his machines, as the side panel lists it. `Ref` routes (never shown); `MachineName` and
/// `MachineOn` are for the session's own page ("Runs on Mac mini"), never drawn on the row.
public sealed record SidebarCloudRow(string Ref, string? SessionId, string Name, bool Chat, string MachineName, bool MachineOn, bool NeedsYou, double LastUsedAt);

public static class SidebarRowLook
{
  /// Segoe Fluent Icons, outline: Message (a plain speech bubble) and CommandPrompt.
  public const string ChatGlyph = "", TerminalGlyph = "";
  public const double GlyphSize = 14;
  public static string Glyph(bool chat) => chat ? ChatGlyph : TerminalGlyph;
  /// The one state the row still shows: the session waits for an approval or an answer.
  public static bool NeedsYou(string? state) => (state ?? "").ToLowerInvariant() is "waiting" or "needs-input" or "needs attention" or "held" or "needs_input" or "approval";
}

public static class SidebarCloudRows
{
  public const string Untitled = "Untitled session";

  /// The other machines' rows to list. A session shows ONCE: a row of this PC (its own, `Mine`), a row whose session is
  /// already in the side panel here (`localIds`: a live tab or a session moved here) and a second copy of the same session
  /// are left out. Newest use first.
  public static IReadOnlyList<SidebarCloudRow> From(IEnumerable<CloudSessionsRead.Row> others, IReadOnlyDictionary<string, CloudSessionsRead.Machine> machines, IEnumerable<string> localIds)
  {
    var local = new HashSet<string>(localIds, StringComparer.Ordinal);
    var seenRefs = new HashSet<string>(StringComparer.Ordinal);
    var seenSessions = new HashSet<string>(StringComparer.Ordinal);
    var rows = new List<SidebarCloudRow>();
    foreach (var row in others.OrderByDescending(r => r.LastUsedAt ?? 0))
    {
      if (row.Mine == true || string.IsNullOrEmpty(row.Ref) || row.ClosedAt is not null) continue;
      if (row.SessionId is { Length: > 0 } sid && (local.Contains(sid) || !seenSessions.Add(sid))) continue;
      if (!seenRefs.Add(row.Ref)) continue;
      var machine = row.Machine is { } m && machines.TryGetValue(m, out var known) ? known : null;
      var machineName = FirstText(machine?.Name, row.MachineName) ?? "another computer";
      var on = machine?.On ?? row.MachineOn ?? false;
      rows.Add(new(row.Ref, row.SessionId, FirstText(row.Name) ?? Untitled, IsChat(row.Kind), ReachMachineName(machineName), on, on && SidebarRowLook.NeedsYou(row.Status), row.LastUsedAt ?? 0));
    }
    return rows;
  }

  /// "chat" and Hoot's chat are chats; a terminal, a shell or an agent's terminal is a terminal.
  public static bool IsChat(string? kind) => (kind ?? "").ToLowerInvariant() is "chat" or "hoot" or "appchat";

  private static string ReachMachineName(string name)
  {
    var text = name.Trim();
    if (text.EndsWith(".local", StringComparison.OrdinalIgnoreCase) && text.Length > 6) text = text[..^6];
    return text;
  }

  private static string? FirstText(params string?[] values) => values.Select(v => v?.Trim()).FirstOrDefault(v => !string.IsNullOrEmpty(v));
}
