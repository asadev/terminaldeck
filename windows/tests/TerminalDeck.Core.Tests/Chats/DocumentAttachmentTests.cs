using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Chats;

public sealed class DocumentAttachmentTests
{
  [Fact] public async Task ClaudePdfStaysABinaryDocumentAndNeverBecomesAnImageBlock()
  {
    using var fixture = new Fixture("claude"); var bytes = Encoding.ASCII.GetBytes("%PDF-1.7\nsynthetic document fixture\n%%EOF");
    var media = await fixture.History.AddImageAsync(fixture.Chat.Definition.Id, "Example.pdf", "application/pdf", bytes, 0, 0, default);
    var wire = new ChatLineProtocol(fixture.Chat, fixture.History).User(new(Guid.NewGuid().ToString(), "Read this", [media]));
    using var json = JsonDocument.Parse(wire); var document = json.RootElement.GetProperty("message").GetProperty("content")[1];
    Assert.Equal("document", document.GetProperty("type").GetString()); Assert.Equal("application/pdf", document.GetProperty("source").GetProperty("media_type").GetString());
    Assert.Equal(bytes, Convert.FromBase64String(document.GetProperty("source").GetProperty("data").GetString()!));
  }
  [Theory] [InlineData("codex")] [InlineData("gemini")]
  public async Task UnsupportedAdaptersCannotSavePdfAsAnImage(string provider)
  {
    using var fixture = new Fixture(provider);
    await Assert.ThrowsAsync<ArgumentException>(async () => await fixture.History.AddImageAsync(fixture.Chat.Definition.Id, "Example.pdf", "application/pdf", "%PDF-1.7"u8.ToArray(), 0, 0, default));
  }
  [Fact] public async Task InvalidAndOversizePdfNeverReachTheProvider()
  {
    using var fixture = new Fixture("claude");
    await Assert.ThrowsAsync<ArgumentException>(async () => await fixture.History.AddImageAsync(fixture.Chat.Definition.Id, "Fake.pdf", "application/pdf", "not-pdf"u8.ToArray(), 0, 0, default));
    var huge = new byte[500001]; "%PDF-"u8.CopyTo(huge); await Assert.ThrowsAsync<ArgumentException>(async () => await fixture.History.AddImageAsync(fixture.Chat.Definition.Id, "Huge.pdf", "application/pdf", huge, 0, 0, default));
  }
  private sealed class Fixture : IDisposable
  {
    private readonly string directory = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "td-pdf-test-" + Guid.NewGuid().ToString("N"));
    public ChatHistory History { get; } public ChatRecord Chat { get; }
    public Fixture(string provider)
    {
      History = new(AppDataRoot.Explicit(directory)); Chat = new(1, new(Guid.NewGuid().ToString(), provider, directory, "Synthetic", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), new()), Guid.NewGuid().ToString("N"), [], []); History.Save(Chat);
    }
    public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
  }
}
