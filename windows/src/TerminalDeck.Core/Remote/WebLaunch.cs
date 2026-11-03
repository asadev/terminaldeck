using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Integration;

namespace TerminalDeck.Core.Remote;

// A desktop click opens enrollment for one Noise-authenticated browser, for one minute.
// The token is independent of the phone's six-digit pairing window.
public sealed class WebLaunch(TimeProvider? clock = null)
{
  private readonly TimeProvider time = clock ?? TimeProvider.System;
  private readonly object gate = new();
  private byte[]? digest;
  private DateTimeOffset until;
  public bool IsOpen { get { lock (gate) return digest is not null && time.GetUtcNow() < until; } }
  public string Issue()
  {
    lock (gate)
    {
      var token = "web_" + Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
      digest = SHA256.HashData(Encoding.UTF8.GetBytes(token)); until = time.GetUtcNow().AddMinutes(1);
      return token;
    }
  }
  public void Cancel() { lock (gate) { digest = null; } }
  public bool Consume(string token)
  {
    lock (gate)
    {
      if (!IsOpen || token.Length != 68 || !CryptographicOperations.FixedTimeEquals(digest!, SHA256.HashData(Encoding.UTF8.GetBytes(token)))) return false;
      digest = null; return true;
    }
  }
}

public sealed class WebLaunchApplication(IRelayPhoneApplication next, DeviceTrust trust, WebLaunch launch, Action<string>? enrolled = null) : IRelayPhoneApplication, IW9PhonePushApplication, IDisposable
{
  public IReadOnlyCollection<byte[]> KnownPeers => next.KnownPeers;
  public bool PairingOpen => next.PairingOpen || launch.IsOpen;
  public void SetPublisher(Func<string, byte[], CancellationToken, ValueTask>? publish) { if (next is IW9PhonePushApplication push) push.SetPublisher(publish); }
  public ValueTask<PhoneApplicationReply> OpenedAsync(string channel, ReadOnlyMemory<byte> key, CancellationToken ct) => next.OpenedAsync(channel, key, ct);
  public async ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> key, ReadOnlyMemory<byte> plaintext, CancellationToken ct)
  {
    JsonObject message;
    string? token;
    try
    {
      if (plaintext.Length > PhoneWire.MaximumMessageBytes) throw new ProtocolException("This message is too large.");
      message = JsonNode.Parse(plaintext.Span, documentOptions: new System.Text.Json.JsonDocumentOptions { MaxDepth = 32 }) as JsonObject ?? throw new ProtocolException("This message is unusable.");
      if (message["t"] is not JsonValue tag || !tag.TryGetValue<string>(out var type)) throw new ProtocolException("This message has no type.");
      if (type != "hello") return await next.ReceiveAsync(channel, key, plaintext, ct);
      if (message["token"] is not JsonValue value || !value.TryGetValue<string>(out token)) throw new ProtocolException("This hello has no credential.");
    }
    catch (Exception ex) when (ex is System.Text.Json.JsonException or InvalidOperationException or FormatException or ArgumentException)
    { throw new ProtocolException("This message is unusable."); }
    if (message?["t"]?.GetValue<string>() != "hello" || token?.StartsWith("web_", StringComparison.Ordinal) != true)
      return await next.ReceiveAsync(channel, key, plaintext, ct);
    ct.ThrowIfCancellationRequested();
    if (message["protocol"] is not JsonValue protocol || !protocol.TryGetValue<int>(out var version) || version != 1 || key.Length != 32 ||
      message["device"] is not JsonObject descriptor || descriptor["name"] is not JsonValue named || !named.TryGetValue<string>(out var name) ||
      name is null || name.Length is 0 or > 256 || name.Any(char.IsControl) || descriptor["platform"] is not JsonValue platform || !platform.TryGetValue<string>(out var claimedPlatform) || claimedPlatform is null || claimedPlatform.Length > 128)
      throw new ProtocolException("This browser hello is unusable.");
    if (!launch.Consume(token!)) throw new ProtocolException("This browser link was used or expired. Open a new one on this computer.");
    descriptor["platform"] = "web";
    var enrollment = trust.EnrollApprovedWeb(name, key.Span);
    var receipt = enrollment.Receipt;
    if (enrollment.IsNew)
    {
      try { enrolled?.Invoke(receipt.DeviceId); }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or ProtocolException)
      {
        // Partial workspace grants cannot make a failed enrollment usable.
        trust.Revoke(receipt.DeviceId);
        throw new ProtocolException("The browser workspace could not be granted safely. Open a new link on the PC.");
      }
    }
    message["token"] = receipt.Credential;
    var reply = await next.ReceiveAsync(channel, key, System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(message), ct);
    var messages = reply.Messages.Select(bytes =>
    {
      var row = JsonNode.Parse(bytes);
      if (row?["t"]?.GetValue<string>() != "welcome") return bytes;
      row["token"] = receipt.Credential;
      return System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(row);
    }).ToArray();
    return new(messages, reply.Close);
  }
  public ValueTask DisconnectedAsync(string channel) => next.DisconnectedAsync(channel);
  public void Dispose() { launch.Cancel(); (next as IDisposable)?.Dispose(); }
}
