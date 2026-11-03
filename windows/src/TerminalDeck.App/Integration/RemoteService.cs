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

public sealed partial class RemoteService : IAsyncDisposable
{
  private readonly AppDataRoot dataRoot;
  private PhoneTransportHub? transportHub;
  private LocalWebHost? localWeb;
  public int? LocalWebPort => localWeb?.Port;
  public string? LocalWebAddress => localWeb?.Address;
  private readonly WindowsCredentialStore secrets;
  private readonly string secretPrefix;
  private readonly Func<IReadOnlyList<SessionRecord>> sessions;
  private readonly CancellationTokenSource stop = new();
  private readonly List<Task> tasks = [];
  public Func<IRelayPhoneApplication, IPhoneSessionView, IRelayPhoneApplication>? WrapApplication { get; set; }
  // The version phones show for this computer (the installed package's).
  public string AppVersion { get; set; } = "windows";
  private IRelayPhoneApplication? application;
  private NoiseIdentity? identity;
  private RelayHostClient? relay;
  private CancellationTokenSource? relayRun;
  private CancellationTokenSource? pairingStop;
  public IRelayReceiverApplication? ReceiverApplication { get; set; }
  public IRelayMcpApplication? McpBridge { get; set; }
  // stream step 2 (dc2): the WebRTC stack for the direct link; null = every link fails with the reason (direct only).
  public ILinkEngine? LinkEngine { get; set; }
  /// A connection moved onto its link (video sends a keyframe first there).
  public event Action<string>? LinkMoved;
  public bool OnLink(string channel) => relay?.OnLink(channel) == true;
  public bool AwaitsLink(string channel) => relay?.AwaitsLink(channel) == true;
  public bool HasLink(string channel) => relay?.HasLink(channel) == true;
  public bool? SendDirect(string channel, byte[] message, LinkLane lane) => relay?.SendDirect(channel, message, lane);
  public LinkVideo? LinkVideo(string channel) => relay?.LinkVideo(channel);
  private void OnTrustChangedForLinks() => _ = Task.Run(RefreshLinkDevices);
  private void RefreshLinkDevices()
  {
    if (relay is not { } current) return;
    var (eligible, known) = LinkEligibility.Devices(Trust);
    current.RefreshLinkDevices(eligible, known);
  }
  public string? McpAddress => hostSecret is null ? null : "https://relay.terminaldeck.dev/mcp/" + PairingCode.HostId(hostSecret);
  public DeviceTrust Trust { get; }
  public PhoneSessionGrants Grants { get; }
  public RelayConnectionState State { get; private set; } = RelayConnectionState.Stopped;
  public event Action? Changed;
  public RemoteService(AppDataRoot root, Func<IReadOnlyList<SessionRecord>> readSessions)
  {
    dataRoot = root; secrets = new(root); secretPrefix = $"{Brand.Name}/{root.NamespaceId}/"; sessions = readSessions;
    Trust = new(new DeviceStore(root));
    Grants = new(new JsonStateStore<SessionGrantState>(root, "phone-grants"));
    Trust.Changed += () => Changed?.Invoke();
  }
  private byte[]? hostSecret;
  private bool phonesEnabled;
  public Func<bool>? ReceiverTransportRequired { get; set; }
  private async Task StartHostCoreAsync(bool enablePhones = true)
  {
    stop.Token.ThrowIfCancellationRequested();
    if (relay is not null) return;
    SetHostSecret(await SecretAsync("remote-host"));
    var key = await SecretAsync("remote-identity");
    try { identity = new(key); } finally { CryptographicOperations.ZeroMemory(key); }
    phonesEnabled = enablePhones;
    var view = new SessionView(sessions, Grants);
    if (enablePhones)
    {
      application = new PhoneLink(Trust, Environment.MachineName, AppVersion, view);
      application = WrapApplication?.Invoke(application, view) ?? application;
      application = new WebLaunchApplication(application, Trust, webLaunch, id => WebEnrolled?.Invoke(id));
    }
    else application = new ReceiverOnlyPhoneApplication();
    transportHub = new(application);
    var webRoot = Path.Combine(AppContext.BaseDirectory, "web");
    if (enablePhones && LocalWebHost.CompatibleBundle(webRoot))
    {
      var preferredPort = 8444;
      try { using var previous = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(dataRoot.DirectoryPath, "remote-local.json"))); if (Uri.TryCreate(previous.RootElement.GetProperty("address").GetString(), UriKind.Absolute, out var address) && address.IsLoopback) preferredPort = address.Port; }
      catch (Exception ex) when (ex is IOException or JsonException or KeyNotFoundException) { }
      localWeb = new(webRoot, Trust, transportHub, id => WebEnrolled?.Invoke(id), preferredPort: preferredPort); localWeb.Start();
      File.WriteAllText(Path.Combine(dataRoot.DirectoryPath, "remote-local.json"), JsonSerializer.Serialize(new { address = localWeb.Address, protocol = 1 }));
    }
    relay = new(RelayEndpoint.Default, hostSecret, identity, transportHub, mcp: enablePhones ? McpBridge : null, receiver: ReceiverApplication,
      linkEngine: enablePhones ? LinkEngine : null, linkEligible: enablePhones ? LinkEligibility.For(Trust) : null);
    // Security M2: which devices may hold a TURN login comes from the trust store, now and on every change.
    RefreshLinkDevices();
    Trust.Changed += OnTrustChangedForLinks;
    relay.StateChanged += state => { State = enablePhones ? state : RelayConnectionState.Stopped; Changed?.Invoke(); };
    relay.LinkMoved += channel => LinkMoved?.Invoke(channel);
    relayRun = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
    tasks.Add(relay.RunAsync(relayRun.Token));
  }
  private async Task<byte[]> SecretAsync(string name)
  {
    name = secretPrefix + name;
    var value = await secrets.ReadAsync(name);
    if (value is { Length: 32 }) return value;
    if (value is not null) CryptographicOperations.ZeroMemory(value);
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
  // Approving a phone (and the sessions it sees) is AppRuntime.ApprovePhone / SetPhoneWorkspace: one writer.
  public async ValueTask DisposeAsync()
  {
    if (Interlocked.Exchange(ref hostDisposed, 1) != 0) return;
    stop.Cancel();
    await lifecycleGate.WaitAsync();
    try { await EndHostEpochAsync(CancellationToken.None); }
    finally { lifecycleGate.Release(); stop.Dispose(); }
  }
  private sealed class SessionView(Func<IReadOnlyList<SessionRecord>> read, PhoneSessionGrants grants) : IPhoneSessionView
  {
    public IReadOnlyList<JsonElement> Read(ApprovedDevice device) => read().Where(s => grants.Allows(device, s)).Select(s => JsonSerializer.SerializeToElement(new
    {
      id = s.Definition.Id, provider = s.Definition.Provider, cwd = s.Definition.Cwd, title = s.Definition.Title,
      status = PhoneSessionRows.TerminalStatus(s, working: false), createdAt = s.CreatedAt
    })).ToArray();
  }
}
