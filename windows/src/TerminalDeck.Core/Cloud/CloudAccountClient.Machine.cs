using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Cloud;

// One row per machine (the Mac's BackendCloudAccount register / describeSelfOnce): this PC tells the service its machine
// id and friendly name at registration, and once per run through the self-rename call when the service does not hold
// the pair it accepted last. A service that refuses the fields gets the plain registration; nothing else changes.
public sealed partial class CloudAccountClient
{
  /// What this PC tells the service about itself (machine id + friendly name); null = nothing is sent.
  public CloudMachineFacts? Machine { get; set; }
  private bool describedThisRun;

  /// An answer that refuses the request's SHAPE (an older service that rejects unknown fields): the registration is then
  /// sent again without them. Never a sign-in or proof refusal.
  public static bool FieldsRefused(Exception error) => error is CloudFailure f && f.Code is "invalid_request" or "bad_request" or "unknown_field" or "validation_failed";

  private static byte[] WithMachine(CloudDeviceRegistration registration, CloudMachineFacts.Pair pair)
  {
    var node = JsonSerializer.SerializeToNode(registration, CloudWire.Json)!.AsObject();
    node["machineId"] = pair.MachineId; node["displayName"] = pair.DisplayName;
    if (pair.HostName is not null) node["hostName"] = pair.HostName;
    return CloudWire.Canonical(node);
  }
  private static string? Field(byte[] body, string name)
  {
    try { using var doc = JsonDocument.Parse(body); return doc.RootElement.ValueKind == JsonValueKind.Object ? CloudChatsReadable.Str(doc.RootElement, name) : null; }
    catch (JsonException) { return null; }
  }

  /// Registers this PC, with its machine id and friendly name when known: first with the host name, then without it,
  /// then plain. A service that echoes the name has the pair remembered so launch does not send it again.
  private async Task<CloudDeviceRegistrationReceipt> RegisterAsync(Saved record, CloudDeviceRegistration registration, CancellationToken ct)
  {
    describedThisRun = true;
    if (Machine is { } machine && machine.PairFor(record.Session.User.Id, configuration.DeviceLabel) is { } full)
    {
      foreach (var pair in new[] { full, full with { HostName = null } })
      {
        byte[] answer;
        try { answer = await SignedAsync(record, HttpMethod.Post, "/devices", WithMachine(registration, pair), ct); }
        catch (Exception error) when (FieldsRefused(error)) { Log("cloud device: machine fields not taken at registration (" + Kind(error) + ")"); continue; }
        var receipt = CloudWire.Decode<CloudDeviceRegistrationReceipt>(answer);
        if (receipt.DeviceId == registration.DeviceId && Field(answer, "displayName") == pair.DisplayName) machine.Remember(CloudMachineFacts.Mark(registration.DeviceId, pair));
        return receipt;
      }
      Log("cloud device: registered plain; machine name tried again at next launch");
    }
    return CloudWire.Decode<CloudDeviceRegistrationReceipt>(await SignedAsync(record, HttpMethod.Post, "/devices", CloudWire.Canonical(registration), ct));
  }

  /// Once per run, for a PC that is already registered: send the pair through the self-rename call when it differs from
  /// the one the service accepted last, or when the service's list no longer shows this PC's name. Any failure costs
  /// nothing; the next launch tries again.
  private async Task DescribeSelfOnceAsync(Saved record, byte[] listed, CancellationToken ct)
  {
    if (describedThisRun || Machine is not { } machine) return;
    describedThisRun = true;
    var label = configuration.DeviceLabel;
    if (machine.PairFor(record.Session.User.Id, label) is not { } pair) return;
    var mark = CloudMachineFacts.Mark(record.DeviceId, pair);
    string? shown = null;
    try
    {
      if (JsonNode.Parse(listed, new JsonNodeOptions { PropertyNameCaseInsensitive = true })?["devices"] is JsonArray devices)
        shown = devices.OfType<JsonObject>().FirstOrDefault(d => d["deviceId"]?.GetValue<string>() == record.DeviceId)?["displayName"]?.GetValue<string>();
    }
    catch (Exception ex) when (ex is JsonException or InvalidOperationException) { }
    if (machine.Accepted() == mark && shown == pair.DisplayName) return;
    try
    {
      string? echoed;
      try { echoed = await DescribeAsync(record, label, pair, ct); }
      catch (Exception error) when (FieldsRefused(error) && pair.HostName is not null)
      {
        // A service that does not know the host name yet: the id and the name still go; the full set (with the host
        // name) is tried again at the next launch, since only it is remembered.
        await DescribeAsync(record, label, pair with { HostName = null }, ct);
        Log("cloud device: machine name sent without the host name; tried again at next launch");
        return;
      }
      if (echoed == pair.DisplayName) { machine.Remember(mark); Log("cloud device: machine name sent"); }
      else Log("cloud device: machine name not taken by this service; tried again at next launch");
    }
    catch (Exception error) when (error is not OutOfMemoryException) { Log("cloud device: machine name not sent (" + Kind(error) + "); tried again at next launch"); }
  }
  private async Task<string?> DescribeAsync(Saved record, string label, CloudMachineFacts.Pair pair, CancellationToken ct)
  {
    var body = new JsonObject { ["deviceId"] = record.DeviceId, ["label"] = label, ["machineId"] = pair.MachineId, ["displayName"] = pair.DisplayName };
    if (pair.HostName is not null) body["hostName"] = pair.HostName;
    var answer = await SignedAsync(record, HttpMethod.Post, "/devices/rename", CloudWire.Canonical(body), ct);
    if (Field(answer, "deviceId") != record.DeviceId) throw new CloudFailure("invalid_request");
    return Field(answer, "displayName") ?? (Field(answer, "machineId") == pair.MachineId ? pair.DisplayName : null);
  }
}
