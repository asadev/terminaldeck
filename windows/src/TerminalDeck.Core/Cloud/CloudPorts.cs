using System.Net.Http.Headers;
using System.Security.Cryptography;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Cloud;

// What the account needs from the platform, passed in so the account itself stays platform-neutral and testable.

/// The one protected record holding the sign-in and this device's private keys. `Read` returns null only when
/// nothing is saved; every other failure throws.
public interface ICloudSecretStore
{
  bool Exists { get; }
  byte[]? Read();
  void Write(ReadOnlySpan<byte> plaintext);
  void Remove();
}
public interface ICloudRandom { void Fill(Span<byte> buffer); }
public sealed record CloudHttpRequest(HttpMethod Method, Uri Url, IReadOnlyDictionary<string, string> Headers, byte[] Body)
{
  // Headers carry the bearer token: never print them.
  public override string ToString() => Method + " " + Url.AbsolutePath;
}
public sealed record CloudHttpResponse(int Status, byte[] Body);
public interface ICloudHttp { Task<CloudHttpResponse> SendAsync(CloudHttpRequest request, CancellationToken ct); }
/// Opens the person's default browser. Only the account calls it, and only after the person's Sign in press.
public interface ICloudBrowser { Task OpenAsync(Uri url, CancellationToken ct); }
public sealed class SystemCloudRandom : ICloudRandom { public void Fill(Span<byte> buffer) => RandomNumberGenerator.Fill(buffer); }

/// The record is encrypted with the platform protector (Windows: DPAPI, current user, `CurrentUserDpapi`) before it
/// touches the disk, and lives in the app's local (never roaming) data folder. The folder is made only on the first
/// write, which is the person's own sign-in.
public sealed class ProtectedCloudSecretStore(string path, IDataProtector protector) : ICloudSecretStore
{
  public static ProtectedCloudSecretStore For(AppDataRoot root, IDataProtector protector) => new(Path.Combine(root.DirectoryPath, "cloud", "account.protected"), protector);
  public bool Exists => File.Exists(path);
  public byte[]? Read() => File.Exists(path) ? protector.Unprotect(File.ReadAllBytes(path)) : null;
  public void Write(ReadOnlySpan<byte> plaintext)
  {
    var sealedBytes = protector.Protect(plaintext);
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
    try { File.WriteAllBytes(temp, sealedBytes); File.Move(temp, path, overwrite: true); }
    finally { if (File.Exists(temp)) File.Delete(temp); }
  }
  public void Remove() { if (File.Exists(path)) File.Delete(path); }
}

/// HTTPS only, no redirects, bounded answers.
public sealed class HttpClientCloudHttp : ICloudHttp, IDisposable
{
  private readonly HttpClient client = new(new SocketsHttpHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromSeconds(30) };
  public async Task<CloudHttpResponse> SendAsync(CloudHttpRequest request, CancellationToken ct)
  {
    if (request.Url.Scheme != "https") throw new CloudFailure("unsafe_configuration");
    using var message = new HttpRequestMessage(request.Method, request.Url);
    if (request.Body.Length > 0 || request.Method == HttpMethod.Post)
    {
      message.Content = new ByteArrayContent(request.Body);
      if (request.Headers.TryGetValue("content-type", out var type)) message.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(type);
    }
    foreach (var (name, value) in request.Headers.Where(h => h.Key != "content-type")) message.Headers.TryAddWithoutValidation(name, value);
    using var response = await client.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, ct);
    await using var stream = await response.Content.ReadAsStreamAsync(ct);
    var buffer = new MemoryStream(); var chunk = new byte[16_384]; int read;
    while ((read = await stream.ReadAsync(chunk, ct)) > 0)
    {
      if (buffer.Length + read > CloudWire.MaximumBodyBytes) throw new CloudFailure("invalid_response");
      buffer.Write(chunk, 0, read);
    }
    return new((int)response.StatusCode, buffer.ToArray());
  }
  public void Dispose() => client.Dispose();
}
