using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class PhoneUploadFeaturesTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "td-upload-test-" + Guid.NewGuid().ToString("N"));
  private static readonly ApprovedDevice Device = new("device", "Phone", "ios", PhoneAccess.Work);
  public PhoneUploadFeaturesTests() => Directory.CreateDirectory(root);
  private static JsonElement Message(object value) => JsonSerializer.SerializeToElement(value);
  [Fact]
  public async Task ChunkedUploadChecksDigestDoesNotOverwriteAndIsBoundToConnection()
  {
    using var uploads = new PhoneUploadFeatures((_, _) => root);
    await File.WriteAllTextAsync(Path.Combine(root, "hello.txt"), "existing");
    var ready = Assert.Single(await uploads.HandleAsync("a", Device, "upload.begin", Message(new { id = "one", name = "hello.txt", size = 5 }), null, default));
    Assert.EndsWith("hello (1).txt", ready["path"]!.GetValue<string>());
    var foreign = Assert.Single(await uploads.HandleAsync("b", Device, "upload.end", Message(new { id = "one", sha256 = new string('0', 64) }), null, default));
    Assert.Equal("upload.failed", foreign["t"]!.GetValue<string>());
    var ack = Assert.Single(await uploads.HandleAsync("a", Device, "upload.data", Message(new { id = "one", data = Convert.ToBase64String("hello"u8.ToArray()) }), null, default));
    Assert.Equal(5, ack["bytes"]!.GetValue<int>());
    var done = Assert.Single(await uploads.HandleAsync("a", Device, "upload.end", Message(new { id = "one", sha256 = Convert.ToHexString(SHA256.HashData("hello"u8.ToArray())) }), null, default));
    Assert.Equal("upload.done", done["t"]!.GetValue<string>());
    Assert.Equal("hello", await File.ReadAllTextAsync(done["path"]!.GetValue<string>()));
    Assert.Equal("existing", await File.ReadAllTextAsync(Path.Combine(root, "hello.txt")));
  }
  [Fact]
  public async Task GrantWithdrawalDiscardsPartialAndLookCannotWrite()
  {
    var allowed = true;
    using var uploads = new PhoneUploadFeatures((_, _) => allowed ? root : throw new PhoneRefusal("unauthorized", "Revoked"));
    await uploads.HandleAsync("a", Device, "upload.begin", Message(new { id = "one", name = "hello.txt", size = 1 }), null, default);
    allowed = false;
    var result = Assert.Single(await uploads.HandleAsync("a", Device, "upload.data", Message(new { id = "one", data = "YQ==" }), null, default));
    Assert.Equal("upload.failed", result["t"]!.GetValue<string>()); Assert.Empty(Directory.GetFiles(root));
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await uploads.HandleAsync("look", Device with { Access = PhoneAccess.Look }, "upload.begin", Message(new { id = "two", name = "a.txt", size = 1 }), null, default));
  }
  [Fact]
  public async Task OverflowTimeoutAndDisconnectRemovePartialFiles()
  {
    var clock = new Clock(); using var uploads = new PhoneUploadFeatures((_, _) => root, clock);
    await uploads.HandleAsync("a", Device, "upload.begin", Message(new { id = "one", name = "one.txt", size = 1 }), null, default);
    var overflow = Assert.Single(await uploads.HandleAsync("a", Device, "upload.data", Message(new { id = "one", data = "YWI=" }), null, default));
    Assert.Equal("upload.failed", overflow["t"]!.GetValue<string>()); Assert.Empty(Directory.GetFiles(root));
    await uploads.HandleAsync("a", Device, "upload.begin", Message(new { id = "two", name = "two.txt", size = 1 }), null, default);
    clock.Now = clock.Now.AddMinutes(3);
    var timedOut = Assert.Single(await uploads.HandleAsync("a", Device, "upload.data", Message(new { id = "two", data = "YQ==" }), null, default));
    Assert.Equal("upload.failed", timedOut["t"]!.GetValue<string>()); Assert.Empty(Directory.GetFiles(root));
    await uploads.HandleAsync("a", Device, "upload.begin", Message(new { id = "three", name = "three.txt", size = 1 }), null, default);
    await uploads.DisconnectedAsync("a"); Assert.Empty(Directory.GetFiles(root));
  }
  private sealed class Clock : TimeProvider { public DateTimeOffset Now = DateTimeOffset.UnixEpoch; public override DateTimeOffset GetUtcNow() => Now; }
  public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
}
