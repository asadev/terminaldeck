using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// Sign-out (owner, 13 Nov): one confirmation on the page ("Sign out of Cloud on this PC?"), then this PC is removed
// from the account at the service and its key is dropped here.
public sealed partial class CloudAccountClient
{
  /// The person's Sign out press, after the page's one confirmation. Asks the service to remove this PC from the account
  /// (`POST /v1/devices/remove`, signed by this PC, with the vault version read just before), then drops the protected
  /// record (sign-in and this PC's private keys) and ends the session. Signing out never waits on the network for long:
  /// when the service cannot be reached the local sign-out still happens and one plain line says so in the log.
  /// Nothing but Cloud's own record is removed here; the trusted-device list is kept.
  public async Task SignOutAsync(CancellationToken ct = default)
  {
    await work.WaitAsync(ct);
    try
    {
      Interlocked.Increment(ref generation);
      bool signedIn;
      try { signedIn = Load(); } catch (Exception) { signedIn = false; }
      if (signedIn) await RemoveThisPcAsync(saved!, ct);
      await ClearSignInAsync();
    }
    finally { work.Release(); }
  }

  private async Task RemoveThisPcAsync(Saved record, CancellationToken ct)
  {
    if (!record.Registered || keys is null) return;
    using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
    limit.CancelAfter(TimeSpan.FromSeconds(15));
    try
    {
      if (record.Session.ExpiresAt <= Now + 60_000) record = await RefreshTokenAsync(record, limit.Token);
      for (var attempt = 0; ; attempt++)
      {
        string vaultVersion;
        using (var state = JsonDocument.Parse(await SignedAsync(record, HttpMethod.Get, "/state", [], limit.Token)))
          vaultVersion = state.RootElement.TryGetProperty("vaultVersion", out var v) && v.ValueKind == JsonValueKind.String ? v.GetString()! : throw new CloudFailure("invalid_response");
        var body = CloudWire.Canonical(new Dictionary<string, string> { ["deviceId"] = record.DeviceId, ["expectedVaultVersion"] = vaultVersion });
        try
        {
          await SignedAsync(record, HttpMethod.Post, "/devices/remove", body, limit.Token);
          Log("cloud sign-out: remove this PC ok");
          return;
        }
        // The vault moved between the two requests: read it once more.
        catch (CloudFailure failure) when (failure.Code == "version_changed" && attempt == 0) { }
      }
    }
    catch (Exception error) when (error is not OutOfMemoryException) { Log("cloud sign-out: remove this PC failed: " + Kind(error)); }
  }
}
