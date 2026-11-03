using TerminalDeck.Core.Platform;

namespace TerminalDeck.Core.Tests.Sessions;

public sealed class KeeperBuildTests
{
  private const string Older = @"C:\Program Files\WindowsApps\TerminalDeck_0.20.3.1_x64__6wvt5fg33ztg8\keeper\20261102080815344\TerminalDeck.Keeper.exe";
  private const string Own = @"C:\Program Files\WindowsApps\TerminalDeck_0.20.4.1_x64__6wvt5fg33ztg8\keeper\20261102154340513\TerminalDeck.Keeper.exe";

  // 3 Nov, umar-pc: the 0.20.4.1 app ran on 0.20.3.1's keeper because Windows applied the update itself.
  [Fact]
  public void OnlyAnOlderBuildsKeeperMovesToThisBuild()
  {
    Assert.Equal("20261102080815344", KeeperBuild.Stamp(Older));
    Assert.True(KeeperBuild.IsOlder(Older, Own));
    // Review #27 item 6: a NEWER keeper (an older app copy sharing the data root) is never moved onto an older one.
    Assert.False(KeeperBuild.IsOlder(Own, Older));
    Assert.False(KeeperBuild.IsOlder(Own, Own));
    Assert.False(KeeperBuild.IsOlder(Own.ToUpperInvariant(), Own));
    // Unknown is never "older": a keeper is not handed over on a guess.
    Assert.False(KeeperBuild.IsOlder(null, Own));
    Assert.False(KeeperBuild.IsOlder("", Own));
    Assert.False(KeeperBuild.IsOlder(@"C:\dev\keeper\TerminalDeck.Keeper.exe", Own));
    Assert.False(KeeperBuild.IsOlder(Older, @"C:\loose\TerminalDeck.Keeper.exe"));
  }

  // Review #27 item 4: a hand-over that fails (refused, or the keeper exits too slowly) must not leave the app refusing
  // every keeper connection; a successful one holds until the caller resumes.
  [Fact]
  public async Task AFailedHandOverEndsTheHandOverState()
  {
    var handover = new KeeperHandover();
    await Assert.ThrowsAsync<IOException>(() => handover.RunAsync(() => Task.CompletedTask, () => throw new IOException("The session service did not close for the update.")));
    Assert.False(handover.Active);
    await Assert.ThrowsAsync<InvalidOperationException>(() => handover.RunAsync(() => throw new InvalidOperationException("refused"), () => Task.CompletedTask));
    Assert.False(handover.Active);
    await handover.RunAsync(() => Task.CompletedTask, () => Task.CompletedTask);
    Assert.True(handover.Active);
    handover.Done();
    Assert.False(handover.Active);
  }
}
