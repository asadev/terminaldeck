using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

public sealed partial class CloudAccountClient
{
  public async Task RenameDeviceAsync(string deviceId, string name, CancellationToken ct = default)
  {
    var clean = name.Trim();
    if (clean.Length is < 1 or > 128) throw new CloudProfileRefusal("Use a name between 1 and 128 characters.");
    await work.WaitAsync(ct);
    try
    {
      // A free account keeps its Devices page (19 Nov free plan); signing a device out stays paid (it reads the Cloud's
      // saved-password vault first).
      if (!Snapshot.Subscription.Offers(CloudPaidPlace.Devices)) throw new CloudProfileRefusal(CloudSubscriptionPageText.Subscribe);
      if (!Load() || saved is not { } record || !Snapshot.DeviceRows.Any(d => d.DeviceId == deviceId)) throw new CloudProfileRefusal("This device is no longer in your account.");
      record = await RefreshTokenAsync(record, ct);
      var answer = await SignedAsync(record, HttpMethod.Post, "/devices/rename", CloudWire.Canonical(new { device_id = deviceId, name = clean }), ct);
      using var doc = JsonDocument.Parse(answer);
      if (!doc.RootElement.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True) throw new CloudFailure("invalid_response");
      if (deviceId == record.DeviceId && Machine is { } machine)
      {
        try { machine.Rename(clean); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Log("cloud device: renamed in account; local name could not be remembered"); }
      }
      Publish(Snapshot with { Devices = Snapshot.DeviceRows.Select(d => d.DeviceId == deviceId ? d with { Name = clean } : d).ToArray(), ThisDeviceName = deviceId == Snapshot.ThisDeviceId ? clean : Snapshot.ThisDeviceName });
    }
    finally { work.Release(); }
  }

  // A fresh vault version protects the saved-password key. A rotation refusal is never treated as a sign-out.
  public async Task SignOutDeviceAsync(string deviceId, CancellationToken ct = default)
  {
    await work.WaitAsync(ct);
    try
    {
      if (!Snapshot.Subscription.AllowsCloudServices) throw new CloudProfileRefusal(CloudSubscriptionPageText.Subscribe);
      if (!Load() || saved is not { } record) throw new CloudProfileRefusal("Sign in to manage your devices.");
      if (deviceId == record.DeviceId) throw new CloudProfileRefusal("Use Sign out to sign out of this PC.");
      if (!Snapshot.DeviceRows.Any(d => d.DeviceId == deviceId)) throw new CloudProfileRefusal("This device is no longer in your account.");
      record = await RefreshTokenAsync(record, ct);
      for (var attempt = 0; attempt < 2; attempt++)
      {
        using var state = JsonDocument.Parse(await SignedAsync(record, HttpMethod.Get, "/state", [], ct));
        var version = state.RootElement.GetProperty("vaultVersion").GetString() ?? throw new CloudFailure("invalid_response");
        try
        {
          var answer = await SignedAsync(record, HttpMethod.Post, "/devices/remove", CloudWire.Canonical(new { deviceId, expectedVaultVersion = version }), ct);
          using var doc = JsonDocument.Parse(answer);
          if (doc.RootElement.GetProperty("deviceId").GetString() != deviceId || doc.RootElement.GetProperty("status").GetString() != "revoked") throw new CloudFailure("invalid_response");
          Publish(Snapshot with { Devices = Snapshot.DeviceRows.Where(d => d.DeviceId != deviceId).ToArray() });
          return;
        }
        catch (CloudFailure error) when (error.Code == "version_changed" && attempt == 0) { }
        catch (CloudFailure error) when (error.Code == "rotation_required") { throw new CloudProfileRefusal("This device holds a saved-passwords key. Move its key before signing it out."); }
      }
    }
    finally { work.Release(); }
  }
}
