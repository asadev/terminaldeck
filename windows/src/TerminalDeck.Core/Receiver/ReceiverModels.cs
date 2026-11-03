using System.Collections.Immutable;
using System.Text.Json;

namespace TerminalDeck.Core.Receiver;

public enum IntakeKind { Share, Drop, Clipboard, Browser, Phone, Report, Hoot, Webhook }
public enum InboxStatus { Unrouted, Held, Delivered, Failed, Ignored }
public enum RouteKind { Session, Chat, NewTask, Hoot, Agent }
public sealed record ReceiverTarget(RouteKind Kind, string? Id = null, string? ThreadKey = null);
public sealed record ReceiverSource(string Id, string Name, IntakeKind Kind, string ProjectId, bool Enabled = true);
public sealed record ReceiverFile(string Id, string Name, string MediaType, long Bytes, string? Sha256 = null);
public sealed record ReceiverTrail(DateTimeOffset At, string Action);
public sealed record ReceiverItem(string Id, string SourceId, string ProjectId, DateTimeOffset ReceivedAt,
  string Title, string Text, string? Url, ImmutableArray<ReceiverFile> Files, string Fingerprint,
  InboxStatus Status = InboxStatus.Unrouted, ReceiverTarget? Target = null, string? RuleId = null,
  string? DeliveryId = null, string? Outcome = null, ImmutableArray<ReceiverTrail> Trail = default)
{
  public JsonElement? Payload { get; init; }
  public string? ReplayedFrom { get; init; }
}
public sealed record ReceiverRule(string Id, string Name, string? SourceId, string Contains, ReceiverTarget Target,
  bool Enabled = true, int PerHour = 30, int? QuietStartHour = null, int? QuietEndHour = null)
{
  public ImmutableArray<ReceiverCondition> Conditions { get; init; } = [];
}
public sealed record ReceiverDecision(string Reason, ReceiverTarget? Target, string? RuleId);
public sealed record ReceiverDraft(string SourceId, string Title, string Text, string? Url = null,
  ImmutableArray<ReceiverFile> Files = default, string? ExternalId = null)
{
  public JsonElement? Payload { get; init; }
  public string? ReplayedFrom { get; init; }
  public bool Ignore { get; init; }
}
public sealed record ReceiverState(ImmutableArray<ReceiverSource> Sources, ImmutableArray<ReceiverRule> Rules,
  ImmutableArray<ReceiverItem> Items);
public sealed record ReceiverDestination(ReceiverTarget Target, string Name, string ProjectId);
public sealed record DeliveryReceipt(string Reference, string Message);

// Implementations must deduplicate deliveryId. An interrupted send cannot be
// proved absent; Retry keeps the same key until an acknowledgement arrives.
public interface IReceiverDelivery
{
  IReadOnlyList<ReceiverDestination> Destinations();
  ValueTask<DeliveryReceipt> DeliverAsync(ReceiverItem item, ReceiverTarget target, string deliveryId, CancellationToken ct);
}
public interface IReceiver
{
  event Action? Changed;
  IReadOnlyList<ReceiverSource> Sources();
  IReadOnlyList<ReceiverRule> Rules();
  IReadOnlyList<ReceiverItem> Items(string? source = null, InboxStatus? status = null, string query = "", int limit = 200);
  ReceiverItem Item(string id);
  IReadOnlyList<ReceiverDestination> Destinations(string projectId);
  ReceiverItem Receive(ReceiverDraft draft);
  ReceiverDecision Test(ReceiverDraft draft, ReceiverRule? rule = null);
  void SaveSource(ReceiverSource source);
  void RemoveSource(string id);
  void SaveRule(ReceiverRule rule);
  void RemoveRule(string id);
  void MoveRule(string id, int index);
  ValueTask<ReceiverItem> RouteAsync(string id, ReceiverTarget target, CancellationToken ct = default);
  ReceiverItem Replay(string id)
  {
    var item = Item(id);
    return Receive(new(item.SourceId, item.Title, item.Text, item.Url, item.Files, Guid.NewGuid().ToString("N"))
      { Payload = item.Payload, ReplayedFrom = item.Id });
  }
  void Hold(string id, ReceiverTarget target);
  void Dismiss(string id);
}

public static class ReceiverJson
{
  public static JsonSerializerOptions Options { get; } = new()
  {
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = true,
    Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
  };
  public static JsonElement Value<T>(T value) => JsonSerializer.SerializeToElement(value, Options);
  public static T Read<T>(JsonElement value) => value.Deserialize<T>(Options) ?? throw new ArgumentException("Give a complete item.");
}
