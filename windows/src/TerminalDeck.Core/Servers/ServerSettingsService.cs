using System.Text.Json;

namespace TerminalDeck.Core.Servers;

public sealed partial class ServerService
{
  public event Action<SavedServer>? SettingsChanged;
  private static readonly JsonSerializerOptions SettingsJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true };
  public async ValueTask<IReadOnlyList<ServerSshAlias>> SshAliasesAsync(ServerCaller caller, CancellationToken ct = default)
  {
    Owner(caller); await caller.RecheckAsync(ct);
    if (aliases is null) throw new ServerRefusal("SSH alias discovery is not connected to this PC.");
    var rows = await aliases(ct); await caller.RecheckAsync(ct); return rows;
  }
  public async ValueTask<ServerSettingsSnapshot> SettingsAsync(string id, ServerCaller caller, CancellationToken ct = default)
  {
    Owner(caller); await caller.RecheckAsync(ct); var server = Get(id, caller);
    JsonElement data;
    try { data = await HostingCallAsync(server, "read", null, ct); }
    catch (IOException ex)
    {
      await caller.RecheckAsync(ct); _ = Get(id, caller);
      var problem = "Could not read hosting and alerts. " + ServerText.Mask(ex.Message);
      return new(server, new(false, false, false, null, null, null, ServerHostingScripts.Version, null, [], problem) { Observed = false }, new(), [], server.ShownApps ?? []) { AlertsProblem = problem };
    }
    var hosting = data.GetProperty("hosting").Deserialize<ServerHostingStatus>(SettingsJson) ?? throw new IOException("The server's hosting status is unreadable.");
    var alerts = data.GetProperty("alerts").Deserialize<ServerAlertSettings>(SettingsJson) ?? new();
    string? Mask(string? secret) => string.IsNullOrEmpty(secret) ? null : ServerSettingsRules.SecretMask;
    alerts = alerts with { Channels = (alerts.Channels ?? []).Select(c => c with { BotToken = Mask(c.BotToken), Password = Mask(c.Password), Secret = Mask(c.Secret), Token = Mask(c.Token) }).ToArray() };
    var history = data.GetProperty("history").Deserialize<ServerAlertEntry[]>(SettingsJson) ?? [];
    IReadOnlyList<ServerApp> apps;
    try { apps = await AppsInventoryAsync(id, caller, ct); }
    catch (IOException) { apps = []; }
    await caller.RecheckAsync(ct); _ = Get(id, caller);
    return new(server, hosting, alerts, history, apps.Select(a => a.Name).Union(server.ShownApps ?? []).Distinct().Order().ToArray());
  }
  public async ValueTask SaveSettingsAsync(string id, ServerSettingsPatch patch, ServerCaller caller, CancellationToken ct = default)
  {
    Owner(caller);
    if (patch.SetHootGrant && patch.HootGrantUntil is { } until && (until <= DateTimeOffset.UtcNow || until > DateTimeOffset.UtcNow.AddHours(1).AddSeconds(5))) throw new ServerRefusal("Allow Hoot for up to one hour, or revoke the grant.");
    await ChangeAsync(id, caller, "change server settings", "App visibility, landing folder, browser consent and this server's temporary Hoot grant", true, false, async before =>
    {
      await store.UpdateSettingsAsync(id, current => current with
      {
        ShownApps = patch.SetShownApps ? patch.ShownApps?.Distinct().ToArray() : current.ShownApps,
        LandingFolder = patch.SetLandingFolder ? string.IsNullOrWhiteSpace(patch.LandingFolder) ? null : patch.LandingFolder : current.LandingFolder,
        DrivesBrowser = patch.DrivesBrowser ?? current.DrivesBrowser,
        HootGrantUntil = patch.SetHootGrant ? patch.HootGrantUntil : current.HootGrantUntil
      }, ct);
      SettingsChanged?.Invoke(store.Get(id));
    }, ct);
  }
  public async ValueTask<ServerHostingStatus> HostingAsync(string id, string action, ServerCaller caller, CancellationToken ct = default)
  {
    Owner(caller);
    if (action is not ("read" or "setup" or "remove")) throw new ServerRefusal("Choose read, setup or remove.");
    if (action == "read") { Owner(caller); return (await SettingsAsync(id, caller, ct)).Hosting; }
    JsonElement response = default;
    await ChangeAsync(id, caller, action + " server helpers", "Set up/remove this app's server-side helper and timer. Setup installs Docker from https://get.docker.com when missing. Removal keeps Docker, apps, volumes and backups.", false, action == "remove", async server => response = await HostingCallAsync(server, action, null, ct), ct);
    return response.GetProperty("hosting").Deserialize<ServerHostingStatus>(SettingsJson) ?? throw new IOException("The server's hosting status is unreadable.");
  }
  public async ValueTask SaveAlertsAsync(string id, ServerAlertSettings settings, ServerCaller caller, CancellationToken ct = default)
  {
    Owner(caller); ServerSettingsRules.Alerts(settings);
    await ChangeAsync(id, caller, "save server alerts", "Save alert thresholds and destinations on this server; secret values stay there and are never returned.", false, false, async server => { await HostingCallAsync(server, "save-alerts", settings, ct); }, ct);
  }
  public async ValueTask<ServerAlertDelivery[]> TestAlertsAsync(string id, ServerCaller caller, CancellationToken ct = default)
  {
    Owner(caller); JsonElement response = default;
    await ChangeAsync(id, caller, "test server alerts", "Send one test alert from this server to each enabled saved channel.", false, false, async server => response = await HostingCallAsync(server, "test-alerts", null, ct), ct);
    return response.GetProperty("deliveries").Deserialize<ServerAlertDelivery[]>(SettingsJson) ?? [];
  }
  public async ValueTask<string> OpenTerminalAtAsync(string id, string? folder, ServerCaller caller, CancellationToken ct = default)
  {
    if (terminal is null) throw new ServerRefusal("The server terminal owner is not connected.");
    if (folder is not null) ServerValidation.Path(folder);
    string? session = null;
    await ChangeAsync(id, caller, "open terminal", "An SSH session can run commands outside Files folder limits.", false, false, async server =>
    { session = await terminal.OpenAsync(new(server with { LandingFolder = folder ?? server.LandingFolder }) { StartIn = folder ?? server.LandingFolder }, ct); }, ct);
    return session ?? throw new IOException("The server terminal did not open.");
  }
  private async ValueTask<JsonElement> HostingCallAsync(SavedServer server, string action, object? value, CancellationToken ct)
  {
    var output = await RunAsync(server, ServerHostingScripts.Command(action, value), ct);
    if (output.Output.Length > 262144) throw new IOException("The server settings response was too large.");
    try { using var doc = JsonDocument.Parse(output.Output); return doc.RootElement.Clone(); }
    catch (JsonException) { throw new IOException("The server settings response was unreadable."); }
  }
  private async ValueTask<IReadOnlyList<ServerApp>> AppsInventoryAsync(string id, ServerCaller caller, CancellationToken ct)
  {
    var server = Get(id, caller); var output = await RunAsync(server, new("if command -v docker >/dev/null 2>&1; then docker ps -a --no-trunc --format '{{json .}}'; fi"), ct);
    _ = Get(id, caller); return ServerResponses.Apps(output.Output);
  }
}
