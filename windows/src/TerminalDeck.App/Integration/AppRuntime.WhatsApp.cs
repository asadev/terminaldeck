using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.WhatsApp;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

// WhatsApp agents on Windows (DESIGN-WHATSAPP.md; the Mac's NativeCompositionWhatsApp.swift). Started in InitializeAsync
// after Hoot; tools in RegisterTools; the keys' store in CloudSecretStores; the records' Cloud family in the account's
// CloudKindsForAccount; the screens' store dispatcher in ShellWindow. Receiver ids are the screens' own: a session =
// its definition id (tab.Subject, SessionDraft.Id), an agent = SavedAgent.Id.
public sealed partial class AppRuntime
{
  /// The engine, null until InitializeWhatsAppAsync ran (the tools then say "not ready").
  public WhatsAppAgents? WhatsApp { get; private set; }
  private WhatsAppSettingsFile? whatsAppSettings;
  /// The synced records (one file of this copy's data folder; they travel as the Mac's settings).
  public WhatsAppSettingsFile WhatsAppSettings => whatsAppSettings ??= new(Path.Combine(Root.DirectoryPath, "whatsapp-agents.json"));
  private WhatsAppCredentialKeeper? whatsAppKeys;
  private WhatsAppCredentialKeeper WhatsAppKeys => whatsAppKeys ??= new(new WindowsCredentialStore(Root), Root);
  private WhatsAppHttpTransport? whatsAppTransport;

  /// After sessions, chats and Hoot exist. Starts reading the agents this PC reads and connects the screens' store.
  public async Task InitializeWhatsAppAsync()
  {
    if (WhatsApp is not null) return;
    whatsAppTransport = new WhatsAppHttpTransport(WhatsAppRedirectGuard.Make());
    var receivers = new WhatsAppWindowsReceivers(Chats, () => Hoot, () => Sessions,
      async (id, bytes) => { var reply = await Keeper.WriteAsync(id, bytes); if (reply.Success != true) throw new InvalidOperationException("The terminal did not take it."); },
      async (agentId, title) => (await Agents.StartAsync(new(agentId, Mode: "chat", Title: title.Length > 120 ? title[..120] : title))).SessionId,
      RefreshSessionsAsync);
    var engine = new WhatsAppAgents(whatsAppTransport, WhatsAppSettings, WhatsAppKeys, new WhatsAppCloudPresence(() => Cloud.Snapshot), receivers,
      removeEverywhere: id => CloudKeysRemovals.Shared.RemoveEverywhereAsync(WhatsAppKeysStore.Source, id));
    WhatsApp = engine;
    await engine.StartAsync();
    await WhatsAppAgentsStore.Shared.ConnectAsync(engine);
  }

  /// The saved-passwords store "whatsapp" under the delete rule (lane S2's style). Its removals go everywhere.
  private CloudSecretsDeleteOwner WhatsAppKeysOwner(string state, Func<bool> gate, Func<string, string?> deviceName, Func<long?> serviceNow)
  {
    var store = new WhatsAppKeysStore(WhatsAppKeys, async id => (await WhatsAppSettings.RecordsAsync()).FirstOrDefault(r => r.Id == id)?.Name);
    return store.DeleteRuleOwner(state, gate, deviceName, serviceNow);
  }
}
