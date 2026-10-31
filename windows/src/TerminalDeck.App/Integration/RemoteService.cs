using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

public sealed class DeviceStore(AppDataRoot root) : IDeviceTrustPersistence
{
  private readonly JsonStateStore<byte[]> store = new(root, "devices-protected");
  private readonly CurrentUserDpapi protector = new(root);
  public IReadOnlyList<StoredDevice> Load()
  {
    var data = store.Load();
    if (data is null) return [];
    var plain = protector.Unprotect(data);
    try { return JsonSerializer.Deserialize<StoredDevice[]>(plain) ?? []; }
    finally { CryptographicOperations.ZeroMemory(plain); }
  }
  public void Save(IReadOnlyList<StoredDevice> devices)
  {
    var plain = JsonSerializer.SerializeToUtf8Bytes(devices);
    try { store.Save(protector.Protect(plain)); }
    finally { CryptographicOperations.ZeroMemory(plain); }
  }
}

public sealed class RemoteService : IAsyncDisposable
{
  private readonly WindowsCredentialStore secrets;
  private readonly string secretPrefix;
  private readonly Func<IReadOnlyList<SessionRecord>> sessions;
  private readonly CancellationTokenSource stop = new();
  private readonly List<Task> tasks = [];
  public Func<IRelayPhoneApplication, IPhoneSessionView, IRelayPhoneApplication>? WrapApplication { get; set; }
  private IRelayPhoneApplication? application;
  private NoiseIdentity? identity;
  private RelayHostClient? relay;
  private CancellationTokenSource? pairingStop;
  public IRelayMcpApplication? McpBridge { get; set; }
  public string? McpAddress => hostSecret is null ? null : "https://relay.terminaldeck.dev/mcp/" + PairingCode.HostId(hostSecret);
  public DeviceTrust Trust { get; }
  public PhoneSessionGrants Grants { get; }
  public RelayConnectionState State { get; private set; } = RelayConnectionState.Stopped;
  public event Action? Changed;
  public RemoteService(AppDataRoot root, Func<IReadOnlyList<SessionRecord>> readSessions)
  {
    secrets = new(root); secretPrefix = $"{Brand.Name}/{root.NamespaceId}/"; sessions = readSessions;
    Trust = new(new DeviceStore(root));
    Grants = new(new JsonStateStore<SessionGrantState>(root, "phone-grants"));
    Trust.Changed += () => Changed?.Invoke();
  }
  private byte[]? hostSecret;
  public async Task StartAsync()
  {
    if (relay is not null) return;
    hostSecret = await SecretAsync("remote-host");
    var key = await SecretAsync("remote-identity");
    try { identity = new(key); } finally { CryptographicOperations.ZeroMemory(key); }
    var view = new SessionView(sessions, Grants);
    application = new PhoneLink(Trust, Environment.MachineName, "0.1.0-windows", view);
    application = WrapApplication?.Invoke(application, view) ?? application;
    relay = new(RelayEndpoint.Default, hostSecret, identity, application, mcp: McpBridge);
    relay.StateChanged += state => { State = state; Changed?.Invoke(); };
    tasks.Add(relay.RunAsync(stop.Token));
  }
  private async Task<byte[]> SecretAsync(string name)
  {
    name = secretPrefix + name;
    var value = await secrets.ReadAsync(name);
    if (value is { Length: 32 }) return value;
    value = RandomNumberGenerator.GetBytes(32); await secrets.WriteAsync(name, value); return value;
  }
  public async Task<PairingOffer> ShowCodeAsync()
  {
    await StartAsync();
    pairingStop?.Cancel();
    var offer = Trust.Pairing.Create();
    pairingStop = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
    pairingStop.CancelAfter(TimeSpan.FromSeconds(60));
    var token = pairingStop.Token;
    var rendezvous = PairingCode.Derive(offer.Code);
    var beacon = new RendezvousBeacon(new(RelayEndpoint.Default, PairingCode.HostId(hostSecret!), identity!.PublicKey, Environment.MachineName, "win32"), offer.ExpiresAt, TimeProvider.System);
    tasks.Add(RunBeaconAsync(rendezvous, beacon, token));
    Changed?.Invoke(); return offer;
  }
  private static async Task RunBeaconAsync(RendezvousIdentity identity, RendezvousBeacon beacon, CancellationToken ct)
  {
    using (identity)
    using (var client = RelayHostClient.ForRendezvous(RelayEndpoint.Default, identity, beacon)) await client.RunAsync(ct);
  }
  public void Approve(string id)
  {
    // The owner explicitly approves the folders/accounts currently shown on this PC.
    var selected = Trust.Pending().Concat(Trust.List()).FirstOrDefault(d => d.Id == id) ?? throw new ProtocolException("Choose a paired device before approving it.");
    var rows = sessions();
    Grants.Set(new(id, true, [], rows.Select(s => s.Definition.Cwd).Distinct().ToArray(), rows.Select(s => s.Definition.AccountId).OfType<string>().Distinct().ToArray()));
    Trust.Approve(id, selected.Access);
  }
  public async ValueTask DisposeAsync()
  {
    stop.Cancel(); pairingStop?.Cancel();
    try { await Task.WhenAll(tasks); } catch (OperationCanceledException) { }
    relay?.Dispose(); (application as IDisposable)?.Dispose(); identity?.Dispose();
    if (hostSecret is not null) CryptographicOperations.ZeroMemory(hostSecret);
    stop.Dispose(); pairingStop?.Dispose();
  }
  private sealed class SessionView(Func<IReadOnlyList<SessionRecord>> read, PhoneSessionGrants grants) : IPhoneSessionView
  {
    public IReadOnlyList<JsonElement> Read(ApprovedDevice device) => read().Where(s => grants.Allows(device, s)).Select(s => JsonSerializer.SerializeToElement(new
    {
      id = s.Definition.Id, provider = s.Definition.Provider, cwd = s.Definition.Cwd, title = s.Definition.Title,
      status = s.State == SessionState.Running ? "waiting" : s.State == SessionState.Exited ? "exited" : "restoring", createdAt = s.CreatedAt
    })).ToArray();
  }
}
