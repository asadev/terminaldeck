using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Receiver;

public sealed class W12ArtifactRootsTests : IDisposable
{
  private readonly string root = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "td-w12-artifact-" + Guid.NewGuid().ToString("N"));
  public W12ArtifactRootsTests() => Directory.CreateDirectory(root);
  public void Dispose() => Directory.Delete(root, true);
  [Fact] public void IndependentAndClosedProjectOutputsRemainDiscoverableWithoutScanning()
  {
    File.WriteAllText(Path.Combine(root, "result.html"), "<h1>Output</h1>");
    var store = new JsonStateStore<ReceiverArtifactState>(AppDataRoot.Explicit(root), "artifacts");
    ReceiverArtifacts Index(Func<string, string?> project) => new(store, project, (_, _) => ValueTask.CompletedTask, (_, _, _) => ValueTask.CompletedTask);
    var index = Index(_ => null); index.Record(root, "result.html", "independent-session", DateTimeOffset.UtcNow);
    Assert.Equal("independent", Assert.Single(index.Roots()).ProjectId); Assert.Single(index.List(root));
    var recovered = Index(_ => null); Assert.Equal("<h1>Output</h1>", recovered.Preview(root, "result.html").Text);
    Assert.Throws<ArgumentException>(() => recovered.List(Path.GetDirectoryName(root)!));
    File.Delete(Path.Combine(root, "result.html")); Assert.Single(recovered.List(root));
    Assert.Throws<IOException>(() => recovered.Preview(root, "result.html"));
    recovered.Remove(root, "result.html"); Assert.Empty(recovered.Roots());
  }
  [Fact] public void TrustedWriteReceiptRegistersAnExactOutsideOutputWithoutPermittingTraversal()
  {
    var project = Path.Combine(root, "project"); var scratch = Path.Combine(root, "scratch"); Directory.CreateDirectory(project); Directory.CreateDirectory(scratch);
    File.WriteAllText(Path.Combine(scratch, "page.html"), "<h1>Produced outside</h1>"); File.WriteAllText(Path.Combine(scratch, "other.html"), "Unrecorded");
    var store = new JsonStateStore<ReceiverArtifactState>(AppDataRoot.Explicit(root), "outside");
    var index = new ReceiverArtifacts(store, cwd => cwd == project ? "project" : null, (_, _) => ValueTask.CompletedTask, (_, _, _) => ValueTask.CompletedTask);
    index.Record(project, "../scratch/page.html", "session", DateTimeOffset.UtcNow);
    var output = Assert.Single(index.List(scratch)); Assert.Equal("project", output.ProjectId); Assert.Equal("page.html", output.RelPath);
    Assert.Equal("<h1>Produced outside</h1>", index.Preview(scratch, "page.html").Text);
    Assert.Throws<ArgumentException>(() => index.Preview(scratch, "other.html"));
    Assert.Throws<ArgumentException>(() => index.Preview(project, "../scratch/page.html"));
    index.Record(project, "../scratch/page.html", "session", DateTimeOffset.UtcNow); Assert.Single(index.List(scratch));
  }
}
