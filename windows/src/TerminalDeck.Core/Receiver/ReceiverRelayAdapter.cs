using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Org.BouncyCastle.Math.EC.Rfc7748;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Receiver;

public sealed class ReceiverRelayAdapter : IRelayReceiverApplication, IDisposable
{
  private readonly ReceiverSourceService sources;
  private Func<RelayPacket, CancellationToken, ValueTask>? send;
  private readonly SemaphoreSlim gate = new(1, 1);
  private readonly CancellationTokenSource stop = new();
  public bool Connected { get; private set; }
  public string[] Active { get; private set; } = [];
  public Dictionary<string, string> Refused { get; private set; } = [];
  public string? Problem { get; private set; }
  public event Action? Changed;
  public ReceiverRelayAdapter(ReceiverSourceService sources) { this.sources = sources; sources.Changed += SourcesChanged; }
  private void SourcesChanged() => _ = ResyncSafelyAsync();
  private async Task ResyncSafelyAsync() { try { await SyncAsync(stop.Token); } catch (Exception error) when (error is IOException or OperationCanceledException or UnauthorizedAccessException or ObjectDisposedException) { } }
  public async ValueTask ConnectedAsync(Func<RelayPacket, CancellationToken, ValueTask> sender, CancellationToken ct) { send = sender; Connected = true; await SyncAsync(ct); Changed?.Invoke(); }
  public ValueTask DisconnectedAsync() { send = null; Connected = false; Active = []; Changed?.Invoke(); return ValueTask.CompletedTask; }
  public async Task SyncAsync(CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try
    {
      if (send is not { } writer) return;
      using var identity = await sources.RelayIdentityAsync(ct); var declarations = await sources.RelayDeclarationsAsync(ct);
      var payload = JsonSerializer.SerializeToUtf8Bytes(new { v = 1, sealKey = Base64(identity.PublicKey), sources = declarations });
      await writer(new(RelayKind.ReceiverSync, new byte[16], payload), ct);
    }
    finally { gate.Release(); }
  }
  public async ValueTask FrameAsync(RelayPacket packet, CancellationToken ct)
  {
    if (packet.Kind == RelayKind.ReceiverSynced)
    {
      try
      {
        if (packet.Payload.Length > 16384) throw new ArgumentException("Receiver status is too large.");
        using var document = JsonDocument.Parse(packet.Payload); var root = document.RootElement;
        if (root.GetProperty("v").GetInt32() != 1 || root.GetProperty("accepted").GetArrayLength() > 64 || root.GetProperty("refused").GetArrayLength() > 64) throw new ArgumentException("Receiver status is invalid.");
        var accepted = root.GetProperty("accepted").EnumerateArray().Select(v => v.GetString()!).ToArray();
        if (accepted.Any(id => !System.Text.RegularExpressions.Regex.IsMatch(id, "^[A-HJ-NP-Z2-9]{26}$"))) throw new ArgumentException("Receiver status contains an invalid source id.");
        var refused = root.GetProperty("refused").EnumerateArray().ToDictionary(v => v.GetProperty("id").GetString()!, v => v.GetProperty("reason").GetString()!);
        Active = accepted; Refused = refused; Problem = null;
      }
      catch (Exception error) when (error is JsonException or ArgumentException or InvalidOperationException or KeyNotFoundException)
      { Problem = "The Receiver relay status could not be read. Existing phone connections were kept."; }
      Changed?.Invoke(); return;
    }
    if (packet.Kind != RelayKind.ReceiverDelivery) return;
    byte ack = 2;
    try
    {
      if (packet.Channel.Length != 16) throw new ArgumentException("The Receiver delivery id is malformed."); var delivery = Convert.ToHexStringLower(packet.Channel);
      if (sources.RelayDeliverySeen(delivery)) ack = 1;
      else
      {
        var (header, sealedBody) = Head(packet.Payload); using (header)
        {
          if (header.RootElement.GetProperty("v").GetInt32() != 1) throw new ArgumentException("The Receiver delivery format is unsupported.");
          var source = header.RootElement.GetProperty("sourceId").GetString()!; var received = header.RootElement.GetProperty("receivedAt").GetInt64();
          if (!System.Text.RegularExpressions.Regex.IsMatch(source, "^[A-HJ-NP-Z2-9]{26}$")) throw new ArgumentException("The Receiver source id is malformed.");
          using var identity = await sources.RelayIdentityAsync(ct); var aad = Encoding.UTF8.GetBytes(source + "." + delivery + "." + received); var plain = Open(sealedBody, identity.PrivateKey, identity.PublicKey, aad);
          try
          {
            var (opened, body) = Head(plain); using (opened)
            {
              var raw = opened.RootElement; if (raw.GetProperty("v").GetInt32() != 1 || raw.GetProperty("method").GetString() != "POST") throw new ArgumentException("The Receiver envelope is unsupported.");
              var headers = raw.GetProperty("headers").EnumerateObject().ToDictionary(p => p.Name.ToLowerInvariant(), p => p.Value.GetString()!);
              await sources.AcceptAsync(new(source, headers, body, raw.TryGetProperty("clientIp", out var ip) ? ip.GetString() : null, raw.TryGetProperty("pathToken", out var token) ? token.GetString() : null, delivery), ct);
              sources.MarkRelayDelivery(delivery); ack = 1;
            }
          }
          finally { CryptographicOperations.ZeroMemory(plain); }
        }
      }
    }
    catch (IOException) { return; }
    catch (Exception error) when (error is CryptographicException or JsonException or ArgumentException or UnauthorizedAccessException or InvalidOperationException or KeyNotFoundException) { ack = 2; }
    if (send is { } writer) await writer(new(RelayKind.ReceiverAck, packet.Channel, [ack]), ct);
  }
  private static (JsonDocument Header, byte[] Body) Head(byte[] bytes)
  {
    if (bytes.Length < 2) throw new ArgumentException("The Receiver frame has no header."); var size = BinaryPrimitives.ReadUInt16BigEndian(bytes);
    if (size > bytes.Length - 2) throw new ArgumentException("The Receiver frame is incomplete."); return (JsonDocument.Parse(bytes.AsMemory(2, size)), bytes[(2 + size)..]);
  }
  private static byte[] Open(byte[] sealedBody, byte[] secret, byte[] recipient, byte[] aad)
  {
    if (sealedBody.Length < 60) throw new ArgumentException("The sealed Receiver delivery is incomplete.");
    var ephemeral = sealedBody[..32]; var shared = new byte[32];
    if (!X25519.CalculateAgreement(secret, 0, ephemeral, 0, shared, 0)) throw new CryptographicException("The Receiver peer key is invalid.");
    var key = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, ephemeral.Concat(recipient).ToArray(), "td-receiver-seal-v1"u8.ToArray());
    try { var plaintext = new byte[sealedBody.Length - 60]; using var aes = new AesGcm(key, 16); aes.Decrypt(sealedBody.AsSpan(32, 12), sealedBody.AsSpan(44, plaintext.Length), sealedBody.AsSpan(sealedBody.Length - 16, 16), plaintext, aad); return plaintext; }
    finally { CryptographicOperations.ZeroMemory(shared); CryptographicOperations.ZeroMemory(key); }
  }
  private static string Base64(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
  public void Dispose() { sources.Changed -= SourcesChanged; send = null; stop.Cancel(); stop.Dispose(); }
}
