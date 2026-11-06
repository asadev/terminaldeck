using System.Text.Json;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.Core.Tests.Chats;

public sealed class ChatRichContentTests
{
  [Fact] public void GfmRetainsTableListsTasksFootnotesMathAndStrikethrough()
  {
    var source = "| A | B |\n|---|---|\n| one | two |\n\n1. Outer\n   - Inner\n\n- [x] Checked\n\n~~removed~~ [note][^1]\n\n[^1]: Footnote\n\n$x^2$\n\n$$\nx^2\n$$";
    var html = ChatRichContent.Html(source);
    Assert.Contains("<table", html); Assert.Contains("<ol", html); Assert.Contains("<ul", html);
    Assert.Contains("checkbox", html); Assert.Contains("<del>", html); Assert.Contains("footnote", html); Assert.Contains("math", html);
  }
  [Fact] public void AStreamingVisualCannotExecuteBeforeItsFenceCloses()
  {
    var partial = "```visual\n<script>console.log('draw')</script>";
    Assert.DoesNotContain("data-kind=\"visual\"", ChatRichContent.Html(partial));
    var closed = partial + "\n```";
    Assert.Contains("data-kind=\"visual\"", ChatRichContent.Html(closed));
    Assert.DoesNotContain("<script>", ChatRichContent.Html(closed));
    Assert.False(ChatRichContent.Blocks(partial).Single().Complete);
    Assert.True(ChatRichContent.Blocks(closed).Single().Complete);
    Assert.Equal("<script>console.log('draw')</script>", ChatRichContent.Blocks(closed).Single().Source.TrimEnd());
  }
  [Fact] public void RawHtmlAndUnsafeLinksNeverBecomeActiveAppMarkup()
  {
    var html = ChatRichContent.Html("<script>alert(1)</script>\n\n[bad](javascript:alert)\n\n![bad](file:///outside.png)");
    Assert.DoesNotContain("<script>", html); Assert.DoesNotContain("href=\"javascript:", html); Assert.DoesNotContain("src=\"file:", html);
  }
  [Fact] public void SessionImagesCannotEscapeThroughAParentOrLinkedPath()
  {
    var folder = Path.Combine(Path.GetTempPath(), "td-chat-image-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(folder);
    try
    {
      File.WriteAllBytes(Path.Combine(folder, "photo.png"), [137, 80, 78, 71]);
      Assert.StartsWith("data:image/png;base64,", ChatRichContent.ImageUrl("photo.png", folder));
      Assert.Empty(ChatRichContent.ImageUrl("../photo.png", folder));
      Assert.Empty(ChatRichContent.ImageUrl("file:///etc/passwd", folder));
      Assert.Equal("https://example.test/photo.png", ChatRichContent.ImageUrl("https://example.test/photo.png", folder));
    }
    finally { Directory.Delete(folder, true); }
  }
  [Fact] public void McpAppMetadataUsesTheStandardAndLegacyUriKeys()
  {
    Assert.Equal("ui://chart", ChatMcpApps.ResourceUri(JsonSerializer.Deserialize<JsonElement>("{\"ui\":{\"resourceUri\":\"ui://chart\"}}")));
    Assert.Equal("ui://chart", ChatMcpApps.ResourceUri(JsonSerializer.Deserialize<JsonElement>("{\"ui/resourceUri\":\"ui://chart\"}")));
    Assert.Null(ChatMcpApps.ResourceUri(JsonSerializer.Deserialize<JsonElement>("{\"ui\":{\"resourceUri\":\"https://example.test\"}}")));
  }
  [Fact] public async Task MessageForkCopiesAllHistoryAndMediaWithoutMutatingTheSource()
  {
    await using var fixture = new ChatFixture(); await fixture.InitializeAsync();
    var image = await fixture.Chats.AddImageAsync(fixture.Chat.Definition.Id, "image.png", "image/png", new byte[] { 137, 80, 78, 71 }, 1, 1);
    var original = fixture.Chat with { Events = [new(1, "user", "u", "Question", ClientId: "u"), new(2, "message", "a", "Answer")], Messages = [new("u", "Question", [image], ChatMessageState.Sent)] };
    fixture.History.Save(original); await fixture.RestartAsync();
    var child = await fixture.Chats.BranchAsync(original.Definition.Id, "a", false);
    Assert.NotEqual(original.Definition.Id, child.Definition.Id); Assert.Equal(original.Events, child.Events);
    Assert.Equal(fixture.Chats.ReadImage(original.Definition.Id, image), fixture.Chats.ReadImage(child.Definition.Id, image));
    Assert.Equal(original.Events, fixture.Chats.Get(original.Definition.Id).Events); Assert.True(child.ReplayHistory); Assert.Null(child.ConversationId);
    Assert.Contains("Question", ChatRichContent.Prompt(child, "Continue")); Assert.Contains("Answer", ChatRichContent.Prompt(child, "Continue"));
  }
  [Fact] public async Task RewindKeepsTheWholeOriginalAndARejectedSelectionChangesNothing()
  {
    await using var fixture = new ChatFixture(); await fixture.InitializeAsync();
    var original = fixture.Chat with { Events = [new(1, "user", "u", "Question", ClientId: "u"), new(2, "message", "a", "Answer"), new(3, "user", "u2", "Another", ClientId: "u2")], Messages = [new("u", "Question", [], ChatMessageState.Sent), new("u2", "Another", [], ChatMessageState.Sent)] };
    fixture.History.Save(original); await fixture.RestartAsync();
    var before = fixture.Chats.Get(original.Definition.Id);
    await Assert.ThrowsAsync<ArgumentException>(async () => await fixture.Chats.BranchAsync(original.Definition.Id, "absent", true));
    Assert.Equal(before, fixture.Chats.Get(original.Definition.Id));
    var rewound = await fixture.Chats.BranchAsync(original.Definition.Id, "u2", true);
    Assert.Equal(2, rewound.Events.Length);
    Assert.Contains(fixture.Chats.List(), c => c.Ended && c.Events.Length == 3 && c.Definition.Id != original.Definition.Id);
  }
}
