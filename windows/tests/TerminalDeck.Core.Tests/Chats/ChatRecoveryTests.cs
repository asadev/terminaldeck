using System.Text.Json;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.Core.Tests.Chats;

[Collection("Windows chat")]
public sealed class ChatRecoveryTests
{
  [Fact] public async Task AMessageAfterStopWaitsForTheInterruptReceipt()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var chat = f.Chat.Definition.Id; var first = Guid.NewGuid().ToString(); var next = Guid.NewGuid().ToString();
    await f.Chats.SendAsync(chat, first, "hold"); f.Keeper.HoldInterrupt = true; await f.Chats.StopAsync(chat);
    Assert.True(f.Chats.Get(chat).Busy); Assert.True(f.Chats.Get(chat).Stopping);
    await f.Chats.SendAsync(chat, next, "next"); Assert.False(f.Keeper.Writes.ContainsKey(next));
    f.Keeper.HoldInterrupt = false; await f.Keeper.InterruptAsync(f.Chats.Get(chat), default);
    await ChatFixture.UntilAsync(() => f.Chats.Get(chat).Events.Count(e => e.Kind == "complete") == 2);
    Assert.Equal(new[] { first, next }, f.Chats.Get(chat).Events.Where(e => e.Kind == "complete").Select(e => e.ClientId));
    Assert.False(f.Chats.Get(chat).Stopping); Assert.Equal(1, f.Keeper.Writes[next]);
  }
  [Fact] public async Task AnotherGuidSpellingCannotOverwriteAnExistingChatHistory()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var alias = f.Chat.Definition with { Id = Guid.Parse(f.Chat.Definition.Id).ToString("N") };
    await Assert.ThrowsAsync<ArgumentException>(async () => await f.Chats.CreateAsync(alias));
    Assert.Single(f.Chats.List()); Assert.Equal(f.Chat.Definition, f.History.Load(f.Chat.Definition.Id)!.Definition);
  }
  [Fact] public async Task OneMinuteWithoutOutputShowsPlainRetryAndDoesNotResendAutomatically()
  {
    var clock = new ManualChatClock(); await using var f = new ChatFixture(clock); await f.InitializeAsync(); var chat = f.Chat.Definition.Id;
    var id = Guid.NewGuid().ToString(); await f.Chats.SendAsync(chat, id, "hold");
    clock.Advance(TimeSpan.FromSeconds(59)); Assert.Null(f.Chats.Get(chat).Problem);
    clock.Advance(TimeSpan.FromSeconds(1)); await ChatFixture.UntilAsync(() => f.Chats.Get(chat).Problem is not null);
    Assert.Equal("No answer yet. Stop and retry when you’re ready.", f.Chats.Get(chat).Problem); Assert.Equal(1, f.Keeper.Writes[id]);
    await f.Chats.RetryAsync(chat); await ChatFixture.UntilAsync(() => f.Keeper.Writes.Count == 2);
    Assert.All(f.Keeper.Writes.Values, count => Assert.Equal(1, count));
  }
  [Fact] public async Task ReconnectOnlyTouchesTheChosenChat()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var other = await f.Chats.CreateAsync("claude", f.Root.DirectoryPath, f.Account.Id);
    var before = f.Chats.Get(other.Definition.Id); await f.Chats.ReconnectAsync(f.Chat.Definition.Id);
    Assert.Equal(before, f.Chats.Get(other.Definition.Id)); Assert.Equal(0, f.Keeper.Starts);
  }
  [Fact] public async Task SavedProviderImagesAreExternalizedBeforeEventsAreJournaled()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var protocol = new ChatLineProtocol(f.Chat, f.History);
    var encoded = Convert.ToBase64String(new byte[10_000]);
    var line = JsonSerializer.Serialize(new { type = "user", message = new { content = new[] { new { type = "tool_result", tool_use_id = "image-tool", content = new[] { new { type = "image", mimeType = "image/png", data = encoded } } } } } });
    var signal = Assert.Single(protocol.Receive(line).Signals);
    Assert.Contains("media/provider-", signal.Text); Assert.DoesNotContain(encoded, signal.Text);
    var directory = Path.Combine(f.Root.DirectoryPath, "chats", Guid.Parse(f.Chat.Definition.Id).ToString("N"), "media");
    Assert.Equal(10_000, new FileInfo(Assert.Single(Directory.GetFiles(directory))).Length);
  }
}

public sealed class ManualChatClock : TimeProvider
{
  private DateTimeOffset now = new(2026, 10, 29, 0, 0, 0, TimeSpan.Zero);
  private readonly List<ManualTimer> timers = [];
  public override DateTimeOffset GetUtcNow() => now;
  public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
  { var timer = new ManualTimer(this, callback, state); timer.Change(dueTime, period); timers.Add(timer); return timer; }
  public void Advance(TimeSpan elapsed)
  { now += elapsed; foreach (var timer in timers.ToArray()) timer.Fire(); }
  private sealed class ManualTimer(ManualChatClock clock, TimerCallback callback, object? state) : ITimer
  {
    private DateTimeOffset? due;
    private TimeSpan period;
    public bool Change(TimeSpan dueTime, TimeSpan newPeriod) { due = dueTime == Timeout.InfiniteTimeSpan ? null : clock.now + dueTime; period = newPeriod; return true; }
    public void Fire() { if (due is { } when && when <= clock.now) { due = period == Timeout.InfiniteTimeSpan ? null : clock.now + period; callback(state); } }
    public void Dispose() => due = null;
    public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
  }
}
