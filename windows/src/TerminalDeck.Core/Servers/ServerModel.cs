using System.Collections.Immutable;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Core.Servers;

public enum ServerAuthentication { Key, Password }
public sealed record ServerAccess(bool LookOnly, ImmutableArray<string> Folders, ImmutableArray<string> AiApps)
{
  public static ServerAccess Default { get; } = new(true, [], []);
}
public sealed record SavedServer(string Id, string Name, string Host, int Port, string User,
  ServerAuthentication Authentication, ServerAccess Access, string? ProjectId = null);
public sealed record ServerDraft(string Name, string Host, int Port, string User, ServerAuthentication Authentication, string? ProjectId = null);
public sealed record ServerCaller(string Id, bool Owner = false, bool LocalSession = false, bool PairedDevice = false, bool ManageServers = false, Func<CancellationToken, ValueTask>? EnsureCurrent = null)
{
  public static ServerCaller Person { get; } = new("person", Owner: true);
  public ValueTask RecheckAsync(CancellationToken ct) { ct.ThrowIfCancellationRequested(); return EnsureCurrent?.Invoke(ct) ?? ValueTask.CompletedTask; }
}
public sealed record ServerAction(string ServerId, string Name, string Operation, string Target, bool Destructive = false);
public interface IServerAuthorizer
{
  ValueTask<bool> ApproveAsync(ServerCaller caller, ServerAction action, CancellationToken ct);
}
public sealed class DenyServerChanges : IServerAuthorizer
{
  public ValueTask<bool> ApproveAsync(ServerCaller caller, ServerAction action, CancellationToken ct) => ValueTask.FromResult(false);
}
public sealed class ServerRefusal(string message) : InvalidOperationException(message);
public sealed record ServerCommand(string Script, string? Input = null, int MaxOutputBytes = 262144);
public sealed record ServerOutput(int ExitCode, string Output);
public sealed record ServerFile(string Name, string Path, string Kind, long Size, double Modified);
public sealed record ServerFilePage(string Path, ServerFile[] Entries, bool More, int Offset = 0);
public sealed record ServerFileContent(string Path, string Base64, bool Truncated);
public sealed record ServerApp(string Id, string Name, string Image, string State, string Status, string Ports);
public sealed record ServerTerminalRequest(SavedServer Server);
public interface IServerTerminal
{
  ValueTask<string> OpenAsync(ServerTerminalRequest request, CancellationToken ct);
}
public interface IServerRuntime
{
  ValueTask<ServerOutput> RunAsync(SavedServer server, ServerCommand command, CancellationToken ct);
  ValueTask ImportKeyAsync(string serverId, string explicitlyPickedFile, CancellationToken ct);
  ValueTask RemoveKeyAsync(string serverId, CancellationToken ct);
  ValueTask<string> ScanHostKeyAsync(SavedServer server, CancellationToken ct);
  ValueTask TrustHostKeyAsync(SavedServer server, string key, CancellationToken ct);
}
public interface IServerKeyPicker
{
  ValueTask<string?> PickAsync(CancellationToken ct);
}
public interface IServers
{
  IReadOnlyList<SavedServer> List(ServerCaller caller);
  SavedServer Get(string id, ServerCaller caller);
  ValueTask<SavedServer> AddAsync(ServerDraft draft, string? pickedKey, ReadOnlyMemory<byte> password, CancellationToken ct = default, ServerCaller? caller = null);
  ValueTask SetAccessAsync(string id, ServerAccess access, ServerCaller caller, CancellationToken ct = default);
  ValueTask RenameAsync(string id, string name, ServerCaller caller, CancellationToken ct = default) => ValueTask.FromException(new ServerRefusal("This connection cannot rename servers yet."));
  ValueTask RemoveAsync(string id, string confirmName, ServerCaller caller, CancellationToken ct = default);
  ValueTask<string> TestAsync(string id, ServerCaller caller, CancellationToken ct = default);
  ValueTask<string> ScanHostKeyAsync(string id, ServerCaller caller, CancellationToken ct = default);
  ValueTask TrustHostKeyAsync(string id, string key, ServerCaller caller, CancellationToken ct = default);
  ValueTask<ServerFilePage> FilesAsync(string id, string path, ServerCaller caller, CancellationToken ct = default);
  ValueTask<ServerFilePage> FilesPageAsync(string id, string path, int offset, ServerCaller caller, CancellationToken ct = default) =>
    offset == 0 ? FilesAsync(id, path, caller, ct) : ValueTask.FromException<ServerFilePage>(new ServerRefusal("This connection does not support more files yet."));
  ValueTask<ServerFileContent> ReadAsync(string id, string path, ServerCaller caller, CancellationToken ct = default);
  ValueTask UploadAsync(string id, string path, ReadOnlyMemory<byte> bytes, ServerCaller caller, CancellationToken ct = default);
  ValueTask DownloadAsync(string id, string path, string localPath, ServerCaller caller, CancellationToken ct = default);
  ValueTask ChangeFileAsync(string id, string path, string operation, string? name, string? confirmName, ServerCaller caller, CancellationToken ct = default);
  ValueTask<IReadOnlyList<ServerApp>> AppsAsync(string id, ServerCaller caller, CancellationToken ct = default);
  ValueTask<ServerHealth> HealthAsync(string id, ServerCaller caller, CancellationToken ct = default) => ValueTask.FromException<ServerHealth>(new ServerRefusal("Health is not connected yet."));
  ValueTask<string> LogsAsync(string id, string appId, int lines, ServerCaller caller, CancellationToken ct = default);
  ValueTask ControlAsync(string id, string appId, string action, ServerCaller caller, CancellationToken ct = default);
  ValueTask<string> OpenTerminalAsync(string id, ServerCaller caller, CancellationToken ct = default);
}
public static partial class ServerValidation
{
  [GeneratedRegex("^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$")] private static partial Regex HostPattern();
  [GeneratedRegex("^[a-zA-Z_][a-zA-Z0-9_.-]{0,63}$")] private static partial Regex UserPattern();
  [GeneratedRegex("^[a-f0-9]{32}$")] private static partial Regex IdPattern();
  [GeneratedRegex("^[a-f0-9]{12,64}$")] private static partial Regex ContainerPattern();
  public static void Id(string id) { if (!IdPattern().IsMatch(id)) throw new ServerRefusal("Choose a saved server."); }
  public static void Draft(ServerDraft d)
  {
    if (!HostPattern().IsMatch(d.Host) && !(System.Net.IPAddress.TryParse(d.Host, out _) && !d.Host.Contains('%')) || !UserPattern().IsMatch(d.User) || d.Port is < 1 or > 65535 ||
      string.IsNullOrWhiteSpace(d.Name) || d.Name.Length > 100 || d.Name.Any(char.IsControl) || !Enum.IsDefined(d.Authentication))
      throw new ServerRefusal("Enter a server name, host, port and SSH user.");
  }
  public static void Access(ServerAccess access)
  {
    if (access.Folders.IsDefault || access.AiApps.IsDefault || access.Folders.Length > 32 || access.AiApps.Length > 100) throw new ServerRefusal("Choose folders and AI apps for this server.");
    foreach (var path in access.Folders) Path(path);
    if (access.AiApps.Any(x => string.IsNullOrWhiteSpace(x) || x.Length > 128 || x.Any(char.IsControl))) throw new ServerRefusal("Choose named AI apps.");
  }
  public static void Path(string path)
  {
    if (!path.StartsWith('/') || path.Contains('\\') || path.Length > 4096 || path.Any(char.IsControl) || path.Split('/').Any(p => p is "." or ".."))
      throw new ServerRefusal("Choose a full Linux path without dot steps.");
  }
  public static void Container(string id) { if (!ContainerPattern().IsMatch(id)) throw new ServerRefusal("Refresh Apps and choose a container."); }
  public static string Quote(string value) => "'" + value.Replace("'", "'\"'\"'", StringComparison.Ordinal) + "'";
  public static void CanRead(SavedServer server, ServerCaller caller)
  {
    if (caller.PairedDevice || !caller.Owner && !caller.ManageServers && !caller.LocalSession && !server.Access.AiApps.Contains(caller.Id)) throw new ServerRefusal("This AI app has no access to this server.");
  }
  public static void CanChange(SavedServer server, ServerCaller caller)
  {
    CanRead(server, caller);
    if (server.Access.LookOnly) throw new ServerRefusal("This server is Look only. The owner can change access on its server page.");
  }
}
