using System.Text.Json;
using TerminalDeck.Core.Servers;
using TerminalDeck.Platform.Windows.Servers;

namespace TerminalDeck.Servers.Tests;

public sealed class ServerSigninTests
{
  private const string Address = "https://claude.ai/oauth/authorize?state=private-state&redirect_uri=http%3A%2F%2Flocalhost%3A45678%2Fcallback";
  private sealed class Forward : IServerSigninForward
  {
    public bool IsAlive { get; set; } = true; public int Closed;
    public ValueTask DisposeAsync() { Closed++; IsAlive = false; return ValueTask.CompletedTask; }
  }
  private sealed class Transport : IServerSigninTransport
  {
    public ServerSigninCapture Capture = new(Address, false, -1); public Forward Lease = new();
    public List<string> Order = []; public int Busy; public int Attempts; public int Stops; public int Cleanups;
    public bool Running = true; public bool BrowserOpened;
    public ValueTask<ServerSigninCapture> CaptureAsync(ServerSigninRequest request, CancellationToken ct) => ValueTask.FromResult(Capture);
    public ValueTask<IServerSigninForward> ForwardAsync(ServerSigninRequest request, int port, CancellationToken ct)
    { Attempts++; if (Busy-- > 0) throw new ServerSigninPortBusy(); Order.Add("forward-ready"); return ValueTask.FromResult<IServerSigninForward>(Lease); }
    public ValueTask OpenBrowserAsync(Uri address, CancellationToken ct) { Order.Add("browser"); BrowserOpened = true; return ValueTask.CompletedTask; }
    public bool SessionRunning(ServerSigninRequest request) => Running;
    public ValueTask StopOwnSessionAsync(ServerSigninRequest request, CancellationToken ct) { Stops++; return ValueTask.CompletedTask; }
    public ValueTask CleanupAsync(ServerSigninRequest request, CancellationToken ct) { Cleanups++; return ValueTask.CompletedTask; }
  }
  private static SavedServer Server() => new SavedServer(Guid.NewGuid().ToString("N"), "Synthetic", "example.test", 22, "tester", ServerAuthentication.Key, new(false, [], [])) { DrivesBrowser = true };
  private static ServerSigninRequest Request(SavedServer server) => new(server, new("claude", "signin") { AttemptId = Guid.NewGuid().ToString("N") }, "own-session", ServerCaller.Person);
  private static async Task Wait(ServerSigninAttempts owner, string id, string phase)
  {
    var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    void Changed(ServerSigninState state) { if (state.ServerId == id && state.Phase == phase) done.TrySetResult(); }
    owner.Changed += Changed;
    try { if (owner.State(id)?.Phase == phase) return; await done.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
    finally { owner.Changed -= Changed; }
  }
  [Fact] public async Task AutomaticBrowserOpensOnlyAfterReadyAndCompletionClosesOwnedTunnel()
  {
    var server = Server(); var transport = new Transport(); await using var owner = new ServerSigninAttempts((_, _) => server, transport);
    owner.Start(Request(server)); await Wait(owner, server.Id, "browser");
    Assert.Equal(new[] { "forward-ready", "browser" }, transport.Order);
    Assert.DoesNotContain("private-state", JsonSerializer.Serialize(owner.State(server.Id)), StringComparison.Ordinal);
    transport.Capture = new(null, true, 0); await Wait(owner, server.Id, "done"); await owner.DisposeAsync();
    Assert.Equal(1, transport.Lease.Closed); Assert.Equal(0, transport.Stops); Assert.Equal(1, transport.Cleanups);
  }
  [Fact] public async Task PortBusyRetriesThenFallsBackWithoutOpeningBrowser()
  {
    var server = Server(); var transport = new Transport { Busy = 4 }; await using var owner = new ServerSigninAttempts((_, _) => server, transport);
    owner.Start(Request(server)); await Wait(owner, server.Id, "manual"); Assert.Equal(3, transport.Attempts); Assert.False(transport.BrowserOpened);
    await owner.DisposeAsync(); Assert.Equal(1, transport.Stops);
  }
  [Fact] public async Task TemporarilyBusyPortCanRecoverBeforeAnyBrowserNavigation()
  {
    var server = Server(); var transport = new Transport { Busy = 1 }; await using var owner = new ServerSigninAttempts((_, _) => server, transport);
    owner.Start(Request(server)); await Wait(owner, server.Id, "browser"); Assert.Equal(2, transport.Attempts); Assert.Equal(new[] { "forward-ready", "browser" }, transport.Order);
  }
  [Fact] public async Task RevokedAccessStopsOnlyOwnSessionAndClosesCallbackCapability()
  {
    var server = Server(); var current = server; var transport = new Transport(); await using var owner = new ServerSigninAttempts((_, _) => current, transport);
    owner.Start(Request(server)); await Wait(owner, server.Id, "browser"); current = server with { Access = server.Access with { LookOnly = true } };
    await Wait(owner, server.Id, "cancelled"); await owner.DisposeAsync(); Assert.Equal(1, transport.Stops); Assert.Equal(1, transport.Lease.Closed);
  }
  [Fact] public async Task DisabledBrowserAndBadRedirectNeverProvisionForwarding()
  {
    var server = Server() with { DrivesBrowser = false }; var transport = new Transport(); await using var owner = new ServerSigninAttempts((_, _) => server, transport);
    owner.Start(Request(server)); await Wait(owner, server.Id, "manual"); Assert.Equal(0, transport.Attempts); Assert.False(transport.BrowserOpened);
    var other = Server(); var invalid = new Transport { Capture = new("https://evil.test/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A45678%2Fcallback", false, -1) };
    await using var rejected = new ServerSigninAttempts((_, _) => other, invalid); rejected.Start(Request(other)); await Wait(rejected, other.Id, "manual"); Assert.Equal(0, invalid.Attempts); Assert.False(invalid.BrowserOpened);
  }
  private sealed class Clock : TimeProvider
  {
    private long offset;
    public override DateTimeOffset GetUtcNow() => DateTimeOffset.UnixEpoch.AddTicks(Interlocked.Read(ref offset));
    public void Expire() => Interlocked.Exchange(ref offset, TimeSpan.FromMinutes(17).Ticks);
  }
  [Fact] public async Task SessionEndAndTimeoutReleaseOnlyTheirOwnedAttempt()
  {
    var server = Server(); var transport = new Transport(); var clock = new Clock();
    await using var owner = new ServerSigninAttempts((_, _) => server, transport, clock);
    owner.Start(Request(server)); await Wait(owner, server.Id, "browser"); clock.Expire(); await Wait(owner, server.Id, "expired"); await owner.DisposeAsync();
    Assert.Equal(1, transport.Stops); Assert.Equal(1, transport.Lease.Closed);
    var other = Server(); var ended = new Transport(); await using var second = new ServerSigninAttempts((_, _) => other, ended);
    second.Start(Request(other)); await Wait(second, other.Id, "browser"); ended.Running = false; second.RefreshSessions();
    await Wait(second, other.Id, "cancelled"); await second.DisposeAsync(); Assert.Equal(1, ended.Stops); Assert.Equal(1, ended.Lease.Closed);
  }
  [Fact] public async Task BrowserPermissionRetirementImmediatelyCancelsItsForward()
  {
    var server = Server(); var transport = new Transport(); await using var owner = new ServerSigninAttempts((_, _) => server, transport);
    owner.Start(Request(server)); await Wait(owner, server.Id, "browser"); owner.ServerChanged(server with { DrivesBrowser = false });
    await Wait(owner, server.Id, "cancelled"); await owner.DisposeAsync(); Assert.Equal(1, transport.Lease.Closed); Assert.Equal(1, transport.Stops);
  }
  [Theory]
  [InlineData("https://evil.test/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A45678%2Fcallback")]
  [InlineData("https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Fremote.test%3A45678%2Fcallback")]
  [InlineData("https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A80%2Fcallback")]
  [InlineData("https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A45678%2Fcallback&redirect_uri=http%3A%2F%2Flocalhost%3A45679%2Fcallback")]
  public void OnlyKnownHttpsOAuthAndOneExactLoopbackCallbackAreAccepted(string invalid) => Assert.Throws<ServerRefusal>(() => ServerSigninAddress.Validate(invalid));
  [Fact] public void FixedCaptureNamespaceAndPinnedForwardArgumentsCannotBecomeCommandDoor()
  {
    Assert.Equal(45678, ServerSigninAddress.Validate(Address).Port);
    Assert.Throws<ServerRefusal>(() => ServerSigninScripts.Capture("../../arbitrary"));
    var args = WindowsServerSigninTransport.ForwardArguments(["-o", "StrictHostKeyChecking=yes", "-o", "ClearAllForwardings=yes", "-T", "--", "example.test"], 45678);
    Assert.Contains("-N", args); Assert.Contains("ExitOnForwardFailure=yes", args); Assert.Contains("127.0.0.1:45678:127.0.0.1:45678", args); Assert.Contains("StrictHostKeyChecking=yes", args); Assert.DoesNotContain("ClearAllForwardings=yes", args); Assert.Equal("example.test", args[^1]);
    Assert.DoesNotContain("private-state", string.Join(' ', args), StringComparison.Ordinal);
  }
}
