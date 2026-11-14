using System.Globalization;

namespace TerminalDeck.Core.Cloud;

/// What Settings → Cloud says in each phase. Kept here, away from WinUI, so the words are tested on any machine.
/// `UseCloud`: the "Use Cloud on this PC" switch, present (non-null) only while signed in with Cloud open.
/// `TrustMode`: "How this PC trusts your other devices", present while signed in with a trusted list. `Notices`: the
/// device notices, each with its one button.
public sealed record CloudPageModel(string Title, string Line, string? Button, string? Problem, string? ThisDevice, IReadOnlyList<CloudPageDevice> Devices, bool Busy,
  bool? UseCloud = null, CloudTrustMode? TrustMode = null, IReadOnlyList<CloudPageNotice>? Notices = null);
/// Drawn: `Name` and `Details` (This PC, added, last seen). `DeviceId` is what a press names; it is never drawn.
/// `CanTrust`: "Trust…" (Ask me mode, a new device only).
public sealed record CloudPageDevice(string Name, string Details, bool ThisDevice, string DeviceId = "", bool CanTrust = false);
public enum CloudNoticeAction { Remove, TrustAgain }
public sealed record CloudPageNotice(string Text, string Button, CloudNoticeAction Action, string DeviceId);

/// The top card of Settings → Cloud (second, after General, as on the Mac). Signed out: one line and a modest Sign in
/// that opens the browser sign-in directly. Signed in: name, e-mail and provider, then this PC and the devices.
public sealed record AccountSummaryModel(string Line, string? Button, string? Name, string? Email, string? Provider, string? CloudRow, string? Problem);

public static class CloudPageText
{
  public const string SignIn = "Sign in", SignOut = "Sign out", Cancel = "Cancel";
  public const string SignedOutLine = $"Sign in with your {Brand.Name} account to keep your work on all your devices.";
  public const string SigningInLine = "Finish signing in in your browser, then come back here.";
  /// Owner, 13 Nov: joining is automatic; one switch, on after sign-in, for a person who wants Cloud off on this PC.
  public const string UseCloudToggle = "Use Cloud on this PC";
  public static string UseCloudState(bool on) => on
    ? "On. This PC is part of your Cloud with your other devices."
    : "Off. Nothing of this PC is sent, and nothing from your Cloud arrives here. Nothing is deleted.";

  public static CloudPageModel For(CloudSnapshot s, Func<DateTimeOffset, string>? date = null)
  {
    date ??= d => d.ToLocalTime().ToString("d MMM yyyy", CultureInfo.CurrentCulture);
    return s.Phase switch
    {
      CloudPhase.Dormant or CloudPhase.SignedOut => new("Cloud", SignedOutLine, SignIn, s.Problem, null, [], false),
      CloudPhase.SigningIn => new("Cloud", SigningInLine, Cancel, s.Problem, null, [], true),
      CloudPhase.NotAllowed => new("Cloud", $"You are signed in as {s.Account}. Cloud is not open for this account yet.", SignOut, s.Problem, null, [], false),
      _ => new("Cloud", $"Signed in as {s.Account}.", SignOut, s.TrustNotice is null ? s.Problem : s.Problem is null ? s.TrustNotice : s.Problem + " " + s.TrustNotice, s.ThisDeviceName,
        s.DeviceRows.Select(d => new CloudPageDevice(d.Name, Details(d, date), d.ThisDevice, d.DeviceId,
          s.TrustMode == CloudTrustMode.Ask && d.Trust is { CanBeTrusted: true })).ToArray(), false,
        s.UseCloud, s.TrustMode, Notices(s))
    };
  }

  /// "How this PC trusts your other devices" (owner, 13 Nov).
  public const string TrustModeTitle = "How this PC trusts your other devices";
  public static string TrustModeLabel(CloudTrustMode mode) => mode == CloudTrustMode.Account ? "Automatically, with my account" : "Ask me for each new device";
  public static string TrustModeNote(CloudTrustMode mode) => mode == CloudTrustMode.Account
    ? "Every device you sign in to with your account is trusted here by itself. If a device's identity changes later, its changes wait until you trust it again."
    : "A new device's changes wait until you trust it here. Before you trust one, compare its code on both devices.";
  public const string Remove = "Remove", TrustAgain = "Trust it again", TrustNew = "Trust…", Trust = "Trust", ShowThisPcCode = "Show this PC's code…";
  public static string Joined(string name) => "“" + name + "” joined your account and is now trusted on this PC.";
  public static string KeyChanged(string name) => "“" + name + "” now signs its changes differently than when it joined. Its changes wait on this PC until you trust it again.";
  /// The compare dialog of "Ask me for each new device": the ONLY place a device code is shown.
  public static string CompareTitle(string name) => "Trust “" + name + "” on this PC?";
  public static string CompareText(string name) => "On “" + name + "”, open Settings → Cloud and check that it shows this code for itself. Trust it only if every group matches.";
  public const string ThisPcCodeTitle = "This PC's code";
  public const string ThisPcCodeText = "On your other device, compare this code with the one it shows for this PC.";

  /// A device that joined by itself (a week, until answered) and a device whose key changed (until trusted again).
  private static IReadOnlyList<CloudPageNotice> Notices(CloudSnapshot s)
  {
    var notices = new List<CloudPageNotice>();
    foreach (var d in s.DeviceRows.Where(d => d.Trust is { KeyChanged: true }))
      notices.Add(new(KeyChanged(d.Name), TrustAgain, CloudNoticeAction.TrustAgain, d.DeviceId));
    if (s.TrustMode == CloudTrustMode.Account)
      foreach (var d in s.DeviceRows.Where(d => d.Joined))
        notices.Add(new(Joined(d.Name), Remove, CloudNoticeAction.Remove, d.DeviceId));
    return notices;
  }

  public const string AccountLine = $"One {Brand.Name} account for all your devices";
  public static AccountSummaryModel Account(CloudSnapshot s) => s.Phase switch
  {
    CloudPhase.Dormant or CloudPhase.SignedOut => new(AccountLine, SignIn, null, null, null, null, s.Problem),
    CloudPhase.SigningIn => new(SigningInLine, Cancel, null, null, null, null, s.Problem),
    _ => new(AccountLine, null, string.IsNullOrWhiteSpace(s.DisplayName) ? null : s.DisplayName, s.Email, ProviderName(s.Provider),
      s.Phase == CloudPhase.NotAllowed ? "Not open for this account yet" : s.Phase == CloudPhase.Paused ? "Off on this PC" : "On", s.Problem)
  };
  public static string? ProviderName(string? provider) => provider switch { "google" => "Signed in with Google", "github" => "Signed in with GitHub", _ => null };

  private static string Details(CloudDeviceRow d, Func<DateTimeOffset, string> date)
  {
    var parts = new List<string>();
    if (d.ThisDevice) parts.Add("This PC");
    if (d.Added is { } added) parts.Add("Added " + date(added));
    parts.Add(d.LastSeen is { } seen ? "Last seen " + date(seen) : "Not seen yet");
    return string.Join(" · ", parts);
  }
}
