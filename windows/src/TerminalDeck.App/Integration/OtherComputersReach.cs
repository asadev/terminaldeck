using System.Text.Json;
using TerminalDeck.Core.Computers;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.App.Integration;

public sealed partial class OtherComputersService
{
  public Func<ReachGuest?>? AccountGuest { get; set; }
  public async Task RefreshAccountMachinesAsync(CancellationToken ct = default)
  {
    if (!CloudAllowed || AccountGuest?.Invoke() is not { } guest) return;
    foreach (var machine in await guest.ReachableAsync(ct: ct))
    {
      var id = ReachGuest.LinkId(machine.DeviceId);
      if (List().All(c => c.Id != id)) Set(new(id, machine.ShownName, machine.Platform, "Disconnected", null, [], []));
    }
  }
  private async Task ConnectReachAsync(string id, CancellationToken ct)
  {
    RequireCloudAccess();
    var guest = AccountGuest?.Invoke() ?? throw new InvalidOperationException("Sign in to your account to reach this computer.");
    var machine = (await guest.ReachableAsync(ct: ct)).SingleOrDefault(m => ReachGuest.LinkId(m.DeviceId) == id)
      ?? throw new InvalidOperationException("That computer is not reachable yet. Its saved conversation is still available.");
    await mutations.WaitAsync(ct);
    try
    {
      RequireCloudAccess();
      if (links.ContainsKey(id)) return;
      var secrets = await guest.SecretsAsync(machine, ct);
      var channel = new ComputerChannel { LinkEngine = LinkEngine, RelayBearer = await guest.RelayTokenAsync(ct) };
      var stopped = new CancellationTokenSource(); wanted.TryAdd(id, 0);
      Set(new(id, machine.ShownName, machine.Platform, "Connecting", null, [], []));
      try
      {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct, stopped.Token); deadline.CancelAfter(TimeSpan.FromSeconds(15));
        await channel.OpenAsync(new MachineOffer(secrets.Relay, secrets.HostId, secrets.HostPublicKey, machine.ShownName, machine.Platform), secrets.GuestKey, deadline.Token);
        await channel.SendAsync(new { t = "hello", protocol = 1, token = secrets.Credential, device = new { name = Environment.MachineName, platform = "win32" }, capabilities = channel.LinkCapabilities }, deadline.Token);
        var answer = await channel.ReceiveAsync(deadline.Token);
        if (Text(answer, "t", "") != "welcome") throw new ProtocolException(Text(answer, "message", "That computer could not open this session."));
        var caps = answer.TryGetProperty("capabilities", out var offered) && offered.ValueKind == JsonValueKind.Array ? offered.EnumerateArray().Select(c => c.GetString() ?? "").ToArray() : [];
        if (!ReferenceEquals(guest, AccountGuest?.Invoke())) throw new InvalidOperationException("The signed-in account changed while connecting.");
        RequireCloudAccess();
        links[id] = (channel, stopped); AcceptSnapshot(id, answer);
        Set(new(id, machine.ShownName, machine.Platform, "Online", null, caps, [])); Frame?.Invoke(id, answer);
        _ = ReadAsync(id, channel, stopped); _ = RestoreWatchesAsync(id, stopped.Token);
      }
      catch
      {
        await channel.DisposeAsync(); stopped.Dispose(); wanted.TryRemove(id, out _);
        Set(new(id, machine.ShownName, machine.Platform, "Disconnected", "The live connection could not open. The saved conversation is kept.", [], [])); throw;
      }
    }
    finally { mutations.Release(); }
  }
  public async Task<string?> OpenCloudSessionAsync(string sessionId, string machineName, CancellationToken ct = default)
  {
    RequireCloudAccess();
    var existing = List().FirstOrDefault(c => c.State == "Online" && Services(c.Id).Sessions.Any(s => Text(s, "id", "") == sessionId));
    if (existing is not null) return existing.Id;
    await RefreshAccountMachinesAsync(ct);
    var guest = AccountGuest?.Invoke(); if (guest is null) return null;
    var machines = await guest.ReachableAsync(ct: ct);
    var candidates = machines.Where(m => ReachMachine.Bare(m.ShownName).Equals(ReachMachine.Bare(machineName), StringComparison.OrdinalIgnoreCase) || ReachMachine.Bare(m.Name).Equals(ReachMachine.Bare(machineName), StringComparison.OrdinalIgnoreCase)).ToArray();
    foreach (var machine in candidates)
    {
      var id = ReachGuest.LinkId(machine.DeviceId);
      try
      {
        await ConnectAsync(id, ct);
        if (Services(id).Sessions.Any(s => Text(s, "id", "") == sessionId)) return id;
      }
      catch (Exception ex) when (ex is not OutOfMemoryException && !ct.IsCancellationRequested && candidates.Length > 1) { }
    }
    return null;
  }
  public async Task DisconnectAccountMachinesAsync()
  {
    foreach (var computer in List().Where(c => ReachGuest.IsReachLink(c.Id))) await DisconnectAsync(computer.Id);
    lock (views) foreach (var id in views.Keys.Where(ReachGuest.IsReachLink).ToArray()) views.Remove(id);
  }
}
