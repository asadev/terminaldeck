using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class PhoneUploadedFilesTests : IDisposable
{
  private readonly string folder = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "phone-files-" + Guid.NewGuid().ToString("N"));
  private static readonly ApprovedDevice Phone = new("phone", "Synthetic phone", "ios", PhoneAccess.Work);
  public PhoneUploadedFilesTests() => Directory.CreateDirectory(folder);
  private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value);
  [Fact]
  public async Task OnlyCompletedOwnedUnchangedUploadsCanBecomeContentSnapshots()
  {
    var ledger = new PhoneUploadedFiles(); using var upload = new PhoneUploadFeatures((_, _) => folder, completed: ledger);
    var bytes = "%PDF-1.7\nsynthetic"u8.ToArray();
    await upload.HandleAsync("c", Phone, "upload.begin", Json(new { id = "file", name = "proof.pdf", size = bytes.Length }), null, default);
    await upload.HandleAsync("c", Phone, "upload.data", Json(new { id = "file", data = Convert.ToBase64String(bytes) }), null, default);
    var done = Assert.Single(await upload.HandleAsync("c", Phone, "upload.end", Json(new { id = "file", sha256 = Convert.ToHexString(SHA256.HashData(bytes)) }), null, default));
    var path = done["path"]!.GetValue<string>();
    using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
    await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await ledger.ReadAsync(Phone, [path], (_, _) => true, cancelled.Token));
    var files = await ledger.ReadAsync(Phone, [path], (_, _) => true, default); var file = Assert.Single(files);
    Assert.Equal(bytes, file.Data); file.Validate("claude"); Assert.Throws<ArgumentException>(() => file.Validate("codex")); Assert.Throws<ArgumentException>(() => file.Validate("gemini"));
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await ledger.ReadAsync(Phone with { Id = "foreign" }, [path], (_, _) => true, default));
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await ledger.ReadAsync(Phone, [path], (_, _) => false, default));
    await File.WriteAllBytesAsync(path, "%PDF-1.7\nDIFFERENT"u8.ToArray());
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await ledger.ReadAsync(Phone, [path], (_, _) => true, default));
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await ledger.ReadAsync(Phone, [Path.Combine(folder, "unuploaded.pdf")], (_, _) => true, default));
  }
  [Fact]
  public void CanonicalFilesHaveBoundedDistinctStringPathsAndMimeComesFromBytes()
  {
    Assert.Equal(new[] { "/owned/file" }, PhoneUploadedFiles.Paths(Json(new { files = new[] { "/owned/file" } })));
    Assert.Throws<PhoneRefusal>(() => PhoneUploadedFiles.Paths(Json(new { files = new[] { "/same", "/same" } })));
    Assert.Throws<PhoneRefusal>(() => PhoneUploadedFiles.Paths(Json(new { files = new object[] { new { path = "/notcanonical" } } })));
    Assert.Throws<PhoneRefusal>(() => PhoneUploadedFiles.Paths(Json(new { files = Enumerable.Range(0, 9).Select(i => "/" + i).ToArray() })));
    Assert.Throws<ArgumentException>(() => ChatAttachmentData.Read("fake.png", "not an image"u8.ToArray()));
    var png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8N8AAAAASUVORK5CYII=");
    var picture = ChatAttachmentData.Read("picture.png", png); Assert.Equal(1, picture.Width); Assert.Equal(1, picture.Height); picture.Validate("codex");
    Assert.Throws<ArgumentException>(() => (picture with { Width = 2049 }).Validate("claude"));
  }
  public void Dispose() => Directory.Delete(folder, true);
}
