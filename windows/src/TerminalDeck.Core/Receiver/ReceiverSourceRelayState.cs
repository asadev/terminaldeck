using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Receiver;

public sealed partial class ReceiverSourceService
{
  private readonly SemaphoreSlim relayKeyGate = new(1, 1);
  public async Task<NoiseIdentity> RelayIdentityAsync(CancellationToken ct = default)
  {
    await CleanupCredentialsAsync(ct);
    await relayKeyGate.WaitAsync(ct);
    try
    {
      string? reference; lock (gate) reference = State().RelayKeyReference;
      if (reference is not null)
      {
        var saved = await secrets.ReadAsync(reference, ct) ?? throw new IOException("The Receiver encryption key is unavailable. Repair this app's protected store before receiving relay events.");
        try { return new(saved); } finally { CryptographicOperations.ZeroMemory(saved); }
      }
      var key = RandomNumberGenerator.GetBytes(32); var next = credentialPrefix + "seal-" + Guid.NewGuid().ToString("N");
      try
      {
        await secrets.WriteAsync(next, key, ct); lock (gate) { var state = State(); store.Save(state with { RelayKeyReference = next }); } return new(key);
      }
      catch { await secrets.DeleteAsync(next, CancellationToken.None); throw; }
      finally { CryptographicOperations.ZeroMemory(key); }
    }
    finally { relayKeyGate.Release(); }
  }
  public async Task<JsonElement> RelayDeclarationsAsync(CancellationToken ct = default)
  {
    var rows = new List<object>();
    foreach (var source in receiver.Sources().Where(s => s.Kind == IntakeKind.Webhook && Regex.IsMatch(s.Id, "^[A-HJ-NP-Z2-9]{26}$")))
    {
      var configuration = Read(source.Id); var proof = configuration.Proof;
      var hash = proof.Scheme is "token" or "basic" ? Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes((proof.Scheme == "basic" ? (proof.BasicUser ?? "") + ":" : "") + (configuration.SecretReference is null ? "" : await SecretAsync(configuration.SecretReference, ct))))) : null;
      rows.Add(new { id = source.Id, auth = proof.Scheme, secretHash = hash, tokenHeader = proof.Scheme == "token" && !proof.Header.Equals("Authorization", StringComparison.OrdinalIgnoreCase) ? proof.Header.ToLowerInvariant() : null, signatureHeader = proof.Scheme == "hmac" ? proof.Header.ToLowerInvariant() : null, ipAllow = proof.IpAllow ?? [], enabled = source.Enabled && (proof.Scheme == "none" || configuration.SecretReference is not null) });
    }
    return JsonSerializer.SerializeToElement(rows);
  }
  public bool RelayDeliverySeen(string id) { lock (gate) return (State().RelayDeliveries ?? []).Contains(id, StringComparer.Ordinal); }
  public void MarkRelayDelivery(string id)
  { lock (gate) { var state = State(); store.Save(state with { RelayDeliveries = (state.RelayDeliveries ?? []).Where(value => value != id).Append(id).TakeLast(10000).ToArray() }); } }
}
