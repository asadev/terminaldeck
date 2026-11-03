using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Integration;

namespace TerminalDeck.Core.Tests.Integration;

public sealed class W9ArtifactTests
{
  private static ChatRecord Chat(params ChatEvent[] events) => new(1, new(Guid.NewGuid().ToString(), "codex", "/scratch", "fixture", new string('a', 32), new string('a', 32), new()), Guid.NewGuid().ToString("N"), events, []);
  [Fact]
  public void CompletedFileChangeCarriesItsSessionProvenanceOnlyOnce()
  {
    var chat = Chat(new ChatEvent(5, "toolResult", "write", Data: JsonSerializer.SerializeToElement(new { type = "fileChange", status = "completed", changes = new[] { new { path = "result.md" } } })));
    Assert.Equal("result.md", Assert.Single(W9ArtifactWrites.Read(chat, 4)).Path);
    Assert.Empty(W9ArtifactWrites.Read(chat, 5));
  }
  [Theory]
  [InlineData("failed")]
  [InlineData("inProgress")]
  public void FailedOrUnfinishedWriteCannotCreateAnArtifact(string status)
  {
    var chat = Chat(new ChatEvent(1, "toolResult", "write", Data: JsonSerializer.SerializeToElement(new { type = "fileChange", status, changes = new[] { new { path = "secret.txt" } } })));
    Assert.Empty(W9ArtifactWrites.Read(chat, 0));
  }
  [Fact]
  public void MentioningAFileOrRunningACommandIsNotAWriteReceipt()
  {
    Assert.Empty(W9ArtifactWrites.Read(Chat(new ChatEvent(1, "message", "answer", "I wrote result.md"), new ChatEvent(2, "toolResult", "shell", Data: JsonSerializer.SerializeToElement(new { type = "commandExecution", status = "completed", path = "result.md" }))), 0));
  }
}
