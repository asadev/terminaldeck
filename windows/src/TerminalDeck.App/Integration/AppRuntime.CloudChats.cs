using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Integration;

/// Lane C: this PC's sessions and chat histories go to the account's Cloud (the phones and Macs list and read them).
/// ONE driver; it uploads only while this PC is signed in with sync on (`SyncIdentity`); signed out it is detached and
/// sends nothing. Switch to this PC is not part of this lane.
public sealed partial class AppRuntime
{
  /// Named CloudChats here: `Chats` is the app's own chat sessions client.
  public CloudChatsDriver? CloudChats { get; private set; }
  /// The Your Cloud page's delete owner for chats (lane U shows it).
  public ICloudDeleteOwning? CloudChatsDeleting { get; private set; }
  private string? cloudChatsFor;

  private void InitializeCloudChats()
  {
    CloudChats = new CloudChatsDriver(ListForCloud, () => Projects.List(),
      CloudChatsLocator.ForWindows(Root, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)),
      ready: () => Cloud.SyncIdentity is not null);
    CloudChatsDeleting = new CloudChatsDeleteOwning(() => CloudChats?.DeleteOwner);
    Cloud.Changed += _ => FollowCloudForChats();
    FollowCloudForChats();
  }

  private void FollowCloudForChats()
  {
    if (CloudChats is not { } driver) return;
    var identity = Cloud.SyncIdentity;
    var wanted = identity is { } id ? id.Subject + "/" + id.DeviceId : null;
    lock (cloudLogGate)
    {
      if (wanted == cloudChatsFor) return;
      cloudChatsFor = wanted;
    }
    if (identity is not { } who) { driver.Detach(); return; }
    var door = new CloudChatsClient(new CloudSyncEndpoint(new Uri(CloudWire.ProductionBase), test: false), Cloud, new HttpClientCloudSyncHttp()).Door();
    var machine = Cloud.Machine?.PairFor(who.Subject)?.MachineId ?? who.DeviceId;
    driver.Attach(door, Path.Combine(CloudAccountFolder(who.Subject), "chats"), who.DeviceId, TerminalDeck.Core.Cloud.CloudChats.MachineRef(who.Subject, machine));
  }

  /// The reading door for the Cloud chat page (a session on another machine): null while signed out.
  public CloudChatsSend? CloudChatsDoor() => Cloud.SyncIdentity is null ? null
    : new CloudChatsClient(new CloudSyncEndpoint(new Uri(CloudWire.ProductionBase), test: false), Cloud, new HttpClientCloudSyncHttp()).Door();

  /// What the side panel lists: the keeper's terminals and the app's chats.
  private Task<IReadOnlyList<CloudChatsSession>> ListForCloud()
  {
    var rows = new List<CloudChatsSession>();
    foreach (var s in Sessions)
    {
      var working = HookSessionEvents.TryGetValue(s.Definition.Id, out var e) && e.Event is "UserPromptSubmit" or "PreToolUse" or "PostToolUse" or "BeforeAgent" or "BeforeTool" or "AfterTool";
      rows.Add(CloudChatsSession.Terminal(s, PhoneSessionRows.TerminalStatus(s, working), e is not null ? e.At.ToUnixTimeMilliseconds() : s.CreatedAt));
    }
    try { foreach (var c in Chats.List()) rows.Add(CloudChatsSession.FromChat(c)); }
    catch (Exception ex) when (ex is InvalidOperationException or ObjectDisposedException or NullReferenceException) { }
    return Task.FromResult<IReadOnlyList<CloudChatsSession>>(rows);
  }
}
