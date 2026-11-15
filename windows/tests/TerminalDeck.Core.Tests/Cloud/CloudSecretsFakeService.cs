using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// The `/secrets/*` routes and the device list as the service answers them (td-cloud-next cloud/worker/src/secrets.ts:
// initialize, approval request / sign / answer, envelope, possession, recovery challenge, rotate with refusedCopies,
// policy/phones, status with pendingApprovals, rotationDue, phonesPolicy), with the service's own checks: the device's
// keys hash, the request signature, the answer proof, every device envelope signed by its author, possession over the
// canary. In memory; each device calls through its own `Call` (the device id is the transport's verified device).
internal sealed class CloudSecretsFakeService
{
  public const string Subject = CloudFakeService.Subject;
  public sealed class Device
  {
    public required CloudDeviceRegistration Registration;
    public string Status = "active";
    public CloudDeviceKeyEnvelope? Envelope;
    public string? CanaryHash;
    public bool Approved;
    public bool SignedOutBefore;
  }
  public sealed class Approval
  {
    public required CloudApproval Value; public string State = "pending"; public int Epoch; public string? TargetSignature;
  }
  public string State = "unset";
  public int Epoch;
  public ulong Version;
  public CloudRecoveryEnvelope? Recovery;
  public string RecoveryVersion = "0";
  public long Now = 1_763_000_000_000;
  public readonly Dictionary<string, Device> Devices = new(StringComparer.OrdinalIgnoreCase);
  public readonly List<Approval> Approvals = [];
  public CloudSecretsRotationDue? Due;
  public CloudSecretsPhonesPolicy? PhonesPolicy;
  public CloudSecretsAskPolicy? AskPolicy { get; set; }
  /// Rotate: refuse the whole call for any copy (an older service) instead of naming it in refusedCopies.
  public bool AllOrNothingCopies { get; set; }
  /// Rotate: copies the service cannot take, by target id (its code).
  public readonly Dictionary<string, string> RefuseCopyFor = new(StringComparer.OrdinalIgnoreCase);
  public readonly List<string> Calls = [];

  public void Add(CloudDeviceRegistration registration) => Devices[registration.DeviceId] = new Device { Registration = registration };
  private static void Check(bool ok, string code = "invalid_request", int status = 400) { if (!ok) throw new CloudFailure(code, status); }
  private string V => Version.ToString(CultureInfo.InvariantCulture);
  private static bool Computer(Device d) => d.Registration.Platform is "macos" or "windows";
  private static bool Viewer(Device d) => d.Registration.Platform is "ios" or "android" or "web";
  private bool IsApproved(Device d) => d.Approved && d.Envelope?.Epoch == Epoch;
  private Device Active(string id) => Devices.TryGetValue(id, out var d) && d.Status == "active" ? d : throw new CloudFailure("not_found", 404);
  private static bool Verify(CloudPublicJwk key, string signature, byte[] message)
  {
    try { CloudKeyWrap.Verify(signature, message, key); return true; } catch (CloudFailure) { return false; }
  }
  private void Envelope(CloudDeviceKeyEnvelope envelope, Device target, Device author, int epoch)
  {
    Check(envelope.V == 1 && envelope.Epoch == epoch && envelope.TargetDeviceId == target.Registration.DeviceId && envelope.AuthorDeviceId == author.Registration.DeviceId);
    Check(Verify(author.Registration.SignPublicJwk, envelope.Signature, [.. envelope.Aad(), .. CloudBytes.Unbase64(envelope.Ciphertext), .. CloudBytes.Unbase64(envelope.Tag, 16)]),
      "bad_signature", 401);
  }

  /// The control port's transport for one device.
  public Func<string, string, CloudJson?, string?, CancellationToken, Task<CloudJson>> Call(string deviceId) => (method, path, body, id, ct) =>
  {
    Calls.Add(method + " " + path);
    var caller = Active(deviceId);
    var o = body as CloudJson.Object ?? CloudJson.Obj();
    if (method == "POST") Check(o["requestId"]?.AsString == id);
    return Task.FromResult(Handle(caller, method, path, o));
  };
  public Func<CancellationToken, Task<IReadOnlyList<CloudDevice>>> List() => _ => Task.FromResult<IReadOnlyList<CloudDevice>>(Devices.Values.Select(d =>
    new CloudDevice(d.Registration.DeviceId, d.Registration.Label, d.Registration.Platform, d.Registration.AppVersion, d.Status, d.Approved, Now,
      d.Registration.SignPublicJwk, d.Registration.WrapPublicJwk)).ToArray());

  private CloudJson Handle(Device c, string method, string path, CloudJson.Object b)
  {
    var me = c.Registration.DeviceId;
    switch (method + " " + path)
    {
      case "GET /secrets/status":
        var pending = !Viewer(c) && IsApproved(c) ? Approvals.Where(a => a.State == "pending" && a.Epoch == Epoch).Select(a => (CloudJson)CloudJson.Obj(
          ("approvalId", CloudJson.From(a.Value.ApprovalId)), ("targetDeviceId", CloudJson.From(a.Value.TargetDeviceId)), ("targetKeyHash", CloudJson.From(a.Value.TargetKeyHash)),
          ("challenge", CloudJson.From(a.Value.Challenge)), ("expiresAt", CloudJson.From(a.Value.ExpiresAt)),
          ("targetSignature", a.TargetSignature is { } s ? CloudJson.From(s) : null),
          ("signedOutBefore", Devices.TryGetValue(a.Value.TargetDeviceId, out var t) && t.SignedOutBefore ? CloudJson.From(true) : null))).ToArray() : [];
        return CloudJson.Obj(("state", CloudJson.From(State)), ("epoch", CloudJson.From(Epoch)), ("version", CloudJson.From(V)),
          ("recoveryReady", CloudJson.From(Recovery is not null)), ("approvedDeviceCount", CloudJson.From(Devices.Values.Count(d => d.Status == "active" && IsApproved(d)))),
          ("secretsApproved", CloudJson.From(IsApproved(c))), ("pendingApprovals", CloudJson.Arr(pending)),
          ("phonesPolicy", PhonesPolicy is { } p ? CloudJson.Obj(("phonesOff", CloudJson.From(p.PhonesOff)), ("at", CloudJson.From(p.At)), ("by", CloudJson.From(p.By)),
            ("signature", CloudJson.From(p.Signature))) : null),
          ("askPolicy", AskPolicy is { AskOnNewDevice: true } q ? CloudJson.Obj(("askOnNewDevice", CloudJson.From(true)), ("at", CloudJson.From(q.At)), ("by", CloudJson.From(q.By)),
            ("signature", CloudJson.From(q.Signature))) : null),
          ("rotationDue", Due is { } due && !Viewer(c) ? CloudJson.Obj(("since", CloudJson.From(due.Since)), ("removedDeviceId", CloudJson.From(due.RemovedDeviceId)),
            ("removedName", CloudJson.From(due.RemovedName)), ("holders", CloudJson.Arr(Devices.Values.Where(d => d.Status == "active" && IsApproved(d)
              && d.Registration.DeviceId != due.RemovedDeviceId).Select(d => CloudJson.From(d.Registration.DeviceId))))) : null));
      case "GET /secrets/envelope":
        Check(State == "ready", "secrets_locked", 403);
        Check(c.Envelope?.Epoch == Epoch, "secrets_locked", 403);
        return CloudJson.Obj(("epoch", CloudJson.From(Epoch)), ("version", CloudJson.From(V)), ("deviceEnvelope", c.Envelope!.ToJson()));
      case "POST /secrets/initialize":
        Check(b["expectedVersion"]?.AsString == V, "version_changed", 409);
        Check(State == "unset" && Version == 0, "version_changed", 409);
        var recovery = CloudRecoveryEnvelope.FromJson(b["recoveryEnvelope"]!);
        Check(recovery.Epoch == 1 && recovery.Version == "1" && recovery.PublicSigningJwk.Crv == "Ed25519");
        var mine = CloudDeviceKeyEnvelope.FromJson(b["deviceEnvelope"]!);
        Envelope(mine, c, c, 1);
        State = "ready"; Epoch = 1; RecoveryVersion = "1"; Recovery = recovery; Version++;
        c.Envelope = mine; c.CanaryHash = b["canaryHash"]!.AsString; c.Approved = false;
        return CloudJson.Obj(("state", CloudJson.From("ready")), ("epoch", CloudJson.From(1)), ("version", CloudJson.From(V)), ("deviceEnvelope", mine.ToJson()),
          ("secretsApproved", CloudJson.From(false)));
      case "POST /secrets/approval/request":
        Check(b["targetDeviceId"]?.AsString == me, "not_approved", 403);
        Check(Computer(c) || c.Registration.Platform is "ios" or "android", "not_approved", 403);
        Check(!(Viewer(c) && PhonesPolicy?.PhonesOff == true), "phones_off", 409);
        Check(State == "ready", "secrets_locked", 403);
        Check(!IsApproved(c), "version_changed", 409);
        Check(b["targetKeyHash"]?.AsString == CloudKeyWrap.KeyHash(c.Registration), "bad_device_proof", 401);
        var approval = new Approval { Value = new(Guid.NewGuid().ToString("D"), me, b["targetKeyHash"]!.AsString!, CloudBytes.Base64Url(RandomNumberGenerator.GetBytes(32)), Now + 600_000), Epoch = Epoch };
        Approvals.Add(approval);
        return CloudJson.Obj(("approvalId", CloudJson.From(approval.Value.ApprovalId)), ("challenge", CloudJson.From(approval.Value.Challenge)), ("expiresAt", CloudJson.From(approval.Value.ExpiresAt)));
      case "POST /secrets/approval/sign":
        var a = Approvals.FirstOrDefault(x => x.Value.ApprovalId == b["approvalId"]?.AsString) ?? throw new CloudFailure("not_found", 404);
        Check(a.Value.TargetDeviceId == me, "not_approved", 403);
        Check(a.TargetSignature is null, "version_changed", 409);
        var message = CloudCanonical.Encode(CloudJson.Obj(("purpose", CloudJson.From("TD-APPROVAL-REQUEST-1")), ("sub", CloudJson.From(Subject)),
          ("approvalId", CloudJson.From(a.Value.ApprovalId)), ("challenge", CloudJson.From(a.Value.Challenge)), ("targetDeviceId", CloudJson.From(a.Value.TargetDeviceId)),
          ("targetKeyHash", CloudJson.From(a.Value.TargetKeyHash)), ("wrapKeyHash", CloudJson.From(CloudBytes.Sha256Hex(CloudCanonical.Encode(CloudP256.Json(c.Registration.WrapPublicJwk))))),
          ("epoch", CloudJson.From(Epoch)), ("expiresAt", CloudJson.From(a.Value.ExpiresAt))));
        Check(Verify(c.Registration.SignPublicJwk, b["signature"]!.AsString!, message), "bad_device_proof", 401);
        a.TargetSignature = b["signature"]!.AsString;
        return CloudJson.Obj(("approvalId", CloudJson.From(a.Value.ApprovalId)));
      case "POST /secrets/approval/answer":
        var ans = Approvals.FirstOrDefault(x => x.Value.ApprovalId == b["approvalId"]?.AsString) ?? throw new CloudFailure("not_found", 404);
        Check(b["expectedVersion"]?.AsString == V, "version_changed", 409);
        var target = Active(ans.Value.TargetDeviceId);
        Check(IsApproved(c) && target != c, "not_approved", 403);
        Check(!(Viewer(target) && PhonesPolicy?.PhonesOff == true), "phones_off", 409);
        Check(ans.State == "pending" && ans.Epoch == Epoch && ans.Value.ExpiresAt > Now, "approval_expired", 410);
        Check(ans.Value.TargetKeyHash == CloudKeyWrap.KeyHash(target.Registration), "version_changed", 409);
        var allow = b["allow"] is CloudJson.Bool { Value: true };
        CloudDeviceKeyEnvelope? sent = null;
        if (allow) { sent = CloudDeviceKeyEnvelope.FromJson(b["deviceEnvelope"]!); Envelope(sent, target, c, Epoch); }
        var proof = (CloudJson.Object)b["proof"]!;
        Check(proof["signerDeviceId"]?.AsString == me, "bad_device_proof", 401);
        Check(Verify(c.Registration.SignPublicJwk, proof["signature"]!.AsString!, CloudSecretsProof.Approval(ans.Value, allow, V, sent, b["canaryHash"]?.AsString)), "bad_device_proof", 401);
        ans.State = allow ? "approved" : "denied";
        if (sent is not null) { target.Envelope = sent; target.CanaryHash = b["canaryHash"]!.AsString; target.Approved = false; }
        Version++;
        return CloudJson.Obj(("approvalId", CloudJson.From(ans.Value.ApprovalId)), ("state", CloudJson.From(ans.State)));
      case "POST /secrets/possession":
        Check(State == "ready", "secrets_locked", 403);
        Check(b["expectedVersion"]?.AsString == V, "version_changed", 409);
        Check(c.Envelope?.Epoch == Epoch && c.CanaryHash is not null && !IsApproved(c), "secrets_locked", 403);
        Check(CloudBytes.Sha256Hex(CloudBytes.Unbase64(b["canary"]!.AsString!, 32)) == c.CanaryHash, "bad_device_proof", 401);
        Check(Verify(c.Registration.SignPublicJwk, b["signature"]!.AsString!, Encoding.UTF8.GetBytes($"TD-CLOUD-POSSESSION-1\n{Subject}\n{me}\n{V}\n{b["canary"]!.AsString}")),
          "bad_device_proof", 401);
        c.Approved = true; Version++;
        return CloudJson.Obj(("secretsApproved", CloudJson.From(true)), ("epoch", CloudJson.From(Epoch)), ("version", CloudJson.From(V)));
      case "POST /secrets/recovery/challenge":
        Check(State == "ready" && Recovery is not null, "recovery_required", 409);
        Check(b["targetKeyHash"]?.AsString == CloudKeyWrap.KeyHash(c.Registration), "bad_device_proof", 401);
        return CloudJson.Obj(("challengeId", CloudJson.From(Guid.NewGuid().ToString("D"))), ("challenge", CloudJson.From("c")), ("expiresAt", CloudJson.From(Now + 300_000)),
          ("epoch", CloudJson.From(Epoch)), ("version", CloudJson.From(V)), ("recoveryEnvelope", Recovery!.ToJson()));
      case "POST /secrets/policy/phones":
        var pp = (CloudJson.Object)b["phonesPolicy"]!;
        PhonesPolicy = new(pp["phonesOff"] is CloudJson.Bool { Value: true }, pp["at"]!.AsInteger!.Value, pp["by"]!.AsString!, pp["signature"]!.AsString!);
        return CloudJson.Obj(("at", CloudJson.From(PhonesPolicy.At)));
      case "POST /secrets/rotate":
        Check(Computer(c), "not_approved", 403);
        Check(b["expectedVersion"]?.AsString == V, "version_changed", 409);
        Check(IsApproved(c), "not_approved", 403);
        if (Due is not { } rotation) throw new CloudFailure("not_due", 409);
        var newEpoch = Epoch + 1;
        var newRecovery = CloudRecoveryEnvelope.FromJson(b["newRecoveryEnvelope"]!);
        Check(newRecovery.Epoch == newEpoch && newRecovery.Version == (ulong.Parse(RecoveryVersion, CultureInfo.InvariantCulture) + 1).ToString(CultureInfo.InvariantCulture)
          && newRecovery.IsPlaceholder);
        var own = CloudDeviceKeyEnvelope.FromJson(b["newDeviceEnvelope"]!);
        Envelope(own, c, c, newEpoch);
        var copies = new Dictionary<string, (CloudDeviceKeyEnvelope Envelope, string Canary)>(StringComparer.OrdinalIgnoreCase);
        var refused = new List<CloudJson>();
        foreach (var item in ((CloudJson.Array)b["copies"]!).Items.Cast<CloudJson.Object>())
        {
          var tid = item["targetDeviceId"]!.AsString!;
          Check(!string.Equals(tid, me, StringComparison.OrdinalIgnoreCase) && !copies.ContainsKey(tid));
          try
          {
            if (RefuseCopyFor.TryGetValue(tid, out var code)) throw new CloudFailure(code, 403);
            Check(!string.Equals(tid, rotation.RemovedDeviceId, StringComparison.OrdinalIgnoreCase), "not_approved", 403);
            var t = Active(tid);
            Check(IsApproved(t), "not_approved", 403);
            var env = CloudDeviceKeyEnvelope.FromJson(item["envelope"]!);
            Envelope(env, t, c, newEpoch);
            copies[tid] = (env, item["canaryHash"]!.AsString!);
          }
          catch (CloudFailure failure)
          {
            if (AllOrNothingCopies) throw;
            refused.Add(CloudJson.Obj(("targetDeviceId", CloudJson.From(tid)), ("code", CloudJson.From(failure.Code))));
          }
        }
        Epoch = newEpoch; Version++; RecoveryVersion = newRecovery.Version; Recovery = newRecovery; Due = null;
        foreach (var d in Devices.Values) d.Approved = false;
        foreach (var x in Approvals) if (x.State == "pending") x.State = "cleared";
        c.Envelope = own; c.CanaryHash = b["canaryHash"]!.AsString;
        foreach (var (tid, copy) in copies) { Devices[tid].Envelope = copy.Envelope; Devices[tid].CanaryHash = copy.Canary; }
        foreach (var d in Devices.Values.Where(d => d != c && !copies.ContainsKey(d.Registration.DeviceId))) { d.Envelope = null; d.CanaryHash = null; }
        return CloudJson.Obj(("epoch", CloudJson.From(Epoch)), ("version", CloudJson.From(V)), ("state", CloudJson.From("ready")),
          ("preservedArchiveId", CloudJson.From(Guid.NewGuid().ToString("D"))), ("secretsApproved", CloudJson.From(false)),
          ("refusedCopies", refused.Count > 0 ? CloudJson.Arr(refused) : null));
    }
    throw new CloudFailure("not_found", 404);
  }
}

/// One device of the account for saved-passwords tests: its own keys, protected slots in memory, its own trusted list
/// (id -> pinned), its hand-over.
internal sealed class CloudSecretsTestDevice
{
  public sealed class MemorySlots : ICloudSecretsSlots
  {
    public readonly Dictionary<string, byte[]> Items = new(StringComparer.Ordinal);
    public bool FailReads { get; set; }
    public byte[]? Read(string name) => FailReads ? throw new IOException("unreadable") : Items.TryGetValue(name, out var v) ? v.ToArray() : null;
    public void Write(string name, byte[] bytes) => Items[name] = bytes.ToArray();
    public void Remove(string name) => Items.Remove(name);
    public void RemoveAll() => Items.Clear();
  }
  public CloudDeviceKeys Keys { get; } = CloudDeviceKeys.Fresh();
  public CloudDeviceRegistration Registration { get; }
  public MemorySlots Slots { get; } = new();
  public Dictionary<string, CloudSecretsPinned> Pinned { get; } = new(StringComparer.OrdinalIgnoreCase);
  public bool Automatic = true;
  public List<string> Lines { get; } = [];
  public CloudSecretsHandover Handover { get; }
  public CloudSecretsLocalKeys Local { get; }
  public string Id => Registration.DeviceId;

  public CloudSecretsTestDevice(CloudSecretsFakeService service, string label, string platform = "windows")
  {
    Registration = Keys.Registration(label, "0.22.0", platform);
    service.Add(Registration);
    Pinned[Id] = new(label, Registration.SignPublicJwk, platform);
    Local = new(Slots);
    Handover = new(CloudSecretsFakeService.Subject, Registration, Keys.Sign, Keys.SharedSecret, Local, new CloudSecretsControl(service.Call(Id), service.List()),
      new CloudSecretsAutoTrust(() => Automatic, id => Pinned.GetValueOrDefault(id)), () => true, () => service.Now, Lines.Add)
    { RotationJitter = () => 0, Sleep = _ => Task.CompletedTask };
  }
  /// This device's own list takes `other` in, with the kind it was registered as.
  public void Trust(CloudSecretsTestDevice other, string? platform = null) => Pinned[other.Id] = new(other.Registration.Label, other.Registration.SignPublicJwk, platform ?? other.Registration.Platform);
  public byte[] Root => Local.Read()!.Root;
}
