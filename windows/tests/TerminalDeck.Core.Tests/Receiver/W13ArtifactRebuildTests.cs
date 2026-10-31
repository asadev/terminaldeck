using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Tests.Sessions;
namespace TerminalDeck.Core.Tests.Receiver;
public sealed class W13ArtifactRebuildTests
{
  [Fact]
  public void HistoricalReceiptsAreIdempotentAndPreserveHiddenItemsUntilANewWrite()
  {
    var folder = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "w13-artifact-" + Guid.NewGuid()); Directory.CreateDirectory(folder);
    try
    {
      File.WriteAllText(Path.Combine(folder, "report.html"), "<p>Review</p>");
      var store = new MemoryState<ReceiverArtifactState>();
      var artifacts = new ReceiverArtifacts(store, _ => "project", (_, _) => ValueTask.CompletedTask, (_, _, _) => ValueTask.CompletedTask);
      var at = DateTimeOffset.UtcNow;
      artifacts.Record(folder, "report.html", "session", at); var id = artifacts.List(folder).Single().Id;
      artifacts.Remove(folder, "report.html");
      artifacts.Record(folder, "report.html", "session", at); artifacts.Record(folder, "report.html", "session", at.AddSeconds(-1));
      Assert.Empty(artifacts.List(folder)); Assert.Single(store.Value!.Artifacts); Assert.True(store.Value.Artifacts[0].Hidden);
      artifacts.Record(folder, "report.html", "session", at.AddSeconds(1));
      Assert.Equal(id, artifacts.List(folder).Single().Id);
    }
    finally { Directory.Delete(folder, true); }
  }
}
