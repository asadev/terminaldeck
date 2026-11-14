using System.Globalization;

namespace TerminalDeck.Core.Cloud;

/// What Settings → Cloud says in each phase. Kept here, away from WinUI, so the words are tested on any machine.
/// `UseCloud`: the "Use Cloud on this PC" switch, present (non-null) only while signed in with Cloud open.
public sealed record CloudPageModel(string Title, string Line, string? Button, string? Problem, string? ThisDevice, IReadOnlyList<CloudPageDevice> Devices, bool Busy,
  bool? UseCloud = null);
public sealed record CloudPageDevice(string Name, string Details, string Code, bool ThisDevice);

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
      _ => new("Cloud", $"Signed in as {s.Account}.", SignOut, s.Problem, s.ThisDeviceName,
        s.DeviceRows.Select(d => new CloudPageDevice(d.Name + (d.ThisDevice ? " (this PC)" : ""), Details(d, date), d.ShortCode, d.ThisDevice)).ToArray(), false,
        s.UseCloud)
    };
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
    if (d.Removed) parts.Add("Removed");
    parts.Add(d.Added is { } added ? "Added " + date(added) : "Added date not known");
    parts.Add(d.LastSeen is { } seen ? "last seen " + date(seen) : "not seen yet");
    return string.Join(" · ", parts);
  }
}
