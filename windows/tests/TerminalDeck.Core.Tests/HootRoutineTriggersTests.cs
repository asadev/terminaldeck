using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Storage;
namespace TerminalDeck.Core.Tests;
public sealed class HootRoutineTriggersTests
{
  private sealed class Store : IStateStore<HootRoutineState> { public HootRoutineState? Value; public HootRoutineState? Load() => Value; public void Save(HootRoutineState next) => Value = next; }
  [Fact] public async Task CommunityMarkdownRetainsRealTriggersAndStaysDisabledUntilExplicitlyEnabled()
  {
    var text = "# Project review\nwhen: session-finished\nwhen: file-change src/**\nin: /publisher\n---\nInspect the result.";
    var calls = 0; using var owner = new HootRoutines(new Store(), (_, ct) => { ct.ThrowIfCancellationRequested(); calls++; return ValueTask.CompletedTask; });
    var folder = Path.GetTempPath(); var id = Guid.NewGuid().ToString(); owner.Save(new(id, "Review", "", folder, 60, text));
    var saved = Assert.Single(owner.List()); Assert.Equal(new[] { "session-finished", "file-change src/**" }, saved.Triggers); Assert.False(saved.Enabled); Assert.Null(saved.NextAt);
    await owner.TriggerAsync("session-finished", folder); Assert.Equal(0, calls);
    // Use only the event trigger here: tests never attach a watcher to a real folder.
    owner.Save(saved with { Enabled = true, QuietSeconds = 0, Triggers = ["session-finished"] });
    await owner.TriggerAsync("session-finished", folder); Assert.Equal(1, calls);
    await owner.TriggerAsync("session-finished", folder); Assert.Equal(2, calls);
  }
  [Theory] [InlineData("schedule 09:00 weekdays")] [InlineData("schedule every 2h")] [InlineData("session-idle 15m")] [InlineData("alert warning")] [InlineData("manual")]
  public void SourceTriggerFormsAreAccepted(string trigger) => HootRoutines.ValidateTrigger(trigger);
  [Theory] [InlineData("schedule every 2s")] [InlineData("file-change ../../outside")] [InlineData("schedule 25:00")] [InlineData("unknown-event")]
  public void InvalidOrRunawayTriggersAreRefused(string trigger) => Assert.Throws<ArgumentException>(() => HootRoutines.ValidateTrigger(trigger));
}
