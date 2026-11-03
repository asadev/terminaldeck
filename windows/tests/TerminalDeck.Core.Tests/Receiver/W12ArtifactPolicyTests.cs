using System.Collections.Immutable;
using TerminalDeck.Core.Receiver;

namespace TerminalDeck.Core.Tests.Receiver;

public sealed class W12ArtifactPolicyTests
{
  [Theory]
  [InlineData("plan.md")]
  [InlineData("PLAN.MARKDOWN")]
  [InlineData("program.cs")]
  [InlineData("index.tsx")]
  [InlineData("data.json")]
  [InlineData("notes.txt")]
  [InlineData("unknown.blob")]
  [InlineData(".html")]
  public void NonArtifactsStayOutOfNewAndHistoricalCatalogs(string path)
  {
    Assert.False(ArtifactCatalogPolicy.Includes(path));
    var root = Path.GetTempPath();
    var row = new ReceiverArtifact("old", "project", root, path, "session", DateTimeOffset.UtcNow);
    var index = new ReceiverArtifacts(new State(new([row])), _ => "project", (_, _) => ValueTask.CompletedTask, (_, _, _) => ValueTask.CompletedTask);
    Assert.Empty(index.List(root)); index.Record(root, path, "session", DateTimeOffset.UtcNow); Assert.Empty(index.List(root));
  }
  [Theory]
  [InlineData("page.XHTML", "Documents")]
  [InlineData("report.pdf", "Documents")]
  [InlineData("diagram.svg", "Pictures")]
  [InlineData("photo.heif", "Pictures")]
  [InlineData("demo.m4v", "Videos")]
  [InlineData("recording.flac", "Videos")]
  public void UsefulOutputTypesHaveAnExplicitCategory(string path, string kind) => Assert.Equal(kind, ArtifactCatalogPolicy.Kind(path));
  private sealed class State(ReceiverArtifactState state) : TerminalDeck.Core.Storage.IStateStore<ReceiverArtifactState>
  { public ReceiverArtifactState Load() => state; public void Save(ReceiverArtifactState next) => state = next; }
}
