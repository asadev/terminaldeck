using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Servers;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Servers;

public sealed class WindowsOpenSshRuntime : IServerRuntime
{
  private readonly string root;
  private readonly string credentialPrefix;
  private readonly ISecretStore secrets;
  private readonly IOpenSshProcess process;
  private readonly string ssh;
  private readonly string keyscan;
  private readonly string? askpass;
  public WindowsOpenSshRuntime(AppDataRoot data, ISecretStore secrets, string? askpassExecutable = null,
    IOpenSshProcess? process = null, string? openSshFolder = null)
  {
    root = Path.Combine(data.DirectoryPath, "servers"); this.secrets = secrets; this.process = process ?? new OpenSshProcess();
    credentialPrefix = Brand.Name + "/" + data.NamespaceId + "/servers/";
    var folder = openSshFolder ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH");
    ssh = Path.Combine(folder, "ssh.exe"); keyscan = Path.Combine(folder, "ssh-keyscan.exe"); askpass = askpassExecutable;
  }
  private string Folder(string id) { ServerValidation.Id(id); return Path.Combine(root, id); }
  public string KeyPath(string id) => Path.Combine(Folder(id), "identity");
  private async ValueTask PrepareAsync(string id, CancellationToken ct)
  {
    var folder = Folder(id); Directory.CreateDirectory(folder);
    if (OperatingSystem.IsWindows())
    {
      var sid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value ?? throw new IOException("Windows could not identify this user.");
      var result = await process.RunAsync(new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "icacls.exe"),
        [folder, "/inheritance:r", "/grant:r", "*" + sid + ":(OI)(CI)F"], new Dictionary<string, string>()), ct);
      if (result.ExitCode != 0) throw new IOException("Windows could not protect the server key folder.");
    }
    else File.SetUnixFileMode(folder, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    var config = Path.Combine(folder, "config");
    if (!File.Exists(config)) await File.WriteAllTextAsync(config, "# App-owned SSH configuration\n", ct);
  }
  public async ValueTask ImportKeyAsync(string serverId, string explicitlyPickedFile, CancellationToken ct)
  {
    if (!Path.IsPathFullyQualified(explicitlyPickedFile) || !File.Exists(explicitlyPickedFile) || new FileInfo(explicitlyPickedFile).Length is < 1 or > 65536)
      throw new ServerRefusal("Choose an SSH private key file up to 64 KB.");
    await PrepareAsync(serverId, ct);
    var bytes = await File.ReadAllBytesAsync(explicitlyPickedFile, ct);
    try
    {
      await using var file = new FileStream(KeyPath(serverId), FileMode.CreateNew, FileAccess.Write, FileShare.None);
      await file.WriteAsync(bytes, ct);
      if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(KeyPath(serverId), UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }
    finally { CryptographicOperations.ZeroMemory(bytes); }
  }
  public ValueTask RemoveKeyAsync(string serverId, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested(); var folder = Folder(serverId);
    foreach (var name in new[] { "identity", "known_hosts", "config" }) { var file = Path.Combine(folder, name); if (File.Exists(file)) File.Delete(file); }
    if (Directory.Exists(folder) && !Directory.EnumerateFileSystemEntries(folder).Any()) Directory.Delete(folder);
    return ValueTask.CompletedTask;
  }
  public static string HostKeyFingerprint(string key)
  {
    var parts = KeyParts(key); return "SHA256:" + Convert.ToBase64String(SHA256.HashData(Convert.FromBase64String(parts[1]))).TrimEnd('=');
  }
  private static string[] KeyParts(string key)
  {
    var parts = key.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
    if (parts.Length != 2 || parts[0] is not ("ssh-ed25519" or "ecdsa-sha2-nistp256" or "ssh-rsa") || key.Any(c => c is '\r' or '\n') || parts[1].Length > 2048)
      throw new ServerRefusal("Choose one SSH host public key from the scan.");
    byte[] bytes;
    try { bytes = Convert.FromBase64String(parts[1]); } catch (FormatException) { throw new ServerRefusal("The host public key is invalid."); }
    if (bytes.Length < 32) throw new ServerRefusal("The host public key is incomplete.");
    return parts;
  }
  public async ValueTask<string> ScanHostKeyAsync(SavedServer server, CancellationToken ct)
  {
    ServerValidation.Draft(new(server.Name, server.Host, server.Port, server.User, server.Authentication));
    var result = await process.RunAsync(new(keyscan, ["-T", "8", "-p", server.Port.ToString(System.Globalization.CultureInfo.InvariantCulture), "-t", "ed25519", "--", server.Host], new Dictionary<string, string>(), Limit: 16384), ct);
    if (result.ExitCode != 0) throw new IOException("The server did not return a host public key.");
    var line = result.Output.Split('\n').FirstOrDefault(l => !l.StartsWith('#') && l.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length == 3) ?? throw new IOException("The server did not return a host public key.");
    var parts = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries); var key = parts[1] + " " + parts[2]; _ = KeyParts(key); return key;
  }
  public async ValueTask TrustHostKeyAsync(SavedServer server, string key, CancellationToken ct)
  {
    var parts = KeyParts(key); await PrepareAsync(server.Id, ct);
    var host = server.Port == 22 ? server.Host : "[" + server.Host + "]:" + server.Port;
    var path = Path.Combine(Folder(server.Id), "known_hosts"); var temp = path + "." + Guid.NewGuid().ToString("N");
    try { await File.WriteAllTextAsync(temp, host + " " + string.Join(' ', parts) + "\n", ct); File.Move(temp, path, true); }
    finally { if (File.Exists(temp)) File.Delete(temp); }
  }
  public IReadOnlyList<string> Arguments(SavedServer server, string? command, bool terminal = false)
  {
    ServerValidation.Id(server.Id); ServerValidation.Draft(new(server.Name, server.Host, server.Port, server.User, server.Authentication));
    var folder = Folder(server.Id);
    var args = new List<string> { "-F", Path.Combine(folder, "config"), "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no", "-o", "CheckHostIP=no",
      "-o", "UserKnownHostsFile=" + ConfigPath(Path.Combine(folder, "known_hosts")), "-o", "GlobalKnownHostsFile=" + ConfigPath(Path.Combine(folder, "known_hosts")),
      "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
      "-o", "ConnectTimeout=10", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", "-o", "NumberOfPasswordPrompts=1",
      "-o", "PreferredAuthentications=" + (server.Authentication == ServerAuthentication.Password ? "password,keyboard-interactive" : "publickey"),
      "-i", server.Authentication == ServerAuthentication.Key ? KeyPath(server.Id) : "none",
      terminal ? "-tt" : "-T", "-p", server.Port.ToString(System.Globalization.CultureInfo.InvariantCulture), "-l", server.User, "--", server.Host };
    if (command is not null) args.Add(command); return args;
  }
  private static string ConfigPath(string path) => "\"" + path.Replace('\\', '/').Replace("%", "%%", StringComparison.Ordinal).Replace("\"", "", StringComparison.Ordinal) + "\"";
  public async ValueTask<ServerOutput> RunAsync(SavedServer server, ServerCommand command, CancellationToken ct)
  {
    await PrepareAsync(server.Id, ct);
    if (!File.Exists(Path.Combine(Folder(server.Id), "known_hosts"))) throw new ServerRefusal("Review and trust this server's host fingerprint before connecting.");
    var password = await secrets.ReadAsync(credentialPrefix + server.Id, ct);
    try
    {
      var env = new Dictionary<string, string>();
      if (password is not null)
      {
        if (askpass is null || !File.Exists(askpass)) throw new ServerRefusal("The password helper is missing. Connect it before using password sign-in.");
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct); lifetime.CancelAfter(TimeSpan.FromSeconds(45));
        var pipeName = "td-server-" + Guid.NewGuid().ToString("N");
        env["SSH_ASKPASS"] = askpass; env["SSH_ASKPASS_REQUIRE"] = "force"; env["DISPLAY"] = "terminaldeck:0"; env["TD_SERVER_ASKPASS_PIPE"] = pipeName;
        var serve = ServePasswordAsync(pipeName, password, lifetime.Token);
        try { return await process.RunAsync(new(ssh, Arguments(server, command.Script), env, command.Input, command.MaxOutputBytes), ct); }
        finally { lifetime.Cancel(); try { await serve; } catch (OperationCanceledException) { } }
      }
      env["SSH_ASKPASS_REQUIRE"] = "never";
      return await process.RunAsync(new(ssh, new[] { "-o", "BatchMode=yes" }.Concat(Arguments(server, command.Script)).ToArray(), env, command.Input, command.MaxOutputBytes), ct);
    }
    finally { if (password is not null) CryptographicOperations.ZeroMemory(password); }
  }
  private static async Task ServePasswordAsync(string name, byte[] password, CancellationToken ct)
  {
    for (var attempt = 0; attempt < 2; attempt++)
    {
      await using var pipe = new NamedPipeServerStream(name, PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
      await pipe.WaitForConnectionAsync(ct); await pipe.WriteAsync(password, ct); await pipe.FlushAsync(ct);
    }
  }
  public ValueTask<OpenSshTerminalLease> PrepareTerminalAsync(SavedServer server, CancellationToken ct) => PrepareTerminalAsync(server, null, ct);
  public async ValueTask<OpenSshTerminalLease> PrepareTerminalAsync(SavedServer server, ServerCodingTask? codingTask, CancellationToken ct)
  {
    codingTask?.Validate();
    if (codingTask is not null) ServerValidation.CanChange(server, ServerCaller.Person);
    var remoteCommand = codingTask?.RemoteCommand();
    if (codingTask is null && server.LandingFolder is { } landing)
    {
      ServerValidation.Path(landing);
      remoteCommand = "sh -c " + ServerValidation.Quote("cd -- " + ServerValidation.Quote(landing) + " || exit; exec \"${SHELL:-/bin/sh}\" -l");
    }
    await PrepareAsync(server.Id, ct);
    if (!File.Exists(Path.Combine(Folder(server.Id), "known_hosts"))) throw new ServerRefusal("Trust the server host fingerprint first.");
    var password = await secrets.ReadAsync(credentialPrefix + server.Id, ct);
    var env = new Dictionary<string, string> { ["SSH_ASKPASS_REQUIRE"] = "never" };
    if (password is null)
      return new(new(ssh, new[] { "-o", "BatchMode=yes" }.Concat(Arguments(server, remoteCommand, terminal: true)).ToArray(), env, Folder(server.Id)), Task.CompletedTask);
    if (askpass is null || !File.Exists(askpass)) { CryptographicOperations.ZeroMemory(password); throw new ServerRefusal("The password helper is missing."); }
    var lifetime = new CancellationTokenSource(TimeSpan.FromSeconds(45));
    var name = "td-server-" + Guid.NewGuid().ToString("N");
    env["SSH_ASKPASS"] = askpass; env["SSH_ASKPASS_REQUIRE"] = "force"; env["DISPLAY"] = "terminaldeck:0"; env["TD_SERVER_ASKPASS_PIPE"] = name;
    async Task ServeAsync()
    {
      try
      {
        await using var pipe = new NamedPipeServerStream(name, PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await pipe.WaitForConnectionAsync(lifetime.Token); await pipe.WriteAsync(password, lifetime.Token); await pipe.FlushAsync(lifetime.Token);
      }
      finally { CryptographicOperations.ZeroMemory(password); }
    }
    var serve = ServeAsync();
    return new(new(ssh, Arguments(server, remoteCommand, terminal: true), env, Folder(server.Id)), serve, lifetime);
  }
}
