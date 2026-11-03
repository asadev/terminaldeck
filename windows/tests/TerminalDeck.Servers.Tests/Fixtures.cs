using System.Text.Json;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Servers;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Servers.Tests;

internal sealed class SecretStore : ISecretStore
{
  public Dictionary<string, byte[]> Values { get; } = [];
  public ValueTask<byte[]?> ReadAsync(string name, CancellationToken cancellationToken = default) => ValueTask.FromResult(Values.TryGetValue(name, out var bytes) ? bytes.ToArray() : null);
  public ValueTask WriteAsync(string name, ReadOnlyMemory<byte> value, CancellationToken cancellationToken = default) { Values[name] = value.ToArray(); return ValueTask.CompletedTask; }
  public ValueTask DeleteAsync(string name, CancellationToken cancellationToken = default) { Values.Remove(name); return ValueTask.CompletedTask; }
}
internal sealed class Approval : IServerAuthorizer
{
  public bool Allow { get; set; } = true;
  public List<ServerAction> Actions { get; } = [];
  public Func<ValueTask>? During { get; set; }
  public async ValueTask<bool> ApproveAsync(ServerCaller caller, ServerAction action, CancellationToken ct)
  { Actions.Add(action); if (During is not null) await During(); return Allow; }
}
internal sealed class Runtime : IServerRuntime
{
  public List<ServerCommand> Commands { get; } = [];
  public List<string> Imported { get; } = [];
  public List<string> Trusted { get; } = [];
  public bool ImportFails { get; set; }
  public List<string> Removed { get; } = [];
  public Func<ServerCommand, ServerOutput> Reply { get; set; } = c => new(0, c.Script.StartsWith("docker ps", StringComparison.Ordinal) ? Container : "{}");
  public const string AppId = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  public static string Container => JsonSerializer.Serialize(new { ID = AppId, Names = "td-test-web", Image = "example/web:1", State = "running", Status = "Up 1 minute", Ports = "127.0.0.1:18080->80/tcp" }) + "\n";
  public ValueTask<ServerOutput> RunAsync(SavedServer server, ServerCommand command, CancellationToken ct) { ct.ThrowIfCancellationRequested(); Commands.Add(command); return ValueTask.FromResult(Reply(command)); }
  public ValueTask ImportKeyAsync(string serverId, string explicitlyPickedFile, CancellationToken ct) { Imported.Add(explicitlyPickedFile); return ImportFails ? ValueTask.FromException(new IOException("fixture import failed")) : ValueTask.CompletedTask; }
  public ValueTask RemoveKeyAsync(string serverId, CancellationToken ct) { Removed.Add(serverId); return ValueTask.CompletedTask; }
  public ValueTask<string> ScanHostKeyAsync(SavedServer server, CancellationToken ct) => ValueTask.FromResult("ssh-ed25519 " + Convert.ToBase64String(new byte[64]));
  public ValueTask TrustHostKeyAsync(SavedServer server, string key, CancellationToken ct) { Trusted.Add(key); return ValueTask.CompletedTask; }
}
internal sealed class Fixture : IDisposable
{
  public string Path { get; } = System.IO.Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : System.IO.Path.GetTempPath(), "td-servers-" + Guid.NewGuid().ToString("N"));
  public SecretStore Secrets { get; } = new();
  public Runtime Runtime { get; } = new();
  public Approval Approval { get; } = new();
  public AppDataRoot Root { get; }
  public ServerStore Store { get; }
  public ServerService Service { get; }
  public Fixture() { Directory.CreateDirectory(Path); Root = AppDataRoot.Explicit(Path); Store = new(Root, Secrets); Service = new(Store, Runtime, Approval); }
  public async Task<SavedServer> AddAsync(bool writable = false)
  {
    var row = await Service.AddAsync(new("Test server", "example.test", 22, "tester", ServerAuthentication.Password), null, "fixture-password"u8.ToArray());
    if (writable) await Store.SetAccessAsync(row.Id, new(false, ["/srv/test"], ["connected-ai"]), default);
    Approval.Actions.Clear(); Runtime.Commands.Clear(); return Store.Get(row.Id);
  }
  public void Dispose() { if (Directory.Exists(Path)) Directory.Delete(Path, true); }
}
