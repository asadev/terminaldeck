using System.Globalization;
using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Cloud;

public sealed record CloudSubscription(string Paywall, string State, string? Plan = null, long? PaidUntil = null,
  string? Source = null, int IncludedGb = 100, int ExtraGb = 0, bool Offer = false, long? DataKeptUntil = null,
  string? Tier = null, bool? CanBuyStorage = null)
{
  public bool Entitled => State is "paid" or "gift";
  /// 19 Nov free plan: the account's own tier, the paywall on or off: the service's `tier` ("paid" for state paid or
  /// gift, else "free"), or from `state` on an older service that does not send it.
  public string AccountTier => Tier ?? (Entitled ? "paid" : "free");
  /// Asad, 19 Nov: a FREE account (paywall on, tier free) reaches its computers' sessions from its other devices and
  /// nothing more. This PC then serves another device sessions only (`RemoteFreePlan`), and Cloud sync does not run.
  /// Restricted ONLY when `paywall == on && tier == free` (Cloud API note, 20 Nov).
  public bool LimitsRemoteToSessions => Paywall == "on" && AccountTier == "free";
  public static CloudSubscription Read(byte[] body)
  {
    var answer = JsonSerializer.Deserialize<CloudSubscription>(body, CloudWire.Json) ?? throw new JsonException();
    if (answer.Paywall is not ("off" or "on") || answer.State is not ("paid" or "gift" or "none" or "lapsed")
      || answer.Plan is not (null or "monthly" or "yearly") || answer.Source is not (null or "apple" or "google" or "gift") || answer.Tier is not (null or "free" or "paid")
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
  /// 19 Nov free plan: this PC serves another device sessions only (`RemoteFreePlan`), and Cloud sync does not run. Like
  /// every payment rule here it holds only on a known answer: no answer, a failed read or an older service leave
  /// everything served as before.
  public bool LimitsRemoteToSessions => Available && LastAnswer?.LimitsRemoteToSessions == true;
  /// The relay itself (this PC reachable by its devices, this PC reaching its other computers): paid, or a free
  /// account's sessions. What each request may do is decided per kind (`RemoteFreePlan`).
  public bool AllowsRemoteSessions => AllowsCloudServices || LimitsRemoteToSessions;
  // Desktop's strict off rule overrides preview offers: off adds no row, page or tool, except (19 Nov) a gift, which
  // shows its plan with the paywall off too.
  public bool ShowsSubscription => Available && (LastAnswer?.Paywall == "on" || LastAnswer?.State == "gift");
  public CloudSubscriptionSnapshot Received(CloudSubscription? answer) => new(answer ?? LastAnswer, answer is not null);
  public bool Offers(CloudPaidPlace place, bool existing = true) =>
    existing && (AllowsCloudServices || LimitsRemoteToSessions && FreeAccountPlaces.Contains(place));
  /// 19 Nov free plan (Decker, 20 Nov: "He started in Windows. He can see and control from Mac"): what a FREE account
  /// keeps on a computer: its devices (the Devices page and its switch) and its other computers' sessions (live through
  /// the relay: open, control, continue, start). Everything else stays paid, other computers' screens included (the
  /// Mac's `freeAccountPlaces`).
  public static IReadOnlySet<CloudPaidPlace> FreeAccountPlaces { get; } = new HashSet<CloudPaidPlace> { CloudPaidPlace.Devices, CloudPaidPlace.OtherComputerSessions };
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
  /// 19 Nov free plan: the tools for other computers' sessions (look; sessions, chats, Hoot and a file into a session
  /// there) stay with a free account, as its sessions do (the Mac's machines.look, .session, .copilot, .upload). Managing
  /// computers, their screens and their local web ports stay paid.
  public static IReadOnlySet<string> FreeAccountTools { get; } = new HashSet<string>(StringComparer.Ordinal) { "computers.look", "computers.services" };
  public static bool ShowsTool(CloudSubscriptionSnapshot state, string id) => id == CloudSubscriptionTools.Id ? state.ShowsSubscription
    : !PaidTool(id) || state.AllowsCloudServices || FreeAccountTools.Contains(id) && state.Offers(CloudPaidPlace.OtherComputerSessions);
  public static bool PaidCommand(string id) => id is "join-remote" or "devices" or "cloud" or "cloud-page" or "settings:cloud" or "settings:devices"
    || id.StartsWith("cloud-session:", StringComparison.Ordinal) || id.StartsWith("cloud-earlier:", StringComparison.Ordinal);
  // The Devices page stays with a free account (19 Nov free plan); joining by code stays paid.
  public static bool ShowsCommand(CloudSubscriptionSnapshot state, string id) => id is "devices" or "settings:devices" ? state.Offers(CloudPaidPlace.Devices)
    : !PaidCommand(id) || state.AllowsCloudServices;
}

// "Terminal Deck Cloud" in Settings, word for word as on the Mac (NativeCloudPlanWords, lane/mac-free-tier, and
// PAYMENTS-DESIGN.md "19 Nov changes"): free = one line of what it adds, the price and where to subscribe; paid = the plan
// and its date; gift = the paid plan at no charge ("Gift · no charge"), the paywall on or off. Names and dates, no ids.
public static class CloudSubscriptionPageText
{
  public const string Id = "terminal-deck-cloud";
  public static string Title => Brand.Name + " Cloud";
  /// One line of what it adds: a free account's sessions on its computers, from every device, are free already.
  public static string Benefit(int includedGb = 100) => $"Browser, simulators and screen sharing, Cloud sync and tasks on every device, and {includedGb} GB of Cloud storage.";
  public const string Price = "$8.00 a month, or $67.00 a year";
  public static string Subscribe => "Subscribe in the " + Brand.Name + " app on your phone";
  /// A plan given to the account (Asad, 19 Nov: "it should show which value subscription it is but it is not paid, it
  /// is a gift").
  public const string Gift = "Gift · no charge";
  public static string Date(long milliseconds) => DateTimeOffset.FromUnixTimeMilliseconds(milliseconds).ToLocalTime().ToString("d MMM yyyy", CultureInfo.CurrentCulture);
  public static string Plan(string? plan) => plan switch { "monthly" => "Monthly", "yearly" => "Yearly", _ => Title };
  /// The row's short state at its right: the plan and its date when paid, the gift, when it ended; else nothing.
  public static string? RowValue(CloudSubscription answer) => answer.State switch
  {
    "paid" => Plan(answer.Plan) + (answer.PaidUntil is { } paid ? " · paid until " + Date(paid) : ""),
    "gift" => Gift,
    "lapsed" => answer.PaidUntil is { } ended ? "Ended " + Date(ended) : "Ended",
    _ => null
  };
  /// After the plan ended: when, and until when the data is kept (each only when the account says it).
  public static string? Ended(CloudSubscription answer)
  {
    if (answer.State != "lapsed") return null;
    var when = answer.PaidUntil is { } until ? "Your plan ended on " + Date(until) + "." : "Your plan has ended.";
    return when + (answer.DataKeptUntil is { } kept ? " Your Cloud data is kept until " + Date(kept) + "." : "");
  }
  public static string Storage(CloudSubscription answer) => $"{(long)answer.IncludedGb + Math.Max(0, answer.ExtraGb)} GB";
  public static string? StorageInfo(CloudSubscription answer) => answer.ExtraGb > 0 ? $"{answer.IncludedGb} GB with the plan and {answer.ExtraGb} GB of extra storage." : null;
  public static string? Source(string? source) => source switch { "apple" => "Apple", "google" => "Google Play", _ => null };
  /// Where the plan is changed: in the phone app it was bought in (a plan given to the account has nothing to change).
  public static string? Manage(string? source) => source switch
  {
    "apple" => "Change or cancel it in the " + Brand.Name + " app on your iPhone.",
    "google" => "Change or cancel it in the " + Brand.Name + " app on your Android phone.",
    _ => null
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
