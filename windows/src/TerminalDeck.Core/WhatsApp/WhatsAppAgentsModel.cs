using System.Text.Json.Serialization;

namespace TerminalDeck.Core.WhatsApp;

// WhatsApp agents (Asad, 15 Nov 2026, DESIGN-WHATSAPP.md second version): the person adds his WhatsApp agents as
// PROFILES (a name and a key each, as many as he has) and chooses, whenever he likes, WHERE each one is received:
// Hoot, one of his agents, one session, or nowhere. This file is the PUBLIC SHAPE the screens build against
// (Settings > AI apps "WhatsApp" group, the "WhatsApp" submenu, the heading chip and its switch). A port of the Mac's
// BackendWhatsAppModel.swift name for name. Nothing here touches the network, a key or a screen.

/// Where one WhatsApp agent's messages are received (Swift: enum WhatsAppReceiver).
public enum WhatsAppReceiverKind { Nowhere, Hoot, Agent, Session }

/// Where one WhatsApp agent's messages are received. Use the factories: Nowhere, Hoot, Agent(id, name), Session(id, name).
public sealed record WhatsAppReceiver
{
  [JsonConstructor]
  public WhatsAppReceiver(WhatsAppReceiverKind kind, string id = "", string name = "")
  {
    Kind = kind;
    Id = kind is WhatsAppReceiverKind.Agent or WhatsAppReceiverKind.Session ? id ?? "" : "";
    Name = kind is WhatsAppReceiverKind.Agent or WhatsAppReceiverKind.Session ? name ?? "" : "";
  }

  public WhatsAppReceiverKind Kind { get; }
  /// The agent's or the session's id ("" for Nowhere and Hoot).
  public string Id { get; }
  /// The agent's or the session's name as last seen ("" for Nowhere and Hoot).
  public string Name { get; }

  /// Kept, not received (no computer polls it).
  public static readonly WhatsAppReceiver Nowhere = new(WhatsAppReceiverKind.Nowhere);
  /// Hoot: one lasting Hoot conversation named after the WhatsApp agent.
  public static readonly WhatsAppReceiver Hoot = new(WhatsAppReceiverKind.Hoot);
  /// One of his agents (seat or saved agent) by id.
  public static WhatsAppReceiver Agent(string id, string name) => new(WhatsAppReceiverKind.Agent, id, name);
  /// One session (chat or terminal) by its session id, on the computer it runs on.
  public static WhatsAppReceiver Session(string id, string name) => new(WhatsAppReceiverKind.Session, id, name);

  /// What the pop-up and the tools show: "Hoot", the agent's or session's name, or "Nowhere".
  [JsonIgnore]
  public string Title => Kind switch
  {
    WhatsAppReceiverKind.Nowhere => "Nowhere",
    WhatsAppReceiverKind.Hoot => "Hoot",
    _ => Name.Length == 0 ? "Unnamed" : Name,
  };

  /// The same receiver, compared by what it points at (a renamed session is still the same session).
  public bool SameTarget(WhatsAppReceiver other) =>
    other is not null && Kind == other.Kind && (Kind is WhatsAppReceiverKind.Nowhere or WhatsAppReceiverKind.Hoot || Id == other.Id);

  /// Hoot and agents may be taken over by another computer after 10 minutes; a session never moves.
  [JsonIgnore]
  public bool CanMoveComputer => Kind is WhatsAppReceiverKind.Hoot or WhatsAppReceiverKind.Agent;
}

/// The one state a row shows (design section 2).
public enum WhatsAppAgentState
{
  /// Green dot: the key is accepted and he has written to the agent at least once.
  Connected,
  /// No dot: the key is accepted but he has not written yet (the agent cannot write first).
  Waiting,
  /// Orange: the key was refused (wrong or replaced). "Replace key" fixes it.
  Refused,
}

public static class WhatsAppAgentStateWords
{
  /// The secondary words beside the row, null when the row shows none (connected).
  public static string? Words(this WhatsAppAgentState state) => state switch
  {
    WhatsAppAgentState.Waiting => "Waiting for your first message",
    WhatsAppAgentState.Refused => "The key was refused",
    _ => null,
  };
}

/// One WhatsApp agent, as every screen and tool sees it. Never holds the key.
public sealed record WhatsAppAgentProfile(
  string Id,
  string Name,
  WhatsAppAgentState State,
  WhatsAppReceiver Receiver,
  string? AnsweringComputerName = null,
  bool AnsweredHere = false,
  bool TakenOver = false,
  DateTimeOffset? LastMessageAt = null,
  bool Sending = true)
{
  /// "Answered by Office PC" when another computer answers; null when this one does or nobody does.
  public string? AnsweredElsewhereWords =>
    AnsweredHere || Receiver.Kind == WhatsAppReceiverKind.Nowhere || string.IsNullOrEmpty(AnsweringComputerName)
      ? null : "Answered by " + AnsweringComputerName;
}

/// A refusal in one plain sentence. Never carries the key.
public sealed class WhatsAppProblem(string message) : Exception(message)
{
  public static WhatsAppProblem KeyRefused => new("WhatsApp refused this key. Copy it again from the agent's Chat info > API key.");
  public static WhatsAppProblem NotFound => new("That WhatsApp agent is not in the list any more.");
  public static WhatsAppProblem NotReady => new("WhatsApp agents are not ready on this computer yet. Try again in a moment.");
  public static WhatsAppProblem Unreachable => new("WhatsApp could not be reached. Check the internet connection and try again.");
}

public static class WhatsAppAgentsLimits
{
  /// No limit on the number of agents on our side (Asad, 15 Nov: "If they have more API, they can connect").
  public const int MaximumNameLength = 60;

  /// "WhatsApp agent", then "WhatsApp agent 2", ...: the first free default name.
  public static string DefaultName(IEnumerable<string> taken)
  {
    var set = new HashSet<string>(taken, StringComparer.Ordinal);
    const string baseName = "WhatsApp agent";
    if (!set.Contains(baseName)) return baseName;
    var n = 2;
    while (set.Contains(baseName + " " + n)) n++;
    return baseName + " " + n;
  }
}

/// What the screens and the tools call (Swift: protocol WhatsAppAgentsControlling). The engine (WhatsAppAgents)
/// implements it; the screens' store (WhatsAppAgentsStore) and picture tests use any implementation.
public interface IWhatsAppAgentsControlling
{
  /// The profiles, in the order he added them.
  Task<IReadOnlyList<WhatsAppAgentProfile>> AgentsAsync();
  /// Called on every change of the list. Replaces the one before; null stops.
  Task ObserveAsync(Action<IReadOnlyList<WhatsAppAgentProfile>>? changed);
  /// Checks the key with WhatsApp first; a refused key throws WhatsAppProblem and adds nothing. An empty name takes the
  /// next default name. The FIRST agent he adds is received by Hoot; later ones nowhere.
  Task<WhatsAppAgentProfile> AddAsync(string name, string key);
  Task RenameAsync(string id, string name);
  /// Checks the new key with WhatsApp first; a refused key throws and keeps the old one.
  Task ReplaceKeyAsync(string id, string key);
  Task RemoveAsync(string id);
  /// Moves the agent to this receiver at once (taking it from wherever it was). Nowhere = kept, not received.
  Task SetReceiverAsync(string id, WhatsAppReceiver receiver);
  /// "Off" in the submenu or the chip: every WhatsApp agent attached to this receiver goes to Nowhere.
  Task OffAsync(WhatsAppReceiver receiver);
  /// The switch on an attached agent: on = answers and approvals go to WhatsApp; off = nothing is sent there.
  Task SetSendingAsync(bool on, string agentId);
}

public static class WhatsAppAgentsControllingExtensions
{
  /// "WhatsApp > &lt;agent&gt;" on a page or a session row: attaches it HERE (= SetReceiverAsync).
  public static Task AttachAsync(this IWhatsAppAgentsControlling engine, string id, WhatsAppReceiver receiver) =>
    engine.SetReceiverAsync(id, receiver);

  /// The WhatsApp agents attached to a page or session (the chip shows the first; the submenu checks each).
  public static IReadOnlyList<WhatsAppAgentProfile> Attached(this IEnumerable<WhatsAppAgentProfile> list, WhatsAppReceiver receiver) =>
    list.Where(p => p.Receiver.SameTarget(receiver)).ToArray();
}

/// An in-memory list for picture tests and previews: no network, no key kept (a key equal to refusedKey is refused).
public sealed class WhatsAppAgentsFixture(IEnumerable<WhatsAppAgentProfile>? list = null, string refusedKey = "refused-test-key")
  : IWhatsAppAgentsControlling
{
  private readonly object gate = new();
  private readonly List<WhatsAppAgentProfile> list = list?.ToList() ?? [];
  private Action<IReadOnlyList<WhatsAppAgentProfile>>? changed;

  public Task<IReadOnlyList<WhatsAppAgentProfile>> AgentsAsync() { lock (gate) return Task.FromResult<IReadOnlyList<WhatsAppAgentProfile>>(list.ToArray()); }
  public Task ObserveAsync(Action<IReadOnlyList<WhatsAppAgentProfile>>? changed) { lock (gate) this.changed = changed; return Task.CompletedTask; }

  private void Tell() { WhatsAppAgentProfile[] copy; Action<IReadOnlyList<WhatsAppAgentProfile>>? c; lock (gate) { copy = list.ToArray(); c = changed; } c?.Invoke(copy); }
  private int Index(string id) { var i = list.FindIndex(p => p.Id == id); if (i < 0) throw WhatsAppProblem.NotFound; return i; }

  public Task<WhatsAppAgentProfile> AddAsync(string name, string key)
  {
    if (string.IsNullOrEmpty(key) || key == refusedKey) throw WhatsAppProblem.KeyRefused;
    WhatsAppAgentProfile p;
    lock (gate)
    {
      var trimmed = (name ?? "").Trim();
      p = new WhatsAppAgentProfile("wa-" + (list.Count + 1), trimmed.Length == 0 ? WhatsAppAgentsLimits.DefaultName(list.Select(x => x.Name)) : trimmed,
        WhatsAppAgentState.Waiting, list.Count == 0 ? WhatsAppReceiver.Hoot : WhatsAppReceiver.Nowhere, "This PC", AnsweredHere: true);
      list.Add(p);
    }
    Tell(); return Task.FromResult(p);
  }
  public Task RenameAsync(string id, string name) { lock (gate) { var i = Index(id); list[i] = list[i] with { Name = name }; } Tell(); return Task.CompletedTask; }
  public Task ReplaceKeyAsync(string id, string key)
  {
    lock (gate)
    {
      var i = Index(id);
      if (string.IsNullOrEmpty(key) || key == refusedKey) throw WhatsAppProblem.KeyRefused;
      list[i] = list[i] with { State = WhatsAppAgentState.Waiting };
    }
    Tell(); return Task.CompletedTask;
  }
  public Task RemoveAsync(string id) { lock (gate) list.RemoveAll(p => p.Id == id); Tell(); return Task.CompletedTask; }
  public Task SetReceiverAsync(string id, WhatsAppReceiver receiver) { lock (gate) { var i = Index(id); list[i] = list[i] with { Receiver = receiver, Sending = true }; } Tell(); return Task.CompletedTask; }
  public Task SetSendingAsync(bool on, string agentId) { lock (gate) { var i = Index(agentId); list[i] = list[i] with { Sending = on }; } Tell(); return Task.CompletedTask; }
  public Task OffAsync(WhatsAppReceiver receiver)
  {
    lock (gate) for (var i = 0; i < list.Count; i++) if (list[i].Receiver.SameTarget(receiver)) list[i] = list[i] with { Receiver = WhatsAppReceiver.Nowhere };
    Tell(); return Task.CompletedTask;
  }
}
