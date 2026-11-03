using System.Text.Json;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Code;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Store;

namespace TerminalDeck.Platform.Windows;

public sealed partial class CommunityStoreOperations
{
  public async ValueTask<StoreInstallation> InstallMcpStockAsync(StoreEntry entry, StoreInstallOptions options, HttpClient http, CancellationToken ct)
  {
    var row = entry.Manifest ?? throw new IOException("The bundled MCP entry is missing."); var runtime = row.GetProperty("runtime").GetString();
    var command = row.GetProperty("command").GetString()!.Split(' ', StringSplitOptions.RemoveEmptyEntries); var inputs = row.GetProperty("inputs");
    if (runtime is "node" or "python")
    {
      var offset = runtime == "node" ? 3 : 2; if (command.Length < offset) throw new IOException("The MCP package command is incomplete.");
      var package = command[offset - 1]; var arguments = command.Skip(offset).Select(a => Regex.Replace(a, @"\$\{([A-Z][A-Z0-9_]*)\}", match => "${input:" + match.Groups[1].Value + "}")).ToArray();
      var normalized = JsonSerializer.SerializeToElement(new { kind = "mcp", agents = new[] { "claude", "codex", "gemini" }, install = new { runtime, package, args = arguments, inputs } });
      return await InstallAsync(entry with { Manifest = normalized }, options, http, ct);
    }
    if (runtime != "docker" || command[0] != "docker") throw new IOException("This catalogue runtime is unsupported.");
    var values = options.Values ?? []; var environment = new Dictionary<string, string>();
    foreach (var field in inputs.EnumerateArray())
    {
      var key = field.GetProperty("key").GetString()!; var required = field.GetProperty("required").GetBoolean();
      if (!values.TryGetValue(key, out var value)) { if (required) throw new ArgumentException("Fill in " + key + " before installing."); continue; }
      if (value.Length > 4096 || value.Any(char.IsControl)) throw new ArgumentException("Use a bounded single-line value for " + key + ".");
      if (field.GetProperty("into").GetString() == "env") environment[key] = value;
    }
    var paths = (Accounts.WindowsAiEnvironment.Read().GetValueOrDefault("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries).Concat(new[] { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Docker", "Docker", "resources", "bin") });
    var executable = paths.Select(p => Path.Combine(p, "docker.exe")).FirstOrDefault(File.Exists) ?? throw new IOException("Install Docker Desktop before adding this server.");
    var check = await new CodeProcessRunner().RunAsync(executable, ["info", "--format", "{{.ServerVersion}}"], root, TimeSpan.FromSeconds(15), ct);
    if (!check.Ok) throw new IOException("Docker is installed but its engine is not ready. Start Docker Desktop and retry.");
    if (options.EnsureCurrent is { } refresh) await refresh(ct);
    var secretKeys = inputs.EnumerateArray().Where(f => f.GetProperty("kind").GetString() == "secret" && f.GetProperty("into").GetString() == "arg").Select(f => f.GetProperty("key").GetString()!).ToHashSet(StringComparer.Ordinal);
    var protectedArguments = new Dictionary<int, string>();
    var argumentsToUse = command.Skip(1).Select((a, index) => Regex.Replace(a, @"\$\{([A-Z][A-Z0-9_]*)\}", match => { var key = match.Groups[1].Value; var value = values.GetValueOrDefault(key) ?? throw new ArgumentException("Fill in " + key); if (secretKeys.Contains(key)) { protectedArguments[index] = value; return "[protected]"; } return value; })).ToArray();
    var name = "td-" + entry.Id.Replace('/', '.'); if (name.Length > 80) name = name[..80];
    var input = new McpServerInput { Name = name, Scope = "user", Transport = "stdio", Command = WindowsCommandLine.Quote(executable) + " " + string.Join(' ', argumentsToUse.Select(WindowsCommandLine.Quote)), Environment = environment, SecretArguments = protectedArguments };
    string id;
    if (options.PreviousReceipt is { } prior)
    {
      var receipt = JsonSerializer.Deserialize<Receipt>(prior) ?? throw new IOException("The prior MCP receipt is missing."); id = receipt.Registration ?? throw new IOException("The prior MCP registration is missing."); await mcp.EditAsync(id, input, ct);
    }
    else id = (await mcp.AddAsync(input, ct)).Id;
    return new(JsonSerializer.Serialize(new Receipt("mcp", [], id)), entry.Version);
  }
}
