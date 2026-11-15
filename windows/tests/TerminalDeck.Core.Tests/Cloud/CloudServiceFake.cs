using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Core.Tests.Cloud;

/// The Cloud service and the identity service as the account client sees them, in memory. No network.
internal sealed class CloudServiceFake : ICloudHttp
{
  public const string UserId = "2f1c7e0a-9b7d-4c1e-8a55-0d4f3b2a1c11";
  public readonly List<CloudHttpRequest> Requests = [];
  public bool Entitled = true;
  public string? RefuseDevicesWith;
  public CloudDeviceRegistration? Registered;
  public string? Verifier;
  public string? ExchangeCallback;
  public string VaultVersion = "3";
  public int RemoveConflicts;
  public bool RemoveFails { get; set; }
  public readonly List<string> Removed = [];
  /// The account's other devices: their registration and status ("active" or "revoked").
  public readonly List<(CloudDeviceRegistration Device, string Status, long RegisteredAt)> Others = [(CloudDeviceKeys.Fresh().Registration("Asad's Mac\nmini", "0.22.0", "macos"), "active", 1_761_000_000_000L)];

  public Task<CloudHttpResponse> SendAsync(CloudHttpRequest request, CancellationToken ct)
  {
    Requests.Add(request);
    var path = request.Url.AbsolutePath;
    CloudHttpResponse Ok(object body) => new(200, JsonSerializer.SerializeToUtf8Bytes(body));
    if (path.EndsWith("/exchange", StringComparison.Ordinal))
    {
      using var doc = JsonDocument.Parse(request.Body);
      Verifier = doc.RootElement.GetProperty("verifier").GetString();
      ExchangeCallback = doc.RootElement.GetProperty("callback").GetRawText();
      var expires = DateTimeOffset.UtcNow.AddMinutes(60).ToUnixTimeMilliseconds();
      return Task.FromResult(Ok(new { accessToken = Jwt(), refreshToken = "refresh-secret-value", expiresAt = expires,
        user = new { id = UserId, displayName = "Someone", email = "someone@example.com", provider = "google" }, capabilities = new { features = new[] { "cloud" }, storageEntitled = Entitled } }));
    }
    if (path == "/v1/capabilities")
      return Task.FromResult(Entitled ? Ok(new { features = new[] { "cloud" }, storageEntitled = true, session = "valid" }) : Ok(new { features = Array.Empty<string>(), session = "valid" }));
    if (RefuseDevicesWith is not null && path == "/v1/devices")
      return Task.FromResult(new CloudHttpResponse(403, JsonSerializer.SerializeToUtf8Bytes(new { error = new { code = RefuseDevicesWith, message = "x", retryable = false, requestId = "" } })));
    if (path == "/v1/devices" && request.Method == HttpMethod.Post)
    {
      Registered = JsonSerializer.Deserialize<CloudDeviceRegistration>(request.Body, CloudWire.Json);
      Assert.True(Verify(request, Registered!.SignPublicJwk));
      return Task.FromResult(new CloudHttpResponse(201, JsonSerializer.SerializeToUtf8Bytes(new { deviceId = Registered.DeviceId, status = "active", secretsApproved = false, headSeq = "0", vaultState = "unset" })));
    }
    if (path == "/v1/devices")
    {
      Assert.True(Verify(request, Registered!.SignPublicJwk));
      var mine = Registered;
      var all = new List<object> { new { mine.DeviceId, mine.Label, mine.Platform, mine.AppVersion, status = Removed.Contains(mine.DeviceId) ? "revoked" : "active", secretsApproved = false, lastSeenAt = 1_763_000_000_000L, registeredAt = 1_763_000_000_000L, mine.SignPublicJwk, mine.WrapPublicJwk } };
      foreach (var (other, status, added) in Others)
        all.Add(new { other.DeviceId, other.Label, other.Platform, other.AppVersion, status, secretsApproved = false, lastSeenAt = 1_762_000_000_000L, registeredAt = added, other.SignPublicJwk, other.WrapPublicJwk });
      return Task.FromResult(Ok(new { devices = all }));
    }
    if (path == "/v1/state" && request.Method == HttpMethod.Get)
    {
      Assert.True(Verify(request, Registered!.SignPublicJwk));
      return Task.FromResult(Ok(new { headSeq = "0", devicesVersion = "1", vaultState = "unset", vaultEpoch = "0", vaultVersion = VaultVersion }));
    }
    if (path == "/v1/devices/remove" && request.Method == HttpMethod.Post)
    {
      Assert.True(Verify(request, Registered!.SignPublicJwk));
      if (RemoveFails) return Task.FromResult(new CloudHttpResponse(503, JsonSerializer.SerializeToUtf8Bytes(new { error = new { code = "unavailable", message = "x", retryable = true, requestId = "" } })));
      using var doc = JsonDocument.Parse(request.Body);
      Assert.Equal(["deviceId", "expectedVaultVersion"], doc.RootElement.EnumerateObject().Select(p => p.Name).ToArray());
      if (RemoveConflicts-- > 0 || doc.RootElement.GetProperty("expectedVaultVersion").GetString() != VaultVersion)
        return Task.FromResult(new CloudHttpResponse(409, JsonSerializer.SerializeToUtf8Bytes(new { error = new { code = "version_changed", message = "x", retryable = false, requestId = "" } })));
      Removed.Add(doc.RootElement.GetProperty("deviceId").GetString()!);
      return Task.FromResult(Ok(new { deviceId = Removed[^1], status = "revoked", vaultState = "unset", vaultVersion = VaultVersion, rotationRequired = false }));
    }
    if (path.EndsWith("/logout", StringComparison.Ordinal)) return Task.FromResult(new CloudHttpResponse(204, []));
    return Task.FromResult(new CloudHttpResponse(404, []));
  }

  private static bool Verify(CloudHttpRequest request, CloudPublicJwk key)
  {
    var h = request.Headers;
    var message = $"TD-CLOUD-1\n{request.Method.Method}\n{request.Url.PathAndQuery}\n{h["X-TD-Time"]}\n{h["X-TD-Request"]}\n{CloudWire.Sha256Hex(request.Body)}";
    using var ec = ECDsa.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, Q = new() { X = CloudWire.FromBase64Url(key.X), Y = CloudWire.FromBase64Url(key.Y) } });
    return h["X-TD-Signature"].Length == 86 && ec.VerifyData(Encoding.UTF8.GetBytes(message), CloudWire.FromBase64Url(h["X-TD-Signature"])!, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
  }
  private static string Jwt()
  {
    var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
    var claims = JsonSerializer.SerializeToUtf8Bytes(new { iss = CloudWire.Issuer, sub = UserId, role = "authenticated", aud = "authenticated", exp = now + 3600, iat = now, session_id = Guid.NewGuid().ToString() });
    return CloudWire.Base64Url("{\"alg\":\"ES256\"}"u8) + "." + CloudWire.Base64Url(claims) + ".c2lnbmF0dXJl";
  }
}

internal sealed class XorProtector : IDataProtector
{
  public byte[] Protect(ReadOnlySpan<byte> plaintext) => plaintext.ToArray().Select(b => (byte)(b ^ 0x5A)).Prepend((byte)1).ToArray();
  public byte[] Unprotect(ReadOnlySpan<byte> ciphertext) => ciphertext[1..].ToArray().Select(b => (byte)(b ^ 0x5A)).ToArray();
}
internal sealed class CountingRandom : ICloudRandom
{
  public int Calls;
  public void Fill(Span<byte> buffer) { Calls++; RandomNumberGenerator.Fill(buffer); }
}
internal sealed class FakeBrowser : ICloudBrowser
{
  public readonly List<Uri> Opened = [];
  public Task OpenAsync(Uri url, CancellationToken ct) { Opened.Add(url); return Task.CompletedTask; }
}
