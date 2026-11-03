using System.Runtime.InteropServices;
using System.Security;
using System.Text.Json;
using Microsoft.Windows.AppNotifications;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Notifications;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  public SessionNotifications Notifications { get; private set; } = null!;
  public event Action<string>? NotificationFailed;
  public event Action<string, string>? NotificationOpenRequested;
  private bool desktopNotificationsInitialized;
  private int notificationDirty;
  private int notificationRefreshing;
  private volatile bool notificationDisposed;
  private void InitializeSessionNotifications()
  {
    if (desktopNotificationsInitialized) return; desktopNotificationsInitialized = true; notificationDisposed = false;
    Notifications = new(new JsonStateStore<NotificationPreferences>(Root, "notifications"), new WindowsNotificationSink(), WindowsNotificationSink.IsOurForeground);
    Changed += DesktopNotificationSessionsChanged;
    Hoot.Changed += DesktopNotificationHootChanged;
    try { AppNotificationManager.Default.NotificationInvoked += DesktopNotificationInvoked; AppNotificationManager.Default.Register(); } catch (Exception e) when (e is COMException or InvalidOperationException) { NotificationFailed?.Invoke("Windows notifications could not register. Check Windows notification settings."); }
    Door.Register("notifications.read", (context, args, ct) => { context.Require("settings", "notifications"); return ValueTask.FromResult(JsonSerializer.SerializeToElement(Notifications.Read())); });
    Door.Register("notifications.set", async (context, args, ct) =>
    {
      context.Require("settings", "notifications"); await context.EnsureCurrentAsync(ct);
      var value = JsonSerializer.SerializeToNode(Notifications.Read(), new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase })!.AsObject();
      foreach (var field in args.EnumerateObject()) value[field.Name] = System.Text.Json.Nodes.JsonNode.Parse(field.Value.GetRawText());
      return JsonSerializer.SerializeToElement(Notifications.Save(value.Deserialize<NotificationPreferences>(new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!));
    });
    Door.Register("notifications.test", async (context, args, ct) =>
    {
      context.Require("settings", "notifications"); await context.EnsureCurrentAsync(ct); var kind = args.GetProperty("kind").GetString();
      if (kind == "settings") return JsonSerializer.SerializeToElement(new NotificationTestResult(await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:notifications")), "Windows notification settings requested."));
      return JsonSerializer.SerializeToElement(await Notifications.TestAsync(kind == "sound", ct));
    });
    DesktopNotificationSessionsChanged();
  }
  private void DesktopNotificationHootChanged(TerminalDeck.Core.Hoot.HootState state) => DesktopNotificationSessionsChanged();
  private void DesktopNotificationInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args)
  {
    var pieces = args.Argument.Split(':', 2); if (pieces.Length != 2 || pieces[1].Length > 128 || pieces[1].Any(char.IsControl)) return;
    var kind = pieces[0]; var id = pieces[1];
    var valid = kind switch { "session" => Sessions.Any(s => s.Definition.Id == id) || Chats.List().Any(c => c.Definition.Id == id), "task" => Tasks.List(new TerminalDeck.Core.Tasks.TaskFilter(Status: "all")).Any(t => t.Id == id), "hoot" => id == "main", _ => false };
    if (valid) NotificationOpenRequested?.Invoke(kind, id);
  }
  private void DisposeSessionNotifications()
  {
    if (!desktopNotificationsInitialized) return; desktopNotificationsInitialized = false; notificationDisposed = true;
    Changed -= DesktopNotificationSessionsChanged; Hoot.Changed -= DesktopNotificationHootChanged;
    try { AppNotificationManager.Default.NotificationInvoked -= DesktopNotificationInvoked; AppNotificationManager.Default.Unregister(); }
    catch (Exception e) when (e is COMException or InvalidOperationException) { }
  }
  private readonly HashSet<string> notifiedTaskComments = [];
  private bool taskNotificationBaseline;
  private void DesktopNotificationSessionsChanged()
  {
    if (notificationDisposed) return;
    Interlocked.Exchange(ref notificationDirty, 1);
    if (Interlocked.CompareExchange(ref notificationRefreshing, 1, 0) != 0) return;
    try
    {
      do { Interlocked.Exchange(ref notificationDirty, 0); if (!notificationDisposed) RefreshDesktopNotificationSessions(); }
      while (!notificationDisposed && Volatile.Read(ref notificationDirty) != 0);
    }
    finally
    {
      Volatile.Write(ref notificationRefreshing, 0);
      if (!notificationDisposed && Volatile.Read(ref notificationDirty) != 0) DesktopNotificationSessionsChanged();
    }
  }
  private void RefreshDesktopNotificationSessions()
  {
    if (Notifications is null) return;
    foreach (var chat in Chats.List().Where(c => c.Definition.Id != Hoot.Read().ChatId))
    {
      var waiting = chat.Problem is not null || ChatProjection.Rows(chat).Any(r => r.Kind == "approval" && r.Waiting);
      _ = ObserveDesktopNoticeAsync(new(chat.Definition.Id, chat.Definition.Title, chat.Busy, waiting, chat.Ended, chat.Problem));
    }
    if (Tasks is not null)
    {
      foreach (var task in Tasks.List(new TerminalDeck.Core.Tasks.TaskFilter(Status: "all")))
        foreach (var comment in task.Comments.IsDefault ? [] : task.Comments)
          if (notifiedTaskComments.Add(comment.Id) && taskNotificationBaseline && !comment.Mentions.IsDefault && comment.Mentions.Contains("me"))
            _ = SendDesktopTaskNoticeAsync(new("task:" + comment.Id, task.Id, "mention", task.Title, comment.Text, comment.At));
      taskNotificationBaseline = true;
    }
    var hoot = Hoot.Read();
    _ = ObserveDesktopNoticeAsync(new("hoot", "Hoot", hoot.Busy, hoot.Lines.Any(l => l.Kind == "approval" && l.Waiting), Detail: hoot.Problem, Hoot: true));
  }
  private async Task SendDesktopTaskNoticeAsync(SessionNotice notice)
  { try { await Notifications.NotifyAsync(notice); } catch (Exception e) when (e is COMException or IOException or InvalidOperationException) { NotificationFailed?.Invoke("Windows could not show the task notification."); } }
  private async Task ObserveDesktopNoticeAsync(SessionNotificationObservation observation)
  {
    try { await Notifications.ObserveAsync(observation); }
    catch (Exception e) when (e is COMException or InvalidOperationException or IOException) { NotificationFailed?.Invoke("Windows could not show a notification. Check its notification settings."); }
  }
  private sealed class WindowsNotificationSink : ISessionNotificationSink
  {
    [DllImport("winmm.dll", EntryPoint = "PlaySoundW", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PlaySound(IntPtr sound, IntPtr module, uint flags);
    private static Task<bool> PlayNotificationSoundAsync(string sound, CancellationToken ct) => Task.Run(() =>
    {
      ct.ThrowIfCancellationRequested(); var bytes = NotificationSounds.Wave(sound); var pinned = GCHandle.Alloc(bytes, GCHandleType.Pinned);
      try { return PlaySound(pinned.AddrOfPinnedObject(), IntPtr.Zero, 0x0004 | 0x0002); }
      finally { pinned.Free(); }
    }, ct);
    public async ValueTask<NotificationTestResult> TestAsync(string sound, bool soundOnly, CancellationToken ct)
    {
      ct.ThrowIfCancellationRequested();
      if (soundOnly) return sound == "none" ? new(false, "Choose a sound before testing it.") : await PlayNotificationSoundAsync(sound, ct) ? new(true, "Sound played through Windows. Check your output volume if you did not hear it.") : new(false, "Windows could not play the sound. Check the selected audio output.");
      var banner = new AppNotification("<toast><visual><binding template=\"ToastGeneric\"><text>Notification check</text><text>This banner was requested from Notifications settings.</text></binding></visual><audio silent=\"true\"/></toast>");
      AppNotificationManager.Default.Show(banner);
      return banner.Id != 0 ? new(true, "Windows accepted the test banner. If it did not appear, check Focus and notification settings.") : new(false, "Windows did not accept the banner. Open Windows notification settings.");
    }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    public static bool IsOurForeground() { GetWindowThreadProcessId(GetForegroundWindow(), out var pid); return pid == Environment.ProcessId; }
    public ValueTask ShowAsync(SessionNotice notice, string sound, CancellationToken ct)
    {
      ct.ThrowIfCancellationRequested();
      const string audio = "<audio silent=\"true\"/>";
      var title = notice.Kind == "needs-you" ? notice.Title + " needs you" : notice.Kind == "hoot" ? "Hoot replied" : notice.Kind == "mention" ? "Task mention" : notice.Title + " finished";
      var route = notice.Kind == "mention" ? "task:" + notice.SessionId : notice.SessionId == "hoot" ? "hoot:main" : "session:" + notice.SessionId;
      var xml = "<toast launch=\"" + SecurityElement.Escape(route) + "\"><visual><binding template=\"ToastGeneric\"><text>" + SecurityElement.Escape(title) + "</text><text>" + SecurityElement.Escape(notice.Detail) + "</text></binding></visual>" + audio + "</toast>";
      AppNotificationManager.Default.Show(new AppNotification(xml));
      if (sound != "none") _ = PlayNotificationSoundAsync(sound, ct); return ValueTask.CompletedTask;
    }
  }
}
