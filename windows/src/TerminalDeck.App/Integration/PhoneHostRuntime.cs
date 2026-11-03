using System.Text;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows.Phone;

namespace TerminalDeck.App.Integration;

public sealed record PhoneScreenState(bool Allowed = true);

// The phone features a Mac serves, on this PC (PhoneHostFeatures): sessions and
// chats, terminals from the phone, Activity and This PC's screen.
public sealed partial class AppRuntime
{
  private readonly PhoneUploadedFiles phoneUploadedFiles = new();
  private string PhoneUploadDestination(ApprovedDevice device, string? requested, PhoneSessionsHost host)
  {
    if (device.Access == PhoneAccess.Hoot)
    {
      var state = Hoot.Read();
      if (!PhoneHootGrants.Allows(device, state) || state.Settings is not { } settings) throw new PhoneRefusal("unauthorized", "Hoot is no longer shared with this phone.");
      return PhoneWorkspacePaths.Require(requested ?? settings.Folder, [settings.Folder], false);
    }
    return PhoneWorkspacePaths.Require(requested ?? host.Folders(device).FirstOrDefault() ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), host.Folders(device), device.Access == PhoneAccess.Full);
  }
  private bool PhoneAttachmentAllowed(ApprovedDevice device, string path)
  {
    var latest = Remote.Trust.List().FirstOrDefault(d => d.Id == device.Id);
    if (latest is null || latest.Access is not (PhoneAccess.Full or PhoneAccess.Work or PhoneAccess.Hoot)) return false;
    var host = new PhoneSessionsHost(this);
    try { return string.Equals(PhoneUploadDestination(latest, Path.GetDirectoryName(path), host), PhoneWorkspacePaths.Resolve(Path.GetDirectoryName(path)!), StringComparison.OrdinalIgnoreCase); }
    catch (Exception ex) when (ex is PhoneRefusal or IOException or UnauthorizedAccessException or ArgumentException) { return false; }
  }
  private ValueTask<ChatAttachmentData[]> ReadPhoneHootAttachmentsAsync(ApprovedDevice device, IReadOnlyList<string> paths, CancellationToken ct) =>
    phoneUploadedFiles.ReadAsync(device, paths, PhoneAttachmentAllowed, ct);
  public const string PhoneScreenTitle = "Phones may view and control this PC's screen";
  public const string PhoneScreenRefusal = "This PC does not let phones view or control its screen. Turn it on at the PC: Settings › Devices › Phones may view and control this PC's screen.";
  private JsonStateStore<PhoneScreenState>? phoneScreenStore;
  private PhoneScreenState phoneScreen = new();
  public PhoneScreens? PhoneScreens { get; private set; }
  public bool PhoneScreenAllowed => Volatile.Read(ref phoneScreen).Allowed;
  public event Action<string>? PhoneScreenNotice;

  public async Task SetPhoneScreenAllowedAsync(bool allowed)
  {
    var next = new PhoneScreenState(allowed);
    phoneScreenStore?.Save(next); Volatile.Write(ref phoneScreen, next);
    // Off: every phone watching this PC is let go at once and told why.
    if (!allowed && PhoneScreens is { } screens) await screens.StopPcAsync(PhoneScreenRefusal);
    Changed?.Invoke();
  }

  private IRelayPhoneApplication WrapPhoneFeatures(IRelayPhoneApplication chain)
  {
    phoneScreenStore = new(Root, "phone-screen");
    EnsurePhoneTrace();
    try { phoneScreen = phoneScreenStore.Load() ?? new(); } catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException) { phoneScreen = new(); }
    var activity = new WindowsSystemActivity(() => WindowsSessionRoots.Read(Root, Sessions.Where(s => s.State == SessionState.Running)
      .Select(s => (CreationKey: s.CreationKey, SessionId: s.Definition.Id, Label: s.Definition.Title.Length > 0 ? s.Definition.Title : s.Definition.Provider))).Concat(WindowsSessionRoots.ReadChats(Root, Chats?.List() ?? [])).ToArray(), Root.DirectoryPath);
    var screenHost = new WindowsScreenHost();
    var screens = new PhoneScreens(screenHost, () => PhoneScreenAllowed, PhoneScreenRefusal, AndroidDeviceList.Rows, DeliverAnnotationAsync);
    screens.DeliverRecording = DeliverPhoneRecordingAsync;
    // stream step 2 / contract §11.7: This PC (and Android devices on it) as H.264 on the connection's direct link only:
    // nothing until the link has moved, never over the relay, no pictures.
    screens.Video = new WindowsScreenVideo(screenHost);
    screens.OnLink = Remote.OnLink;
    screens.AwaitsLink = Remote.AwaitsLink;
    screens.HasLink = Remote.HasLink;
    screens.Direct = Remote.SendDirect;
    screens.LinkVideo = Remote.LinkVideo;
    Remote.LinkMoved += screens.LinkMoved;
    PhoneScreens = screens;
    screens.ViewersChanged += () =>
    {
      var viewers = screens.Viewers();
      PhoneScreenNotice?.Invoke(viewers.Count == 0 ? "" : string.Join(" · ", viewers.Select(v => (v.Controlling ? "Controlled from " : "Watched from ") + v.Phone)) + ". Stop it in Settings › Devices.");
      Changed?.Invoke();
    };
    // Full control means every session and chat, now and later, like the Mac. Phones let in at Full
    // before this version get that grant too, so no hidden step stands between them and their sessions.
    foreach (var device in Remote.Trust.List().Where(d => d.Access == PhoneAccess.Full && Remote.Grants.Get(d.Id)?.Everything != true))
      Remote.Grants.Set(new(device.Id, true, [], [], [], Everything: true));
    var sessionsHost = new PhoneSessionsHost(this);
    return new PhoneHostFeatures(chain, Remote.Trust, sessionsHost, activity, screens, CreatePhoneWorkspace(sessionsHost));
  }

  // The MCP door's approve (remote.manage) lets a phone in by the same rule as the device dialog: one writer.
  public void ApprovePhone(string deviceId)
  {
    var device = Remote.Trust.Pending().Concat(Remote.Trust.List()).FirstOrDefault(d => d.Id == deviceId) ?? throw new ProtocolException("Choose a paired device before approving it.");
    var projects = Projects.List().Where(p => p.IsOpen && TaskGrants.HasProject(device, p.Id)).ToArray();
    WritePhoneSessionGrant(deviceId, projects, device.Access);
    Remote.Trust.Approve(deviceId, device.Access); Changed?.Invoke();
  }

  private void WritePhoneSessionGrant(string deviceId, TerminalDeck.Core.Projects.Project[] projects, PhoneAccess access)
  {
    // Full control: every session and chat. Work and Look only: the sessions in the ticked projects' folders.
    var folders = projects.SelectMany(p => p.Folders).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    Remote.Grants.Set(access == PhoneAccess.Full ? new(deviceId, true, [], [], [], Everything: true) : new(deviceId, true, [], folders, [], AnyAccount: true));
  }

  public string PhoneAppVersion
  {
    get
    {
      try { var version = TerminalDeck.App.Services.WindowsUpdateStatus.Version(); return version.Length is > 0 and <= 32 ? version : "windows"; }
      catch (Exception ex) when (ex is InvalidOperationException or IOException or System.Xml.XmlException) { return "windows"; }
    }
  }

  // Annotate from the phone: the still with its marks goes to Hoot, a chat, or a terminal the phone sees.
  private async ValueTask<string> DeliverAnnotationAsync(byte[] png, string note, string to, ApprovedDevice device, CancellationToken ct)
  {
    var folder = Path.Combine(Root.DirectoryPath, "phone-annotations"); TerminalDeck.Platform.Windows.WindowsPrivateDirectory.Ensure(folder);
    var path = Path.Combine(folder, DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..6] + ".png");
    await File.WriteAllBytesAsync(path, png, ct);
    var text = note.Trim().Length > 0 ? note.Trim() : "Look at this screenshot from " + device.Name + ".";
    if (to == "hoot")
    {
      if (Hoot.Read().Settings is null) throw new PhoneRefusal("unavailable", "Hoot is not set up on this PC yet.");
      // The device dialog's "Allow this phone to use Hoot" decides, as it does for hoot.say.
      if (!PhoneHootGrants.Allows(device, Hoot.Read())) throw new PhoneRefusal("unauthorized", "Hoot is not shared with this phone.");
      var image = await PhoneImageCodec.AnnotationPngAsync(png, ct);
      // Resizing is asynchronous. Consult current device access again before
      // a provider sees any content, rather than retaining an old Full grant.
      var current = Remote.Trust.List().FirstOrDefault(d => d.Id == device.Id);
      if (current is null || current.Access is not (PhoneAccess.Work or PhoneAccess.Full) || !PhoneHootGrants.Allows(current, Hoot.Read())) throw new PhoneRefusal("unauthorized", "Hoot is no longer shared with this phone.");
      var (width, height) = PngSize(image);
      var attachment = new ChatAttachmentData(Path.GetFileName(path), "image/png", image, width, height);
      await Hoot.SayWithAttachmentsAsync(Guid.NewGuid().ToString(), text, [attachment], new TerminalDeck.Core.Hoot.HootSource("person") { DeviceId = current.Id, Restricted = current.Access != PhoneAccess.Full }, ct);
      return "Sent to Hoot.";
    }
    if (Chats?.List().FirstOrDefault(c => c.Definition.Id == to && !c.Ended) is { } chat)
    {
      if (device.Access != PhoneAccess.Full && !Remote.Grants.Allows(device, ChatSessions.Session(chat))) throw new PhoneRefusal("unauthorized", "That chat is not shared with this phone.");
      var (width, height) = PngSize(png);
      var media = await Chats.AddImageAsync(chat.Definition.Id, Path.GetFileName(path), "image/png", png, width, height, ct);
      var caller = RequireCurrentAnnotationDevice(device.Id);
      if (caller.Access != PhoneAccess.Full && !Remote.Grants.Allows(caller, ChatSessions.Session(chat))) throw new PhoneRefusal("unauthorized", "That chat is no longer shared with this phone.");
      await Chats.SendAsync(chat.Definition.Id, Guid.NewGuid().ToString(), text, [media], ct);
      return "Sent to " + chat.Definition.Title + ".";
    }
    if (Sessions.FirstOrDefault(s => s.Definition.Id == to && s.State == SessionState.Running) is { } session)
    {
      if (device.Access != PhoneAccess.Full && !Remote.Grants.Allows(device, session)) throw new PhoneRefusal("unauthorized", "That session is not shared with this phone.");
      var caller = RequireCurrentAnnotationDevice(device.Id);
      if (caller.Access != PhoneAccess.Full && !Remote.Grants.Allows(caller, session)) throw new PhoneRefusal("unauthorized", "That session is no longer shared with this phone.");
      await Keeper.WriteAsync(session.Definition.Id, Encoding.UTF8.GetBytes(text.Replace('\n', ' ') + " (screenshot: " + path + ")\r"), ct);
      return "Sent to " + session.Definition.Title + ".";
    }
    throw new PhoneRefusal("unknown-session", "That session is not on this PC any more.");
  }

  private ApprovedDevice RequireCurrentAnnotationDevice(string id) => Remote.Trust.List().FirstOrDefault(d => d.Id == id && d.Access is PhoneAccess.Full or PhoneAccess.Work)
    ?? throw new PhoneRefusal("unauthorized", "This phone no longer has permission to send an annotation.");

  private static (int Width, int Height) PngSize(byte[] png) => png.Length >= 24
    ? ((png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19], (png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23]) : (0, 0);

  private sealed class PhoneSessionsHost(AppRuntime app) : IPhoneHostSessions
  {
    public event Action? Changed { add => app.Changed += value; remove => app.Changed -= value; }
    public IReadOnlyList<SessionRecord> Terminals() => app.Sessions;
    public IReadOnlyList<ChatRecord> Chats()
    {
      try { return app.Chats?.List() ?? []; } catch (Exception ex) when (ex is IOException or InvalidOperationException) { return []; }
    }
    public string? ObservedStatus(SessionRecord session) => app.HookPhoneStatus(session);
    public IChatSessions? ChatEngine => app.Chats;
    public bool SupportsAttachments => true;
    public ValueTask<ChatAttachmentData[]> AttachmentsAsync(ApprovedDevice device, IReadOnlyList<string> paths, CancellationToken ct) => app.phoneUploadedFiles.ReadAsync(device, paths, app.PhoneAttachmentAllowed, ct);
    public bool Visible(ApprovedDevice device, SessionRecord terminal) =>
      terminal.Definition.Purpose is null && (device.Access == PhoneAccess.Full || app.Remote.Grants.Allows(device, terminal));
    public bool Visible(ApprovedDevice device, ChatRecord chat) => device.Access == PhoneAccess.Full || app.Remote.Grants.Allows(device, ChatSessions.Session(chat));
    public IReadOnlyList<string> Folders(ApprovedDevice device)
    {
      var grant = app.Remote.Grants.Get(device.Id);
      IEnumerable<string> folders = device.Access == PhoneAccess.Full || grant?.Everything == true
        ? app.Projects.List().Where(p => p.IsOpen).SelectMany(p => p.Folders).Concat(app.RecentFolders())
        : grant?.Folders ?? Array.Empty<string>();
      return folders.Where(f => !string.IsNullOrWhiteSpace(f) && Directory.Exists(f)).Distinct(StringComparer.OrdinalIgnoreCase).Take(100).ToArray();
    }
    public bool MayStartIn(ApprovedDevice device, string folder) => Path.IsPathFullyQualified(folder) && Directory.Exists(folder) &&
      (device.Access == PhoneAccess.Full || app.Remote.Grants.MayStartIn(device, folder));
    public async ValueTask<SessionRecord> StartTerminalAsync(string provider, string folder, string? accountId, CancellationToken ct) =>
      await app.StartAsync(provider, folder, accountId, TerminalDeck.Core.Sessions.CustomTerminalProviders.IsKey(provider) ? app.CustomProviders.Require(provider).Name : TerminalDeck.Core.Agents.AgentSeats.ProviderName(provider));
    public async ValueTask<ChatRecord> StartChatAsync(string provider, string folder, string? accountId, ChatOptions options, AiPermissionMode? mode, CancellationToken ct)
    {
      var account = accountId is null ? app.Accounts.Preferred(provider, folder) : app.Accounts.Get(accountId);
      if (account is null || account.Provider != provider) throw new PhoneRefusal("unavailable", "Sign in to this AI on the PC first (Coding AIs).");
      var permission = mode is { } chosen && ChatPermissionModes.Supported(provider).Contains(chosen) ? chosen : app.General.NewChatPermission(provider);
      var chat = await app.Chats.CreateAsync(new(Guid.NewGuid().ToString(), provider, folder, TerminalDeck.Core.Agents.AgentSeats.ProviderName(provider), account.Id, account.HomeId,
        options, PermissionMode: permission), cancellationToken: ct);
      try { app.Projects.BindSession(chat.Definition.Id, app.Projects.Resolve(null, folder)); } catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or KeyNotFoundException) { }
      try { app.ConnectChatTools(chat.Definition.Id); } catch (Exception ex) when (ex is IOException or McpRefusal or InvalidOperationException) { }
      await app.RefreshSessionsAsync();
      return app.Chats.List().FirstOrDefault(c => c.Definition.Id == chat.Definition.Id) ?? chat;
    }
    // Close on the phone is Delete on the PC: a chat ends (kept in its archive), a terminal stops.
    public async ValueTask CloseAsync(string id, CancellationToken ct)
    {
      if (app.Chats?.List().Any(c => c.Definition.Id == id) == true) { await app.Chats.EndAsync(id, ct); await app.RefreshSessionsAsync(); }
      else await app.StopAsync(id);
    }
    public async ValueTask RenameAsync(string id, string title, CancellationToken ct)
    {
      title = title.Trim();
      if (title.Length is < 1 or > 40 || title.Any(char.IsControl)) throw new PhoneRefusal("bad-message", "Use a name of 1–40 characters on one line.");
      if (app.Sessions.Any(s => s.Definition.Id == id))
      {
        var result = await app.Keeper.RenameAsync(id, title, ct);
        if (result.Error is not null) throw new InvalidOperationException("The session could not be renamed.");
      }
      else await app.Chats.RenameAsync(id, title, ct);
      await app.RefreshSessionsAsync();
    }
    public async ValueTask<KeeperRemoteAttachment> AttachAsync(string id, CancellationToken ct) => await app.Keeper.AttachAsync(id, ct);
    public async ValueTask WriteAsync(string id, string data, CancellationToken ct) => await app.Keeper.WriteAsync(id, Encoding.UTF8.GetBytes(data), ct);
    public async ValueTask ResizeAsync(string id, TerminalSize size, CancellationToken ct) => await app.Keeper.ResizeAsync(id, size, ct);
    public IReadOnlyList<(string Id, string Name)> TerminalProviders() => app.CustomProviders.List().Where(p => p.Enabled).Select(p => (p.Id, p.Name)).ToArray();
    public IReadOnlyList<AccountProfile> Accounts() => app.Accounts.List();
    public AccountProfile? PreferredAccount(string provider, string folder) => app.Accounts.Preferred(provider, folder);
    public AiPermissionMode NewChatPermission(string provider) => app.General.NewChatPermission(provider);
  }
}
