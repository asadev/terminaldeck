using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace TerminalDeck.Core.WhatsApp;

/// The one observable store every WhatsApp screen reads (Settings > AI apps "WhatsApp" group, the "WhatsApp" submenu in a
/// page's "..." menu and a session row's right-click menu, the heading chip and its switch). A port of the Mac's
/// NativeWhatsAppAgents.swift. It holds the list and passes every action to the engine. The composition calls Connect
/// once WhatsApp agents are ready on this computer; picture tests connect a WhatsAppAgentsFixture.
/// Post: how a change reaches the UI thread (the App passes its dispatcher; tests leave it null = run inline).
public sealed class WhatsAppAgentsStore(Action<Action>? post = null) : INotifyPropertyChanged
{
  public static WhatsAppAgentsStore Shared { get; } = new();

  /// Set once by the App before Connect: how changes reach the UI thread.
  public Action<Action>? Post { get; set; } = post;

  private IReadOnlyList<WhatsAppAgentProfile> agents = [];
  private string? problem;
  private bool checking;

  public event PropertyChangedEventHandler? PropertyChanged;
  /// Raised after every change of the list (the chip and submenus re-read through Attached/Chip).
  public event Action? Changed;

  /// The profiles, in the order he added them.
  public IReadOnlyList<WhatsAppAgentProfile> Agents { get => agents; private set { agents = value; Raise(); Raise(nameof(NextDefaultName)); Changed?.Invoke(); } }
  /// The last refusal in one plain sentence; the screen that acted shows it, then clears it (set to null).
  public string? Problem { get => problem; set { problem = value; Raise(); } }
  /// True while an add or a key replacement is being checked with WhatsApp (the field and "Add" wait).
  public bool Checking { get => checking; private set { checking = value; Raise(); } }
  public IWhatsAppAgentsControlling? Engine { get; private set; }

  /// Set by the composition (or a test). Reads the list at once and follows every change.
  public async Task ConnectAsync(IWhatsAppAgentsControlling? engine)
  {
    Engine = engine;
    if (engine is null) { OnUi(() => Agents = []); return; }
    await engine.ObserveAsync(list => OnUi(() => Agents = list)).ConfigureAwait(false);
    var now = await engine.AgentsAsync().ConfigureAwait(false);
    OnUi(() => Agents = now);
  }

  // What the views read.

  /// "+ Add WhatsApp agent" always shows (no limit on our side).
  public bool CanAdd => true;
  /// The WhatsApp agents attached to this page or session (the submenu's check marks).
  public IReadOnlyList<WhatsAppAgentProfile> Attached(WhatsAppReceiver receiver) => agents.Attached(receiver);
  /// The chip: the first WhatsApp agent attached here, null = no chip.
  public WhatsAppAgentProfile? Chip(WhatsAppReceiver receiver) => Attached(receiver).FirstOrDefault();
  public IReadOnlyList<WhatsAppAgentProfile> AttachedToSession(string sessionId) => Attached(WhatsAppReceiver.Session(sessionId, ""));
  public IReadOnlyList<WhatsAppAgentProfile> AttachedToAgent(string agentId) => Attached(WhatsAppReceiver.Agent(agentId, ""));
  public IReadOnlyList<WhatsAppAgentProfile> AttachedToHoot => Attached(WhatsAppReceiver.Hoot);
  /// The default name the add row's name field is prefilled with.
  public string NextDefaultName => WhatsAppAgentsLimits.DefaultName(agents.Select(a => a.Name));

  // What the views call (each returns true when it was done; a refusal is in Problem).

  public async Task<bool> AddAsync(string name, string key)
  {
    Checking = true;
    try { return await Run(e => e.AddAsync(name, key)); } finally { Checking = false; }
  }
  public Task<bool> RenameAsync(string id, string name) => Run(e => e.RenameAsync(id, name));
  public async Task<bool> ReplaceKeyAsync(string id, string key)
  {
    Checking = true;
    try { return await Run(e => e.ReplaceKeyAsync(id, key)); } finally { Checking = false; }
  }
  public Task<bool> RemoveAsync(string id) => Run(e => e.RemoveAsync(id));
  public Task<bool> SetReceiverAsync(string id, WhatsAppReceiver receiver) => Run(e => e.SetReceiverAsync(id, receiver));
  /// "WhatsApp > &lt;agent&gt;" on this page or session: attach it here.
  public Task<bool> AttachAsync(string id, WhatsAppReceiver receiver) => Run(e => e.AttachAsync(id, receiver));
  /// The switch on an attached agent (on = answers go to WhatsApp, off = they stay in Terminal Deck).
  public Task<bool> SetSendingAsync(bool on, string agentId) => Run(e => e.SetSendingAsync(on, agentId));
  /// "WhatsApp > Off" on this page or session.
  public Task<bool> OffAsync(WhatsAppReceiver receiver) => Run(e => e.OffAsync(receiver));

  private async Task<bool> Run(Func<IWhatsAppAgentsControlling, Task> action)
  {
    var engine = Engine;
    if (engine is null) { Problem = WhatsAppProblem.NotReady.Message; return false; }
    try { await action(engine); Problem = null; return true; }
    catch (WhatsAppProblem p) { Problem = p.Message; return false; }
    catch (Exception) { Problem = WhatsAppProblem.Unreachable.Message; return false; }
  }

  private void OnUi(Action a) { if (Post is { } p) p(a); else a(); }
  private void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
