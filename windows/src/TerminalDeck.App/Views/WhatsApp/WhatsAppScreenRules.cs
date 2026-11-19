using TerminalDeck.Core.WhatsApp;

namespace TerminalDeck.App.Views.WhatsApp;

// WhatsApp agents, the screens' rules (Asad, 15 Nov 2026; notes/review-20261115/DESIGN-WHATSAPP.md sections 2 and 3).
// A port of the Mac's NativeWhatsAppScreens.swift (WhatsAppWords, WhatsAppReceiverChoices, WhatsAppMenu) and of what each
// Settings row and the heading chip show. Plain .NET, no window: Core.Tests links this file and checks every rule.

/// Every word the WhatsApp screens show (the Mac's words; "this PC" where the Mac says "this Mac").
public static class WhatsAppWords
{
  public const string GroupTitle = "WhatsApp";
  public const string SubmenuTitle = "WhatsApp";
  /// The group's info button: the whole manual way, then one secondary line.
  public const string Steps = "1. In WhatsApp open Settings > Agents and create an agent.\n2. Open its chat, then Chat info > API key, and copy the key.\n3. Add it here.";
  public const string NotEncrypted = "WhatsApp does not encrypt these chats end to end.";
  public const string AddRow = "Add WhatsApp agent";
  public const string KeyPrompt = "Paste the key from WhatsApp";
  public const string Add = "Add";
  public const string Off = "Off";
  /// The switch: on = answers go to WhatsApp; off = the agent stays attached and nothing is sent.
  public const string Send = "Send to WhatsApp";
  public const string Paused = "Paused";
  public const string Pause = "Pause";
  public const string Resume = "Resume";
  public const string Rename = "Rename";
  public const string ReplaceKey = "Replace key";
  public const string Remove = "Remove";
  public const string Sessions = "Sessions";
  public const string Independent = "Independent";
  /// The submenu when he has no WhatsApp agent yet: one item that opens Settings > AI apps.
  public const string AddFromMenu = "Add a WhatsApp agent…";
  /// Settings > AI apps on Windows (SettingsNavigation's id).
  public const string SettingsSection = "outside-ai-apps";
  public static string ChipHelp(string name) => "Received on WhatsApp: " + name;
}

public sealed record WhatsAppChoice(string Id, string Name);
public sealed record WhatsAppChoiceProject(string Name, IReadOnlyList<WhatsAppChoice> Agents);

/// The row pop-up's lists: Hoot · his agents by name under their project · "Sessions" with the open sessions · Nowhere.
public sealed record WhatsAppReceiverChoices(IReadOnlyList<WhatsAppChoiceProject> Projects, IReadOnlyList<WhatsAppChoice> Sessions)
{
  public static WhatsAppReceiverChoices Empty { get; } = new([], []);

  /// Agents grouped under their project in the order first seen ("" = Independent); sessions once each, by id.
  public static WhatsAppReceiverChoices From(IEnumerable<(string Id, string Name, string Project)> agents, IEnumerable<(string Id, string Name)> sessions)
  {
    var order = new List<string>();
    var byProject = new Dictionary<string, List<WhatsAppChoice>>(StringComparer.Ordinal);
    foreach (var (id, name, project) in agents)
    {
      if (!byProject.TryGetValue(project, out var list)) { order.Add(project); byProject[project] = list = []; }
      list.Add(new(id, name));
    }
    var seen = new HashSet<string>(StringComparer.Ordinal);
    var open = sessions.Where(s => seen.Add(s.Id)).Select(s => new WhatsAppChoice(s.Id, s.Name)).ToArray();
    return new(order.Select(p => new WhatsAppChoiceProject(p.Length == 0 ? WhatsAppWords.Independent : p, byProject[p])).ToArray(), open);
  }

  /// The pop-up's tag for a receiver (agents and sessions by id, so a renamed one stays chosen).
  public static string Tag(WhatsAppReceiver receiver) => receiver.Kind switch
  {
    WhatsAppReceiverKind.Hoot => "hoot",
    WhatsAppReceiverKind.Agent => "agent:" + receiver.Id,
    WhatsAppReceiverKind.Session => "session:" + receiver.Id,
    _ => "nowhere",
  };

  /// The receiver a chosen tag stands for, with the name the list shows now (current keeps one no longer listed).
  public WhatsAppReceiver Receiver(string tag, WhatsAppReceiver current)
  {
    if (tag == Tag(current)) return current;
    if (tag == "hoot") return WhatsAppReceiver.Hoot;
    if (tag.StartsWith("agent:", StringComparison.Ordinal))
    {
      var id = tag[6..];
      return WhatsAppReceiver.Agent(id, Projects.SelectMany(p => p.Agents).FirstOrDefault(a => a.Id == id)?.Name ?? "");
    }
    if (tag.StartsWith("session:", StringComparison.Ordinal))
    {
      var id = tag[8..];
      return WhatsAppReceiver.Session(id, Sessions.FirstOrDefault(s => s.Id == id)?.Name ?? "");
    }
    return WhatsAppReceiver.Nowhere;
  }

  /// True when the current receiver is an agent or session the lists no longer hold (it is still shown, by its name).
  public bool Lacks(WhatsAppReceiver receiver) => receiver.Kind switch
  {
    WhatsAppReceiverKind.Agent => !Projects.SelectMany(p => p.Agents).Any(a => a.Id == receiver.Id),
    WhatsAppReceiverKind.Session => !Sessions.Any(s => s.Id == receiver.Id),
    _ => false,
  };

  /// What the pop-up's list holds, in order: (kind, text, tag, checked). Kinds: item, header, separator.
  public IReadOnlyList<WhatsAppPopUpLine> Lines(WhatsAppReceiver current)
  {
    var chosen = Tag(current);
    var lines = new List<WhatsAppPopUpLine> { new(WhatsAppPopUpLineKind.Item, WhatsAppReceiver.Hoot.Title, "hoot", chosen == "hoot") };
    foreach (var project in Projects)
    {
      lines.Add(new(WhatsAppPopUpLineKind.Header, project.Name, "", false));
      lines.AddRange(project.Agents.Select(a => new WhatsAppPopUpLine(WhatsAppPopUpLineKind.Item, a.Name, "agent:" + a.Id, chosen == "agent:" + a.Id)));
    }
    if (Sessions.Count > 0)
    {
      lines.Add(new(WhatsAppPopUpLineKind.Header, WhatsAppWords.Sessions, "", false));
      lines.AddRange(Sessions.Select(s => new WhatsAppPopUpLine(WhatsAppPopUpLineKind.Item, s.Name, "session:" + s.Id, chosen == "session:" + s.Id)));
    }
    // A receiver no longer listed (an agent removed, a session elsewhere) still shows, by its name.
    if (Lacks(current)) lines.Add(new(WhatsAppPopUpLineKind.Item, current.Title, chosen, true));
    lines.Add(new(WhatsAppPopUpLineKind.Separator, "", "", false));
    lines.Add(new(WhatsAppPopUpLineKind.Item, WhatsAppReceiver.Nowhere.Title, "nowhere", chosen == "nowhere"));
    return lines;
  }
}

public enum WhatsAppPopUpLineKind { Item, Header, Separator }
public sealed record WhatsAppPopUpLine(WhatsAppPopUpLineKind Kind, string Text, string Tag, bool Checked);

/// The row's dot: green connected, orange the key was refused, none while waiting for his first message.
public enum WhatsAppDot { None, Green, Orange }

/// What one Settings row shows (section 2): [dot] name ...... [secondary words] [pop-up | orange refusal] [...].
public sealed record WhatsAppRowLook(string Name, WhatsAppDot Dot, string? Secondary, string? Refused, bool ShowsReceiver, string ReceiverTitle, IReadOnlyList<string> Menu)
{
  public const string MenuSeparator = "-";

  public static WhatsAppRowLook For(WhatsAppAgentProfile agent)
  {
    var dot = agent.State switch { WhatsAppAgentState.Connected => WhatsAppDot.Green, WhatsAppAgentState.Refused => WhatsAppDot.Orange, _ => WhatsAppDot.None };
    var refused = agent.State == WhatsAppAgentState.Refused ? agent.State.Words() : null;
    // A paused row says "Paused" before its pop-up; otherwise the waiting words, or who answers.
    var secondary = refused is not null ? null : agent.Sending ? agent.State.Words() ?? agent.AnsweredElsewhereWords : WhatsAppWords.Paused;
    return new(agent.Name, dot, secondary, refused, refused is null, agent.Receiver.Title,
      (string[])[agent.Sending ? WhatsAppWords.Pause : WhatsAppWords.Resume, WhatsAppWords.Rename, WhatsAppWords.ReplaceKey, MenuSeparator, WhatsAppWords.Remove]);
  }
}

public enum WhatsAppMenuEntryKind { Agent, Separator, Sending, Off, AddAgent }

/// One line of the "WhatsApp" submenu (and of the chip's own list).
public sealed record WhatsAppMenuEntry(WhatsAppMenuEntryKind Kind, string Text, string? AgentId = null, bool Checked = false, bool Enabled = true);

/// The "WhatsApp" submenu for one place: his WhatsApp agents by name (a check on the one attached here), then the checked
/// item "Send to WhatsApp" (for the agent attached here) and "Off". With none yet: one item that opens Settings > AI apps.
public static class WhatsAppMenu
{
  public static IReadOnlyList<WhatsAppMenuEntry> Entries(IReadOnlyList<WhatsAppAgentProfile> agents, WhatsAppReceiver here)
  {
    if (agents.Count == 0) return (WhatsAppMenuEntry[])[new(WhatsAppMenuEntryKind.AddAgent, WhatsAppWords.AddFromMenu)];
    var entries = agents.Select(a => new WhatsAppMenuEntry(WhatsAppMenuEntryKind.Agent, a.Name, a.Id, a.Receiver.SameTarget(here))).ToList();
    entries.Add(new(WhatsAppMenuEntryKind.Separator, ""));
    if (agents.Attached(here).FirstOrDefault() is { } attached)
      entries.Add(new(WhatsAppMenuEntryKind.Sending, WhatsAppWords.Send, attached.Id, attached.Sending));
    entries.Add(new(WhatsAppMenuEntryKind.Off, WhatsAppWords.Off, Enabled: entries.Any(e => e.Kind == WhatsAppMenuEntryKind.Agent && e.Checked)));
    return entries;
  }

  /// A WhatsApp agent: attached HERE (taken from wherever it was); choosing the one already here changes nothing.
  /// "Send to WhatsApp": flips the switch of the agent attached here. "Off": every one attached here goes to Nowhere.
  public static async Task<bool> PerformAsync(WhatsAppMenuEntry entry, WhatsAppReceiver here, WhatsAppAgentsStore store)
  {
    switch (entry.Kind)
    {
      case WhatsAppMenuEntryKind.Agent when entry.AgentId is { } id:
        return entry.Checked || await store.AttachAsync(id, here);
      case WhatsAppMenuEntryKind.Sending:
        return store.Chip(here) is { } agent && await store.SetSendingAsync(!entry.Checked, agent.Id);
      case WhatsAppMenuEntryKind.Off:
        return await store.OffAsync(here);
      default:
        return false;
    }
  }
}

/// The heading chip (section 3): ONLY while a WhatsApp agent is attached here; its name, drawn in secondary colour
/// while its switch is off. Null = no chip and no switch.
public sealed record WhatsAppChipLook(string AgentId, string Name, bool Sending)
{
  public string Help => WhatsAppWords.ChipHelp(Name);
  public static WhatsAppChipLook? For(IReadOnlyList<WhatsAppAgentProfile> agents, WhatsAppReceiver here) =>
    agents.Attached(here).FirstOrDefault() is { } agent ? new(agent.Id, agent.Name, agent.Sending) : null;
}
