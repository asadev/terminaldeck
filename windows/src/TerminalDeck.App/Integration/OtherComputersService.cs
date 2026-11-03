using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Computers;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

public sealed record SavedComputer(string Id, MachineOffer Offer, byte[] Identity, string Token, bool DrivesWindows = false);
public sealed record ComputerConnection(string Id, string Name, string Platform, string State, string? Note, string[] Capabilities, JsonElement[] Displays, string Fingerprint = "", string? AppVersion = null);

// Outbound credentials are private to this Windows user AND this app data root.
// They are separate from devices allowed to come into this computer.
public sealed partial class OtherComputersService : IAsyncDisposable
{
  private readonly JsonStateStore<byte[]> store;
  private readonly CurrentUserDpapi protector;
  private readonly System.Collections.Concurrent.ConcurrentDictionary<string, SavedComputer> saved = new();
  private readonly Dictionary<string, ComputerConnection> views = [];
  private readonly Dictionary<string, (ComputerChannel Channel, CancellationTokenSource Stop)> links = [];
  /// The direct link's engine (contract §11): connections ask for the link and, when offered, run on it only (the
  /// screen as H.264). Null: today's relay connection.
  public ILinkAnswerEngine? LinkEngine { get; set; }
  /// The path a computer's connection runs on now ("host", "internet", "turn"), or null (relay, or not connected).
  public string? LinkRoute(string id)
  {
    try { return links.TryGetValue(id, out var link) ? link.Channel.LinkRoute : null; }
    catch (InvalidOperationException) { return null; }
  }
  private readonly SemaphoreSlim mutations = new(1);
  public event Action? Changed;
  public event Action<string, JsonElement>? Frame;
  public IReadOnlyList<ComputerConnection> List() { lock (views) return views.Values.OrderBy(v => v.Name).ToArray(); }
  public OtherComputersService(AppDataRoot root)
  {
    store = new(root, "other-computers-protected"); protector = new(root);
    System.Net.NetworkInformation.NetworkChange.NetworkAvailabilityChanged += NetworkChanged;
    if (store.Load() is not { } encrypted) return;
    var plain = protector.Unprotect(encrypted);
    try
    {
      foreach (var row in JsonSerializer.Deserialize<SavedComputer[]>(plain) ?? [])
      {
        if (row.Identity.Length != 32 || !PairingCode.IsHostId(row.Offer.HostId)) continue;
        saved[row.Id] = row;
        views[row.Id] = new(row.Id, row.Offer.Name, row.Offer.Platform, "Disconnected", null, [], [], PairingCode.Fingerprint(row.Offer.PublicKey));
      }
    }
    finally { CryptographicOperations.ZeroMemory(plain); }
  }
  private void Save()
  {
    var plain = JsonSerializer.SerializeToUtf8Bytes(saved.Values.ToArray());
    try { store.Save(protector.Protect(plain)); }
    finally { CryptographicOperations.ZeroMemory(plain); }
  }
  public async Task<string> PairAsync(string raw, CancellationToken ct)
  {
    var code = PairingCode.Normalize(raw) ?? throw new ArgumentException("Type the six-digit code shown on the other computer.");
    await mutations.WaitAsync(ct);
    try
    {
      using var lookup = await Task.Run(() => PairingCode.Derive(code), ct);
      using var guest = NoiseIdentity.Generate();
      await using var beacon = new ComputerChannel();
      await beacon.OpenAsync(new(RelayEndpoint.Default, lookup.HostId, lookup.Keys.PublicKey, "", ""), guest, ct);
      using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(15));
      var offer = MachineOffer.Decode(JsonSerializer.SerializeToUtf8Bytes(await beacon.ReceiveAsync(deadline.Token)));
      var seed = RandomNumberGenerator.GetBytes(32);
      try
      {
        using var identity = new NoiseIdentity(seed);
        await using var channel = new ComputerChannel(); await channel.OpenAsync(offer, identity, deadline.Token);
        await channel.SendAsync(new { t = "hello", protocol = 1, token = code, device = new { name = Environment.MachineName, platform = "win32" }, capabilities = browserDoor is null ? Array.Empty<string>() : new[] { "windows" } }, deadline.Token);
        var answer = await channel.ReceiveAsync(deadline.Token);
        if (answer.GetProperty("t").GetString() != "welcome" || !answer.TryGetProperty("token", out var token) || token.ValueKind != JsonValueKind.String || string.IsNullOrEmpty(token.GetString()))
          throw new ProtocolException("That computer did not return a pairing credential. Make a fresh code there and try again.");
        var id = offer.HostId;
        if (saved.ContainsKey(id)) throw new InvalidOperationException("That computer is already paired. Connect it from the list.");
        saved[id] = new(id, offer, seed.ToArray(), token.GetString()!);
        try { Save(); } catch { saved.TryRemove(id, out _); throw; }
        Set(new(id, offer.Name, offer.Platform, "Awaiting approval", "Choose Let it in on that computer, then Connect here.", [], [], PairingCode.Fingerprint(offer.PublicKey)));
        return id;
      }
      finally { CryptographicOperations.ZeroMemory(seed); }
    }
    finally { mutations.Release(); }
  }
  public async Task ConnectAsync(string id, CancellationToken ct = default)
  {
    await mutations.WaitAsync(ct);
    try
    {
      if (links.ContainsKey(id)) return;
      if (!saved.TryGetValue(id, out var row)) throw new ArgumentException("Choose a paired computer.");
      wanted.TryAdd(id, 0);
      var stop = new CancellationTokenSource(); var channel = new ComputerChannel { LinkEngine = LinkEngine };
      Set(new(id, row.Offer.Name, row.Offer.Platform, "Connecting", null, [], [], PairingCode.Fingerprint(row.Offer.PublicKey)));
      try
      {
        using var identity = new NoiseIdentity(row.Identity);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct, stop.Token); deadline.CancelAfter(TimeSpan.FromSeconds(15));
        await channel.OpenAsync(row.Offer, identity, deadline.Token);
        // link.dc2 + link.only: everything after the welcome on the direct link when the other computer offers it (§11).
        await channel.SendAsync(new { t = "hello", protocol = 1, token = row.Token, device = new { name = Environment.MachineName, platform = "win32" }, capabilities = (browserDoor is null ? Array.Empty<string>() : new[] { "windows" }).Concat(channel.LinkCapabilities).ToArray() }, deadline.Token);
        var answer = await channel.ReceiveAsync(deadline.Token);
        if (answer.GetProperty("t").GetString() != "welcome") throw new ProtocolException(Text(answer, "message", "That computer has not approved this connection."));
        var caps = answer.GetProperty("capabilities").EnumerateArray().Take(128).Select(c => c.GetString() ?? "").ToArray();
        links[id] = (channel, stop);
        AcceptSnapshot(id, answer);
        Set(new(id, row.Offer.Name, Text(answer, "hostPlatform", row.Offer.Platform), "Online", null, caps, [], PairingCode.Fingerprint(row.Offer.PublicKey), Text(answer, "appVersion", Text(answer, "version", ""))));
        Frame?.Invoke(id, answer);
        _ = ReadAsync(id, channel, stop);
        _ = RestoreWatchesAsync(id, stop.Token);
        if (caps.Contains("sims")) await channel.SendAsync(new { t = "sims.list", rid = "computers-displays" }, ct);
      }
      catch
      {
        await channel.DisposeAsync(); stop.Dispose(); Set(new(id, row.Offer.Name, row.Offer.Platform, "Disconnected", "Couldn’t connect. Check approval and connectivity on that computer. Retrying automatically.", [], [], PairingCode.Fingerprint(row.Offer.PublicKey))); ScheduleReconnect(id); throw;
      }
    }
    finally { mutations.Release(); }
  }
  private async Task ReadAsync(string id, ComputerChannel channel, CancellationTokenSource stop)
  {
    try
    {
      while (!stop.IsCancellationRequested)
      {
        var frame = await channel.ReceiveAsync(stop.Token);
        var tag = frame.GetProperty("t").GetString();
        if (tag == "error" && !frame.TryGetProperty("rid", out _) && Text(frame, "code", "") is "unauthorized" or "unauthenticated") throw new ProtocolException(Text(frame, "message", "The other computer changed access."));
        AcceptSnapshot(id, frame);
        CompleteRequest(id, frame);
        if (tag == "window.call") _ = ServeBrowserAsync(id, frame.Clone(), stop.Token);
        if (tag is "net.data" or "net.ack" or "net.close" or "tunnel.closed") await HandlePortAsync(id, frame);
        if (tag == "sims.rows" && frame.TryGetProperty("devices", out var devices))
        {
          ComputerConnection? view; lock (views) views.TryGetValue(id, out view);
          if (view is not null) Set(view with { Displays = devices.EnumerateArray().Where(d => Text(d, "platform", "") is "mac" or "windows").Take(32).Select(d => d.Clone()).ToArray() });
        }
        Frame?.Invoke(id, frame);
      }
    }
    catch (Exception ex) when (ex is IOException or System.Net.WebSockets.WebSocketException or ProtocolException or OperationCanceledException or JsonException or InvalidOperationException)
    {
      if (!stop.IsCancellationRequested)
      {
        ComputerConnection? view; lock (views) views.TryGetValue(id, out view);
        // No direct path (contract §11.3): the plain truth, and the normal retries.
        var note = ex is IOException { Message: LinkGuest.Unreachable } ? "Can't reach " + (view?.Name ?? "that computer") + " — this network blocks the direct connection. Retrying automatically." : "The connection ended. Connect again to resume.";
        if (view is not null) Set(view with { State = "Disconnected", Note = note, Displays = [] });
      }
    }
    finally
    {
      await mutations.WaitAsync();
      try { if (links.TryGetValue(id, out var current) && ReferenceEquals(current.Channel, channel)) links.Remove(id); }
      finally { mutations.Release(); }
      await channel.DisposeAsync(); stop.Dispose();
      CancelUpload(id);
      RevokeBrowser(id);
      foreach (var reach in reaches.Values.Where(r => r.Computer == id)) await ClosePortAsync(id, reach.Remote);
      ScheduleReconnect(id);
    }
  }
  public async Task SendAsync(string id, object message, CancellationToken ct = default)
  {
    ComputerChannel channel;
    await mutations.WaitAsync(ct);
    try { channel = links.TryGetValue(id, out var link) ? link.Channel : throw new InvalidOperationException("Connect that computer first."); }
    finally { mutations.Release(); }
    await channel.SendAsync(message, ct);
  }
  public async Task DisconnectAsync(string id)
  {
    wanted.TryRemove(id, out _);
    CancelUpload(id);
    RevokeBrowser(id);
    foreach (var reach in reaches.Values.Where(r => r.Computer == id)) await ClosePortAsync(id, reach.Remote);
    FailRequests(id);
    await mutations.WaitAsync();
    try { if (links.Remove(id, out var link)) { link.Stop.Cancel(); await link.Channel.DisposeAsync(); } }
    finally { mutations.Release(); }
    ComputerConnection? view; lock (views) views.TryGetValue(id, out view); if (view is not null) Set(view with { State = "Disconnected", Note = null, Displays = [] });
  }
  public async Task ForgetAsync(string id)
  {
    await DisconnectAsync(id); await mutations.WaitAsync();
    try
    {
      if (!saved.TryRemove(id, out var row)) return;
      try { Save(); } catch { saved[id] = row; throw; }
      CryptographicOperations.ZeroMemory(row.Identity); lock (views) views.Remove(id); Changed?.Invoke();
    }
    finally { mutations.Release(); }
  }
  private void Set(ComputerConnection view) { lock (views) views[view.Id] = view; Changed?.Invoke(); }
  public static string Text(JsonElement value, string field, string fallback) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(field, out var found) && found.ValueKind == JsonValueKind.String ? found.GetString() ?? fallback : fallback;
  public async ValueTask DisposeAsync()
  {
    string[] ids; await mutations.WaitAsync(); try { ids = links.Keys.ToArray(); } finally { mutations.Release(); }
    lifetime.Cancel();
    System.Net.NetworkInformation.NetworkChange.NetworkAvailabilityChanged -= NetworkChanged;
    foreach (var id in ids) await DisconnectAsync(id);
    foreach (var row in saved.Values) CryptographicOperations.ZeroMemory(row.Identity);
  }
}
