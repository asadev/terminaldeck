using TerminalDeck.Core.Platform;

namespace TerminalDeck.Core.Tests.Platform;

// Reviewer #9 (4 Nov): the automatic update looked at the PC once, then downloaded ~270 MB for minutes, then forced
// the restart. Now it looks again after the download, right before the restart, and waits if anyone or any AI is busy.
public sealed class UpdateRestartOrderTests
{
  private sealed class Script(params string?[] answers)
  {
    private int next;
    public readonly List<string> Steps = [];
    public Task<string?> WaitReason() { var answer = answers[Math.Min(next++, answers.Length - 1)]; Steps.Add("look:" + (answer ?? "free")); return Task.FromResult(answer); }
    public Task Prepare() { Steps.Add("download"); return Task.CompletedTask; }
    public Task Restart() { Steps.Add("restart"); return Task.CompletedTask; }
  }

  [Fact]
  public async Task SomebodyArrivingDuringTheDownloadStopsTheRestart()
  {
    var s = new Script(null, "someone is using this PC");
    string? said = null;
    var outcome = await UpdateReadiness.RestartWhenFreeAsync(s.WaitReason, true, s.Prepare, s.Restart, reason => said = reason);
    Assert.Equal(UpdateReadiness.AutomaticRestart.Waiting, outcome);
    Assert.Equal(new[] { "look:free", "download", "look:someone is using this PC" }, s.Steps);
    Assert.Equal("someone is using this PC", said);
  }

  [Fact]
  public async Task AnAiStartingATurnDuringTheDownloadStopsTheRestart()
  {
    var s = new Script(null, "Claude is working");
    var outcome = await UpdateReadiness.RestartWhenFreeAsync(s.WaitReason, true, s.Prepare, s.Restart, _ => { });
    Assert.Equal(UpdateReadiness.AutomaticRestart.Waiting, outcome);
    Assert.DoesNotContain("restart", s.Steps);
  }

  [Fact]
  public async Task QuietBeforeAndAfterTheDownloadRestartsLookingLast()
  {
    var s = new Script(null, null);
    var outcome = await UpdateReadiness.RestartWhenFreeAsync(s.WaitReason, true, s.Prepare, s.Restart, _ => { });
    Assert.Equal(UpdateReadiness.AutomaticRestart.Restarted, outcome);
    Assert.Equal(new[] { "look:free", "download", "look:free", "restart" }, s.Steps);
  }

  [Fact]
  public async Task BusyAtTheFirstLookDownloadsNothing()
  {
    var s = new Script("a chat is answering");
    var outcome = await UpdateReadiness.RestartWhenFreeAsync(s.WaitReason, true, s.Prepare, s.Restart, _ => { });
    Assert.Equal(UpdateReadiness.AutomaticRestart.Waiting, outcome);
    Assert.Equal(new[] { "look:a chat is answering" }, s.Steps);
  }

  [Fact]
  public async Task MovingSessionsToANewKeeperNeedsNoDownload()
  {
    var s = new Script((string?)null);
    var outcome = await UpdateReadiness.RestartWhenFreeAsync(s.WaitReason, false, s.Prepare, s.Restart, _ => { });
    Assert.Equal(UpdateReadiness.AutomaticRestart.Restarted, outcome);
    Assert.Equal(new[] { "look:free", "restart" }, s.Steps);
  }
}
