using System.Diagnostics;
using TerminalDeck.Core.Servers;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;
using TerminalDeck.Platform.Windows.Servers;

namespace TerminalDeck.Servers.Windows.Tests;

public sealed class WindowsServerTests
{
  private static AppDataRoot Root()
  {
    var proof = Environment.GetEnvironmentVariable("TD_SERVERS_PROOF_ROOT") ?? throw new InvalidOperationException("Name a scratch C:\\TD\\out proof root.");
    if (!proof.StartsWith(@"C:\TD\out\", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Keep proof under C:\\TD\\out.");
    return AppDataRoot.Explicit(Path.Combine(proof, "windows-tests", Guid.NewGuid().ToString("N")));
  }
  [Fact] public void CodingTaskIsFixedSshRemoteArgumentAfterHostAndNeverPromptInput()
  {
    var root = Root(); var runtime = new WindowsOpenSshRuntime(root, new WindowsCredentialStore(root));
    var server = new SavedServer(Guid.NewGuid().ToString("N"), "Scratch", "example.test", 22, "tester", ServerAuthentication.Key, new(false, [], []));
    var task = new ServerCodingTask("codex", "signin"); var command = task.RemoteCommand();
    var args = runtime.Arguments(server, command, terminal: true);
    Assert.Contains("-tt", args); Assert.Equal(server.Host, args[^2]); Assert.Equal(command, args[^1]); Assert.Contains("login --device-auth", args[^1]);
    Assert.Contains("StrictHostKeyChecking=yes", args); Assert.Contains("ForwardAgent=no", args);
    Assert.Throws<ServerRefusal>(() => new ServerCodingTask("codex; whoami", "signin").RemoteCommand());
    Assert.Throws<ServerRefusal>(() => new ServerCodingTask("codex", "exec").RemoteCommand());
  }
  [Fact] public async Task CredentialManagerRoundTripAndNamespaceIsolation()
  {
    var root = Root(); var secrets = new WindowsCredentialStore(root); var store = new ServerStore(root, secrets); SavedServer? server = null;
    try
    {
      server = await store.AddAsync(new("Scratch credential proof", "example.test", 22, "tester", ServerAuthentication.Password), "synthetic-test-value"u8.ToArray(), default);
      Assert.True((await secrets.ReadAsync(store.PasswordName(server.Id)))!.AsSpan().SequenceEqual("synthetic-test-value"u8));
      var other = new ServerStore(AppDataRoot.Explicit(root.DirectoryPath + "-other"), secrets);
      await Assert.ThrowsAsync<ArgumentException>(async () => await secrets.ReadAsync(other.PasswordName(server.Id)));
    }
    finally { if (server is not null) await store.RemoveAsync(server.Id, default); if (Directory.Exists(root.DirectoryPath)) Directory.Delete(root.DirectoryPath, true); }
  }
  [Fact] public async Task BuiltInOpenSshClientIsAvailable()
  {
    var exe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh.exe"); Assert.True(File.Exists(exe));
    var result = await new OpenSshProcess().RunAsync(new(exe, ["-V"], new Dictionary<string, string>()), default); Assert.Equal(0, result.ExitCode);
  }
  [Fact] public async Task PasswordHelperRunsAsRealChildWithoutSecretArgumentsOrEnvironment()
  {
    var root = Root(); var secrets = new WindowsCredentialStore(root); var store = new ServerStore(root, secrets); SavedServer? server = null;
    var helper = Environment.GetEnvironmentVariable("TD_SERVERS_ASKPASS") ?? throw new InvalidOperationException("Build the askpass helper first.");
    var runner = new HelperRunner(helper);
    var runtime = new WindowsOpenSshRuntime(root, secrets, helper, runner);
    try
    {
      server = await store.AddAsync(new("Scratch password proof", "example.test", 22, "tester", ServerAuthentication.Password), "synthetic-test-value"u8.ToArray(), default);
      await runtime.TrustHostKeyAsync(server, "ssh-ed25519 " + Convert.ToBase64String(new byte[64]), default);
      Assert.Equal(0, (await runtime.RunAsync(server, new("true"), default)).ExitCode); Assert.True(runner.HelperSucceeded);
    }
    finally { if (server is not null) { await runtime.RemoveKeyAsync(server.Id, default); await store.RemoveAsync(server.Id, default); } if (Directory.Exists(root.DirectoryPath)) Directory.Delete(root.DirectoryPath, true); }
  }
  [Fact] public async Task KeyCopyIsProtectedAndOnlyOwnedCopyIsRemoved()
  {
    var root = Root(); Directory.CreateDirectory(root.DirectoryPath); var source = Path.Combine(root.DirectoryPath, "explicit-pick"); await File.WriteAllTextAsync(source, "synthetic-key-data");
    var runtime = new WindowsOpenSshRuntime(root, new WindowsCredentialStore(root)); var id = Guid.NewGuid().ToString("N");
    try
    {
      await runtime.ImportKeyAsync(id, source, default); Assert.Equal("synthetic-key-data", await File.ReadAllTextAsync(runtime.KeyPath(id)));
      var acl = FileSystemAclExtensions.GetAccessControl(new DirectoryInfo(Path.GetDirectoryName(runtime.KeyPath(id))!)); Assert.True(acl.AreAccessRulesProtected);
      await runtime.RemoveKeyAsync(id, default); Assert.True(File.Exists(source)); Assert.False(File.Exists(runtime.KeyPath(id)));
    }
    finally { if (Directory.Exists(root.DirectoryPath)) Directory.Delete(root.DirectoryPath, true); }
  }
  [Fact] public async Task ExpiredServerApprovalCannotWriteWindowsCredentialsOrImportChosenKey()
  {
    var root = Root(); Directory.CreateDirectory(root.DirectoryPath);
    var source = Path.Combine(root.DirectoryPath, "person-picked-key"); await File.WriteAllTextAsync(source, "synthetic-key-data");
    var secrets = new WindowsCredentialStore(root); var store = new ServerStore(root, secrets);
    var runtime = new WindowsOpenSshRuntime(root, secrets); var approval = new ExpiringApproval();
    var service = new ServerService(store, runtime, approval);
    var caller = new ServerCaller("hoot:fixture", ManageServers: true, EnsureCurrent: _ => approval.Expired
      ? ValueTask.FromException(new ServerRefusal("The caller expired while approval was open.")) : ValueTask.CompletedTask);
    try
    {
      await Assert.ThrowsAsync<ServerRefusal>(async () => await service.AddAsync(new("Scratch review proof", "example.test", 22, "tester", ServerAuthentication.Key), source, "synthetic-passphrase"u8.ToArray(), default, caller));
      Assert.Empty(store.List()); Assert.Equal("synthetic-key-data", await File.ReadAllTextAsync(source));
      Assert.False(Directory.Exists(Path.Combine(root.DirectoryPath, "servers")));
      Assert.Contains(source, approval.Action!.Target, StringComparison.Ordinal);
    }
    finally { if (Directory.Exists(root.DirectoryPath)) Directory.Delete(root.DirectoryPath, true); }
  }
  private sealed class ExpiringApproval : IServerAuthorizer
  {
    public bool Expired { get; private set; }
    public ServerAction? Action { get; private set; }
    public ValueTask<bool> ApproveAsync(ServerCaller caller, ServerAction action, CancellationToken ct)
    { Action = action; Expired = true; return ValueTask.FromResult(true); }
  }
  private sealed class HelperRunner(string helper) : IOpenSshProcess
  {
    public bool HelperSucceeded { get; private set; }
    public async ValueTask<ServerOutput> RunAsync(OpenSshInvocation request, CancellationToken ct)
    {
      if (!request.Executable.EndsWith("ssh.exe", StringComparison.OrdinalIgnoreCase)) return await new OpenSshProcess().RunAsync(request, ct);
      Assert.DoesNotContain(request.Arguments, s => s.Contains("synthetic-test-value", StringComparison.Ordinal));
      Assert.DoesNotContain(request.Environment.Values, s => s.Contains("synthetic-test-value", StringComparison.Ordinal));
      var start = new ProcessStartInfo(helper) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
      foreach (var pair in request.Environment) start.Environment[pair.Key] = pair.Value;
      using var child = Process.Start(start)!; var output = await child.StandardOutput.ReadToEndAsync(ct); var error = await child.StandardError.ReadToEndAsync(ct); await child.WaitForExitAsync(ct);
      HelperSucceeded = child.ExitCode == 0 && output == "synthetic-test-value\n" && error.Length == 0;
      Assert.True(HelperSucceeded); return new(0, "fixture connected");
    }
  }
}
