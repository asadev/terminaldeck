using TerminalDeck.Core.Notifications;
using TerminalDeck.Core.Storage;
namespace TerminalDeck.Core.Tests.Notifications;
public sealed class SessionNotificationsTests
{
  private sealed class Store : IStateStore<NotificationPreferences> { public NotificationPreferences? Value; public NotificationPreferences? Load() => Value; public void Save(NotificationPreferences value) => Value = value; }
  private sealed class Sink : ISessionNotificationSink
  {
    public List<(SessionNotice Notice, string Sound)> Rows = [];
    public ValueTask ShowAsync(SessionNotice notice, string sound, CancellationToken ct) { ct.ThrowIfCancellationRequested(); Rows.Add((notice, sound)); return ValueTask.CompletedTask; }
  }
  [Fact] public async Task RealStateTransitionsNotifyOnceWithoutReplayingOldSessionsAndRespectPreferences()
  {
    var store = new Store(); var sink = new Sink(); var focused = false; var owner = new SessionNotifications(store, sink, () => focused);
    await owner.ObserveAsync(new("old", "Old session", false, false)); Assert.Empty(sink.Rows);
    await owner.ObserveAsync(new("new", "New session", true, false)); await owner.ObserveAsync(new("new", "New session", false, true, Detail: "Private confirmation"));
    Assert.Equal("needs-you", Assert.Single(sink.Rows).Notice.Kind); Assert.DoesNotContain("Private", sink.Rows[0].Notice.Detail);
    await owner.ObserveAsync(new("new", "New session", false, true)); Assert.Single(sink.Rows);
    owner.Save(owner.Read() with { Sound = "none", Finished = false });
    await owner.ObserveAsync(new("new", "New session", true, false)); await owner.ObserveAsync(new("new", "New session", false, false)); Assert.Single(sink.Rows);
    focused = true; await owner.NotifyAsync(new("focused", "new", "needs-you", "Session", "", DateTimeOffset.UtcNow)); Assert.Single(sink.Rows);
    owner.Save(owner.Read() with { OnlyWhenAway = false, Preview = true });
    await owner.NotifyAsync(new("allowed", "new", "needs-you", "Session", "A short preview", DateTimeOffset.UtcNow));
    Assert.Equal("none", sink.Rows[1].Sound); Assert.Equal("A short preview", sink.Rows[1].Notice.Detail);
    await owner.NotifyAsync(new("allowed", "new", "needs-you", "Session", "Repeated event", DateTimeOffset.UtcNow)); Assert.Equal(2, sink.Rows.Count);
  }
  [Fact] public async Task CancellationDoesNotEmitAndUnsupportedSoundsCannotBeSaved()
  {
    var owner = new SessionNotifications(new Store(), new Sink(), () => false);
    Assert.Throws<ArgumentException>(() => owner.Save(new(Sound: "custom-executable")));
    using var stop = new CancellationTokenSource(); stop.Cancel();
    await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await owner.NotifyAsync(new("cancelled", "s", "finished", "Session", "", DateTimeOffset.UtcNow), stop.Token));
  }
}
