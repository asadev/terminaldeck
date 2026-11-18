using System.Globalization;
using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Cloud;

public sealed record CloudSubscription(string Paywall, string State, string? Plan = null, long? PaidUntil = null,
  string? Source = null, int IncludedGb = 100, int ExtraGb = 0, bool Offer = false, long? DataKeptUntil = null)
{
  public bool Entitled => State is "paid" or "gift";
  public static CloudSubscription Read(byte[] body)
  {
    var answer = JsonSerializer.Deserialize<CloudSubscription>(body, CloudWire.Json) ?? throw new JsonException();
    if (answer.Paywall is not ("off" or "on") || answer.State is not ("paid" or "gift" or "none" or "lapsed")
      || answer.Plan is not (null or "monthly" or "yearly") || answer.Source is not (null or "apple" or "google" or "gift")
      || answer.IncludedGb < 0 || answer.ExtraGb < 0 || answer.PaidUntil is < 0 or > 253402300799999 || answer.DataKeptUntil is < 0 or > 253402300799999) throw new JsonException("Invalid subscription answer.");
    return answer;
  }
}

// Missing/old/unavailable service disables enforcement, as on Mac. The last good facts survive an outage in memory.
// The service's state alone decides entitlement; a local clock never invents an expiry.
public sealed record CloudSubscriptionSnapshot(CloudSubscription? LastAnswer = null, bool Available = false)
{
  public static CloudSubscriptionSnapshot Unknown { get; } = new();
  public bool AllowsCloudServices => !Available || LastAnswer is not { Paywall: "on" } answer || answer.Entitled;
  // Desktop's strict off rule overrides preview offers: off adds no row, page or tool.
  public bool ShowsSubscription => Available && LastAnswer?.Paywall == "on";
  public CloudSubscriptionSnapshot Received(CloudSubscription? answer) => new(answer ?? LastAnswer, answer is not null);
  public bool Offers(CloudPaidPlace place, bool existing = true) => existing && AllowsCloudServices;
}

public enum CloudPaidPlace
{
  SidebarCloud, SettingsCloud, Devices, PhoneAndWebReach, Pairing, OtherComputerSessions, SessionMove,
  RemoteMachineChoices, FileManager, SyncSwitches, SavedPasswords, PhonesCopy, AiAppsInternet, CloudTools,
  ProjectCloudActions, ArtifactCloudActions
}

public static class CloudPaidInventory
{
  public static bool PaidTool(string id) => id != "cloud.profile" && (id.StartsWith("cloud.", StringComparison.Ordinal)
    || id.StartsWith("remote.", StringComparison.Ordinal) || id.StartsWith("computers.", StringComparison.Ordinal)
    || id.StartsWith("phone.", StringComparison.Ordinal) || id is "devices.page" or "devices.remove" or "devices.rename" or "ai_apps.internet" or "mcp.remote");
  public static bool ShowsTool(CloudSubscriptionSnapshot state, string id) => id == CloudSubscriptionTools.Id ? state.ShowsSubscription : !PaidTool(id) || state.AllowsCloudServices;
  public static bool PaidCommand(string id) => id is "join-remote" or "devices" or "cloud" or "cloud-page" or "settings:cloud" or "settings:devices"
    || id.StartsWith("cloud-session:", StringComparison.Ordinal) || id.StartsWith("cloud-earlier:", StringComparison.Ordinal);
  public static bool ShowsCommand(CloudSubscriptionSnapshot state, string id) => !PaidCommand(id) || state.AllowsCloudServices;
}

public static class CloudSubscriptionPageText
{
  public const string Id = "terminal-deck-cloud";
  public static string Title => Brand.Name + " Cloud";
  public const string Benefit = "Sync and storage, phone and web apps, and access to your computers from another device.";
  public const string Price = "$8.00 a month or $67.00 a year. 100 GB included.";
  public static string Subscribe => "Subscribe in the " + Brand.Name + " app on your iPhone or Android phone";
  public static string Date(long milliseconds) => DateTimeOffset.FromUnixTimeMilliseconds(milliseconds).ToLocalTime().ToString("d MMM yyyy", CultureInfo.CurrentCulture);
  public static string RowValue(CloudSubscription answer) => answer.State switch
  {
    "gift" => "Included",
    "lapsed" => answer.PaidUntil is { } ended ? "Ended " + Date(ended) : "Ended",
    "paid" => (answer.Plan == "yearly" ? "Yearly" : answer.Plan == "monthly" ? "Monthly" : "Paid") + (answer.PaidUntil is { } paid ? " · paid until " + Date(paid) : ""),
    _ => ""
  };
}

public static class CloudSubscriptionTools
{
  public const string Id = "cloud.subscription";
  public static IReadOnlyList<McpToolSpec> Specs => [new(Id, "cloud_subscription", McpTier.Read,
    JsonSerializer.SerializeToElement(new { type = "object", properties = new { }, additionalProperties = false }))];
  public static void Register(CloudAccountClient account, McpDoor door) => door.Register(Id, (_, _, _) =>
  {
    if (!account.Snapshot.Subscription.ShowsSubscription) throw new McpRefusal("This account has no subscription page.");
    return ValueTask.FromResult(JsonSerializer.SerializeToElement(account.Snapshot.Subscription.LastAnswer, CloudWire.Json));
  });
}
