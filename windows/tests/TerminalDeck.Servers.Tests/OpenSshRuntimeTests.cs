using System.IO.Pipes;
using System.Text;
using TerminalDeck.Core.Servers;
using TerminalDeck.Platform.Windows.Servers;

namespace TerminalDeck.Servers.Tests;

public sealed class OpenSshRuntimeTests
{
  private sealed class Runner : IOpenSshProcess
  {
    public List<OpenSshInvocation> Calls { get; } = [];
    public Func<OpenSshInvocation, CancellationToken, ValueTask<ServerOutput>> Reply { get; set; } = (_, _) => ValueTask.FromResult(new ServerOutput(0, "connected"));
    public ValueTask<ServerOutput> RunAsync(OpenSshInvocation invocation, CancellationToken ct) { Calls.Add(invocation); return Reply(invocation, ct); }
    // On Windows the key folder is first locked to this user with icacls.exe; that is not a connection.
    public IEnumerable<OpenSshInvocation> Connections => Calls.Where(c => !Path.GetFileName(c.Executable).Equals("icacls.exe", StringComparison.OrdinalIgnoreCase));
  }
  [Fact] public async Task KeyImportOnlyReadsExplicitPickAndLeavesOriginalAlone()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); var chosen = f.Path + "/chosen-key"; File.WriteAllText(chosen, "fixture-key");
    var run = new Runner(); var runtime = new WindowsOpenSshRuntime(f.Root, f.Secrets, process: run);
    await runtime.ImportKeyAsync(row.Id, chosen, default); Assert.Equal("fixture-key", File.ReadAllText(runtime.KeyPath(row.Id)));
    await runtime.RemoveKeyAsync(row.Id, default); Assert.True(File.Exists(chosen)); Assert.False(File.Exists(runtime.KeyPath(row.Id)));
  }
  [Fact] public async Task NoConnectionBeforeHostKeyTrustAndNoUserSshDefaults()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); var run = new Runner(); var runtime = new WindowsOpenSshRuntime(f.Root, f.Secrets, process: run);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await runtime.RunAsync(row, new("true"), default)); Assert.Empty(run.Connections);
    var args = runtime.Arguments(row, "true");
    Assert.Contains("StrictHostKeyChecking=yes", args); Assert.Contains("IdentityAgent=none", args); Assert.Contains("IdentitiesOnly=yes", args);
    Assert.Contains("ForwardAgent=no", args); Assert.Contains("ClearAllForwardings=yes", args);
    Assert.Contains(Path.Combine(f.Path, "servers", row.Id, "config"), args);
    Assert.Contains("none", args); Assert.DoesNotContain(args, a => a.Contains(".ssh", StringComparison.Ordinal));
  }
  [Fact] public async Task HostTrustWritesOnlyOnePinnedPublicKey()
  {
    using var f = new Fixture(); var row = await f.AddAsync(); var runtime = new WindowsOpenSshRuntime(f.Root, f.Secrets, process: new Runner());
    var key = "ssh-ed25519 " + Convert.ToBase64String(new byte[64]);
    await runtime.TrustHostKeyAsync(row, key, default);
    Assert.StartsWith("SHA256:", WindowsOpenSshRuntime.HostKeyFingerprint(key));
    Assert.Equal(row.Host + " " + key + "\n", File.ReadAllText(Path.Combine(f.Path, "servers", row.Id, "known_hosts")));
    await Assert.ThrowsAsync<ServerRefusal>(async () => await runtime.TrustHostKeyAsync(row, key + "\nHost *", default));
  }
  [Fact] public async Task PasswordTravelsOnlyThroughPrivatePipeAndIsZeroedAfterRequest()
  {
    using var f = new Fixture(); var row = await f.AddAsync(); var helper = f.Path + "/askpass"; File.WriteAllText(helper, "fixture"); var run = new Runner();
    run.Reply = async (request, ct) =>
    {
      if (!request.Environment.TryGetValue("TD_SERVER_ASKPASS_PIPE", out var pipeName)) return new(0, "");
      Assert.DoesNotContain(request.Arguments, a => a.Contains("fixture-password", StringComparison.Ordinal));
      Assert.DoesNotContain(request.Environment.Values, a => a.Contains("fixture-password", StringComparison.Ordinal));
      await using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.In, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
      await pipe.ConnectAsync(ct); using var text = new StreamReader(pipe); var value = await text.ReadToEndAsync(ct);
      Assert.Equal("fixture-password", value); return new(0, "connected");
    };
    var runtime = new WindowsOpenSshRuntime(f.Root, f.Secrets, helper, run); await runtime.TrustHostKeyAsync(row, "ssh-ed25519 " + Convert.ToBase64String(new byte[64]), default);
    var result = await runtime.RunAsync(row, new("true"), default); Assert.Equal(0, result.ExitCode);
    Assert.Equal("fixture-password", Encoding.UTF8.GetString(f.Secrets.Values[f.Store.PasswordName(row.Id)]));
  }
  [Fact] public async Task MissingPasswordHelperRefusesWithoutLaunchingSsh()
  {
    using var f = new Fixture(); var row = await f.AddAsync(); var run = new Runner(); var runtime = new WindowsOpenSshRuntime(f.Root, f.Secrets, process: run);
    await runtime.TrustHostKeyAsync(row, "ssh-ed25519 " + Convert.ToBase64String(new byte[64]), default);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await runtime.RunAsync(row, new("true"), default)); Assert.Empty(run.Connections);
  }
  [Fact] public async Task PasswordTerminalUsesSessionOwnerAndFreshOneUsePipe()
  {
    using var f = new Fixture(); var row = await f.AddAsync(); var helper = f.Path + "/askpass"; File.WriteAllText(helper, "fixture");
    var runtime = new WindowsOpenSshRuntime(f.Root, f.Secrets, helper, new Runner());
    await runtime.TrustHostKeyAsync(row, "ssh-ed25519 " + Convert.ToBase64String(new byte[64]), default);
    var launches = 0;
    await using var terminal = new WindowsServerTerminal(runtime, async (server, launch, ct) =>
    {
      launches++; Assert.Equal(row.Id, server.Id); Assert.Contains("-tt", launch.Arguments);
      Assert.DoesNotContain(launch.Environment.Values, s => s.Contains("fixture-password", StringComparison.Ordinal));
      await using var pipe = new NamedPipeClientStream(".", launch.Environment["TD_SERVER_ASKPASS_PIPE"], PipeDirection.In, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
      await pipe.ConnectAsync(ct); using var text = new StreamReader(pipe); Assert.Equal("fixture-password", await text.ReadToEndAsync(ct));
      return "owned-session";
    });
    Assert.Equal("owned-session", await terminal.OpenAsync(new(row), default)); Assert.Equal(1, launches);
  }
  [Fact] public async Task ProcessOutputLimitsAndCancellationEndOnlyOwnedProcess()
  {
    var runner = new OpenSshProcess();
    // The same two children on each system: endless output, and a ten-second wait.
    var cmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");
    var endless = OperatingSystem.IsWindows() ? new OpenSshInvocation(cmd, ["/d", "/c", "for /l %i in (0,0,1) do @echo sample"], new Dictionary<string, string>(), Limit: 32) : new("/bin/sh", ["-c", "yes sample"], new Dictionary<string, string>(), Limit: 32);
    var slow = OperatingSystem.IsWindows() ? new OpenSshInvocation(cmd, ["/d", "/c", Path.Combine(Environment.SystemDirectory, "PING.EXE") + " -n 11 127.0.0.1"], new Dictionary<string, string>()) : new("/bin/sh", ["-c", "sleep 10"], new Dictionary<string, string>());
    await Assert.ThrowsAnyAsync<Exception>(async () => await runner.RunAsync(endless, default));
    using var cancelled = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));
    await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await runner.RunAsync(slow, cancelled.Token));
  }
}
