using System.Text;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Servers;
using TerminalDeck.Platform.Windows.Servers;

namespace TerminalDeck.Servers.Tests;

// Server keys travel (the Mac's chooseSSHSettings cases): a server from his SSH settings with no key of its own on this
// PC connects with the copy from his other device (its host, user, port, key file and known-host lines); his own key
// always wins; a password server never uses a copy. Scratch folders only; no connection is made.
[Collection("CloudSshTravelledBox")]
public sealed class CloudKeysSshDialTests
{
  [Fact] public async Task A_server_without_its_own_key_dials_with_the_travelled_copy_and_his_own_key_wins()
  {
    using var f = new Fixture();
    const string id = "5f0e6a2c9b1d4c3e8f7a1b2c3d4e5f60";
    await f.Store.CloudAddSshIfAbsentAsync(id, new CloudSecretsServerDefinition("Work box", "work-box", 22, "deploy", null, true, null, null), "work-box");
    var row = f.Store.Get(id);
    var folder = new CloudKeysSshFolder(Path.Combine(f.Path, "travelled"));
    folder.Put(id, new(new("Work box", "work-box", 22, "deploy", null, true, null, null), "work-box", "192.0.2.10", "deploy", 2222,
      [("id_ed25519", Encoding.ASCII.GetBytes("MADE-UP-KEY"))], [("ssh-ed25519", Encoding.ASCII.GetBytes("made-up host key"))]));
    var runtime = new WindowsOpenSshRuntime(f.Root, f.Secrets, process: new NoProcess());
    CloudSshTravelledBox.Shared.Set(folder);
    try
    {
      var args = runtime.Arguments(row, "true");
      var copy = folder.Travelled(id)!;
      Assert.Equal(new[] { "-p", "2222", "-l", "deploy", "--", "192.0.2.10", "true" }, args.TakeLast(7));
      Assert.Contains(copy.IdentityFiles[0], args);
      Assert.Contains(args, a => a.StartsWith("GlobalKnownHostsFile=", StringComparison.Ordinal) && a.Contains("travelled", StringComparison.Ordinal));
      Assert.DoesNotContain(runtime.KeyPath(id), args);
      // His own key here: always his.
      Directory.CreateDirectory(Path.GetDirectoryName(runtime.KeyPath(id))!);
      File.WriteAllText(runtime.KeyPath(id), "his own made-up key");
      var own = runtime.Arguments(row, "true");
      Assert.Contains(runtime.KeyPath(id), own);
      Assert.Equal(new[] { "-p", "22", "-l", "deploy", "--", "work-box", "true" }, own.TakeLast(7));
      // A password server never takes a copy.
      var password = await f.AddAsync();
      Assert.Null(runtime.Travelled(password));
    }
    finally { CloudSshTravelledBox.Shared.Set(null); }
  }
  private sealed class NoProcess : IOpenSshProcess
  {
    public ValueTask<ServerOutput> RunAsync(OpenSshInvocation invocation, CancellationToken ct) => ValueTask.FromResult(new ServerOutput(0, ""));
  }
}
