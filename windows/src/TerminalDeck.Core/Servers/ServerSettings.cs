using System.Text.Json;

namespace TerminalDeck.Core.Servers;

public sealed record ServerSshAlias(string Alias, string Host, int Port, string User, string[] KeyNames);
public sealed record ServerSettingsPatch
{
  public bool SetShownApps { get; init; }
  public string[]? ShownApps { get; init; }
  public bool SetLandingFolder { get; init; }
  public string? LandingFolder { get; init; }
  public bool? DrivesBrowser { get; init; }
  public bool SetHootGrant { get; init; }
  public DateTimeOffset? HootGrantUntil { get; init; }
}
public sealed record ServerAlertChannel(string Id, string Kind, string Name, bool Enabled = true)
{
  public string? BotToken { get; init; }
  public string? ChatId { get; init; }
  public string? SmtpUrl { get; init; }
  public string? Username { get; init; }
  public string? Password { get; init; }
  public string? From { get; init; }
  public string[] To { get; init; } = [];
  public string? Url { get; init; }
  public string? Secret { get; init; }
  public string? Token { get; init; }
  public override string ToString() => "<private alert destination>";
}
public sealed record ServerAlertSettings(bool Enabled = false, ServerAlertChannel[]? Channels = null, int DiskPercent = 85, int MemoryPressure = 20, int CertDays = 14, int RemindMinutes = 1440, string[]? WatchContainers = null);
public sealed record ServerAlertDelivery(string Id, bool Ok);
public sealed record ServerAlertEntry(long Id, string Severity, string Title, string Message, string? App, DateTimeOffset At, ServerAlertDelivery[] Delivered);
public sealed record ServerHostFacts(string System, string Hostname, string User, string[] Listeners, string? PackageManager);
public sealed record ServerHostingStatus(bool Installed, bool Administrator, bool Supported, string? Docker, string? Hostname, string? InstalledVersion, string HelperVersion, string? RouterSummary, string[] Duties, string? Problem = null)
{
  public bool Observed { get; init; } = true;
  public ServerHostFacts? Facts { get; init; }
  public string? SetupState { get; init; }
  public string? SetupProblem { get; init; }
}
public sealed record ServerSettingsSnapshot(SavedServer Server, ServerHostingStatus Hosting, ServerAlertSettings Alerts, ServerAlertEntry[] History, string[] SeenApps)
{
  public string? AlertsProblem { get; init; }
}

public sealed partial class ServerStore
{
  internal async ValueTask UpdateSettingsAsync(string id, Func<SavedServer, SavedServer> update, CancellationToken ct)
  {
    using var lease = await store.AcquireWriteAsync(ct); var current = Get(id); var next = update(current);
    ServerSettingsRules.Validate(next); store.Save(List().Select(row => row.Id == id ? next : row).ToArray());
  }
}
public static class ServerSettingsRules
{
  public const string SecretMask = "••••••••";
  public static void Validate(SavedServer server)
  {
    if (server.ShownApps is { } apps && (apps.Length > 500 || apps.Any(s => !Name(s, 128)))) throw new ServerRefusal("Choose up to 500 app names.");
    if (server.LandingFolder is { } folder) ServerValidation.Path(folder);
    if (server.SshAlias is { } alias && (alias.Length > 128 || !alias.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.'))) throw new ServerRefusal("Choose a literal SSH alias.");
  }
  public static bool Name(string text, int max) => text.Length is > 0 && text.Length <= max && !text.Any(char.IsControl);
  public static bool Shown(SavedServer server, ServerApp app) => server.ShownApps is null || server.ShownApps.Contains(app.Name, StringComparer.Ordinal);
  public static bool TimedGrantAllows(SavedServer server, ServerCaller caller, string operation, DateTimeOffset now) => caller.IsHoot && !caller.PairedDevice && !server.Access.LookOnly && server.HootGrantUntil > now && operation is "start app" or "stop app" or "restart app";
  public static void Alerts(ServerAlertSettings value)
  {
    if (value.DiskPercent is < 50 or > 99 || value.MemoryPressure is < 1 or > 100 || value.CertDays is < 1 or > 60 || value.RemindMinutes is < 10 or > 10080 || value.Channels?.Length > 10 || value.WatchContainers?.Length > 50) throw new ServerRefusal("Choose valid alert limits and up to ten channels.");
    var channels = value.Channels ?? [];
    if (channels.Any(c => c is null || c.To is null)) throw new ServerRefusal("Each alert channel needs valid fields.");
    if (channels.Select(c => c.Id).Distinct().Count() != channels.Length) throw new ServerRefusal("Each channel needs its own ID.");
    foreach (var channel in channels)
    {
      if (!Name(channel.Id, 48) || !channel.Id.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_') || !Name(channel.Name, 80) || channel.Kind is not ("telegram" or "email" or "webhook" or "receiver")) throw new ServerRefusal("Choose a channel name and supported kind.");
      foreach (var text in new[] { channel.BotToken, channel.ChatId, channel.SmtpUrl, channel.Username, channel.Password, channel.From, channel.Url, channel.Secret, channel.Token }.Concat(channel.To))
        if (text is not null && (text.Length > 2048 || text.Any(char.IsControl))) throw new ServerRefusal("Alert fields must be bounded single-line values.");
      if (channel.Kind is "webhook" or "receiver" && (!Uri.TryCreate(channel.Url, UriKind.Absolute, out var uri) || (uri.Scheme != "https" && !(channel.Kind == "webhook" && uri.Scheme == "http" && uri.IsLoopback)) || !string.IsNullOrEmpty(uri.UserInfo))) throw new ServerRefusal("Use an HTTPS alert URL without embedded credentials.");
      if (channel.Kind == "telegram" && !Name(channel.ChatId ?? "", 40)) throw new ServerRefusal("Enter the Telegram chat ID.");
      if (channel.Kind == "email" && (!Uri.TryCreate(channel.SmtpUrl, UriKind.Absolute, out var smtp) || smtp.Scheme is not ("smtp" or "smtps") || !string.IsNullOrEmpty(smtp.UserInfo) || channel.To.Length is < 1 or > 10 || channel.To.Append(channel.From ?? "").Any(a => !a.Contains('@') || a.Any(char.IsWhiteSpace)))) throw new ServerRefusal("Enter an SMTP server, sender and 1–10 recipients.");
    }
    foreach (var name in value.WatchContainers ?? []) if (!Name(name, 128) || !name.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '-' or '.')) throw new ServerRefusal("Choose literal container names.");
  }
}
