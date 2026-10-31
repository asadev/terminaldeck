using System.Text.Json;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Mcp;

public sealed record McpServerConfig(string Id, string Name, string Scope, string? Folder, string Transport,
  string? Executable, string[] Arguments, string? Url, Dictionary<string, string> EnvironmentReferences,
  Dictionary<string, string> HeaderReferences, bool Enabled = true, string[]? DisabledTools = null);
public sealed record McpManagerState(int Version, McpServerConfig[] Servers);
public sealed record McpServerView(string Id, string Name, string Scope, string? Folder, string Transport, bool Enabled, bool Connected, int? ToolCount = null);
public sealed record McpRemoteTool(string Name, JsonElement InputSchema, string? Title = null, string? Description = null);
public sealed record McpServerSettings(McpServerView Server, string? Executable, string[] Arguments, string? Url,
  string[] EnvironmentNames, string[] HeaderNames, string[] DisabledTools)
{
  public override string ToString() => "<MCP server settings>";
}
public sealed record McpDiagnostic(DateTimeOffset At, string Message);
public sealed record McpCommand(string Executable, string[] Arguments);
public interface IMcpCommandResolver { McpCommand Resolve(string commandLine); }
public interface IManagedMcpConnection : IAsyncDisposable
{
  ValueTask<IReadOnlyList<McpRemoteTool>> ToolsAsync(CancellationToken cancellationToken);
  ValueTask<JsonElement> CallAsync(string tool, JsonElement arguments, CancellationToken cancellationToken);
}
public interface IMcpConnectionFactory
{
  // The connection owns only children it creates. Dispose must never kill an imported/shared PID.
  ValueTask<IManagedMcpConnection> ConnectAsync(McpServerConfig config, ISecretStore secrets, CancellationToken cancellationToken);
}
public sealed class McpServerInput
{
  public required string Name { get; init; }
  public required string Scope { get; init; }
  public required string Transport { get; init; }
  public string? Folder { get; init; }
  public string? Command { get; init; }
  public string? Url { get; init; }
  public Dictionary<string, string> Environment { get; init; } = [];
  public Dictionary<string, string> Headers { get; init; } = [];
  public override string ToString() => "<MCP server input>";
}

public sealed class McpManager : IAsyncDisposable
{
  private readonly IStateStore<McpManagerState> store;
  private readonly ISecretStore secrets;
  private readonly IMcpCommandResolver commands;
  private readonly IMcpConnectionFactory factory;
  private readonly string prefix;
  private readonly SemaphoreSlim gate = new(1);
  private readonly Dictionary<string, IManagedMcpConnection> connected = [];
  public event Action? Changed;
  private McpManagerState state;
  private readonly Dictionary<string, List<McpDiagnostic>> diagnostics = [];
  private readonly Dictionary<string, int> toolCounts = [];

  public McpManager(IStateStore<McpManagerState> store, ISecretStore secrets, AppDataRoot root, IMcpCommandResolver commands, IMcpConnectionFactory factory)
  {
    this.store = store; this.secrets = secrets; this.commands = commands; this.factory = factory;
    prefix = $"{Brand.Name}/{root.NamespaceId}/mcp/";
    state = store.Load() ?? new(1, []);
    if (state.Version != 1 || state.Servers.Select(s => s.Id).Distinct().Count() != state.Servers.Length)
      throw new IOException("The saved MCP servers could not be read safely.");
  }
  public async ValueTask<IReadOnlyList<McpServerView>> ListAsync(CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try { return state.Servers.Select(s => new McpServerView(s.Id, s.Name, s.Scope, s.Folder, s.Transport, s.Enabled, connected.ContainsKey(s.Id), toolCounts.TryGetValue(s.Id, out var count) ? count : null)).ToArray(); }
    finally { gate.Release(); }
  }
  public async ValueTask<McpServerView> AddAsync(McpServerInput input, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var config = Validate(input);
      if (state.Servers.Any(s => s.Id == config.Id)) throw new McpRefusal("An MCP server with that name already exists in this scope.");
      var written = new List<string>();
      try
      {
        config = config with { EnvironmentReferences = await ProtectAsync(input.Environment, written, cancellationToken), HeaderReferences = await ProtectAsync(input.Headers, written, cancellationToken) };
        Save(state with { Servers = [.. state.Servers, config] });
      }
      catch { foreach (var reference in written) await secrets.DeleteAsync(reference, CancellationToken.None); throw; }
      return new(config.Id, config.Name, config.Scope, config.Folder, config.Transport, true, false);
    }
    finally { gate.Release(); }
  }
  public async ValueTask EditAsync(string id, McpServerInput input, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var previous = Find(id); var config = Validate(input, previous.Scope == "project" && input.Scope == "project" && input.Folder == previous.Folder);
      if (state.Servers.Any(s => s.Id != id && s.Id == config.Id)) throw new McpRefusal("An MCP server with that name already exists in this scope.");
      var written = new List<string>();
      try
      {
        config = config with { Enabled = previous.Enabled, DisabledTools = previous.DisabledTools, EnvironmentReferences = await ProtectAsync(input.Environment, written, cancellationToken), HeaderReferences = await ProtectAsync(input.Headers, written, cancellationToken) };
        await DisconnectOwnedAsync(id);
        Save(state with { Servers = state.Servers.Select(s => s.Id == id ? config : s).ToArray() });
      }
      catch { foreach (var reference in written) await secrets.DeleteAsync(reference, CancellationToken.None); throw; }
      await DeleteReferencesAsync(previous);
    }
    finally { gate.Release(); }
  }
  public async ValueTask EditPatchAsync(string id, JsonElement patch, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var previous = Find(id);
      string? Text(string key) => patch.TryGetProperty(key, out var value) ? value.GetString() : null;
      var next = previous with { Name = Text("name") ?? previous.Name, Scope = Text("scope") ?? previous.Scope, Transport = Text("transport") ?? previous.Transport, Url = Text("url") ?? previous.Url };
      if (next.Scope == "project" && previous.Scope != "project") throw new McpRefusal("Shared project configuration is not available here. Use local for a private project server, or user for every project.");
      if (patch.TryGetProperty("enabled", out var enabled)) next = next with { Enabled = enabled.GetBoolean() };
      if (patch.TryGetProperty("disabledTools", out var disabled))
      {
        if (disabled.ValueKind != JsonValueKind.Array || disabled.GetArrayLength() > 4096) throw new McpRefusal("Choose tool names from this server.");
        var names = disabled.EnumerateArray().Select(t => t.GetString() ?? "").ToArray();
        if (names.Any(t => string.IsNullOrWhiteSpace(t) || t.Length > 256 || t.Any(char.IsControl))) throw new McpRefusal("Choose valid tool names from this server.");
        next = next with { DisabledTools = names.Distinct(StringComparer.Ordinal).ToArray() };
      }
      next = next with { Id = MakeId(next.Name, next.Scope, next.Folder) };
      if (!Regex.IsMatch(next.Name, "^[a-zA-Z0-9_.-]{1,80}$") || next.Scope is not ("user" or "project" or "local") || next.Transport is not ("stdio" or "http" or "sse") || next.Scope != "user" && string.IsNullOrWhiteSpace(next.Folder))
        throw new McpRefusal("Choose a valid MCP name, scope and connection type.");
      if (state.Servers.Any(s => s.Id != id && s.Id == next.Id)) throw new McpRefusal("An MCP server with that name already exists.");
      if (Text("command") is { } command)
      {
        var resolved = commands.Resolve(command); next = next with { Executable = resolved.Executable, Arguments = resolved.Arguments };
      }
      if (next.Transport == "stdio" && string.IsNullOrWhiteSpace(next.Executable)) throw new McpRefusal("Choose a command for this MCP server.");
      if (next.Transport != "stdio" && (!Uri.TryCreate(next.Url, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") || uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0))
        throw new McpRefusal("Choose an HTTP or HTTPS address with credentials in protected headers.");
      var written = new List<string>();
      try
      {
        foreach (var field in new[] { "env", "headers", "envSet", "headersSet" })
        {
          if (!patch.TryGetProperty(field, out var values)) continue;
          var input = values.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString() ?? throw new McpRefusal("MCP values must be text."));
          if (input.Count > 64 || input.Any(p => !Regex.IsMatch(p.Key, "^[a-zA-Z0-9_-]{1,128}$") || p.Value.Length > 2560)) throw new McpRefusal("The MCP environment or headers are unusable.");
          var references = await ProtectAsync(input, written, cancellationToken);
          var environment = field.StartsWith("env", StringComparison.Ordinal);
          if (field.EndsWith("Set", StringComparison.Ordinal))
          {
            var mergedReferences = new Dictionary<string, string>(environment ? next.EnvironmentReferences : next.HeaderReferences);
            foreach (var entry in references) mergedReferences[entry.Key] = entry.Value;
            references = mergedReferences;
          }
          next = environment ? next with { EnvironmentReferences = references } : next with { HeaderReferences = references };
        }
        await DisconnectOwnedAsync(id); Save(state with { Servers = state.Servers.Select(s => s.Id == id ? next : s).ToArray() });
      }
      catch { foreach (var reference in written) await secrets.DeleteAsync(reference, CancellationToken.None); throw; }
      var retained = next.EnvironmentReferences.Values.Concat(next.HeaderReferences.Values).ToHashSet();
      foreach (var reference in previous.EnvironmentReferences.Values.Concat(previous.HeaderReferences.Values).Where(r => !retained.Contains(r))) await secrets.DeleteAsync(reference);
    }
    finally { gate.Release(); }
  }
  public async ValueTask RemoveAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var config = Find(id); await DisconnectOwnedAsync(id);
      Save(state with { Servers = state.Servers.Where(s => s.Id != id).ToArray() });
      await DeleteReferencesAsync(config);
    }
    finally { gate.Release(); }
  }
  public async ValueTask<IReadOnlyList<McpRemoteTool>> ConnectAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var config = Find(id);
      if (!config.Enabled) throw new McpRefusal("Enable this MCP server before connecting.");
      IManagedMcpConnection? created = null;
      try
      {
        if (!connected.TryGetValue(id, out var connection)) connection = created = await factory.ConnectAsync(config, secrets, cancellationToken);
        var tools = await connection.ToolsAsync(cancellationToken);
        if (created is not null) connected.Add(id, created);
        toolCounts[id] = tools.Count; Changed?.Invoke();
        return tools;
      }
      catch (OperationCanceledException) { if (created is not null) await created.DisposeAsync(); throw; }
      catch { if (created is not null) await created.DisposeAsync(); Record(id, "Connection failed. Check the server command or address and its protected credentials."); throw new McpRefusal("This MCP server could not connect. Check its command or address."); }
    }
    finally { gate.Release(); }
  }
  public async ValueTask DisconnectAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try { _ = Find(id); await DisconnectOwnedAsync(id); Changed?.Invoke(); }
    finally { gate.Release(); }
  }
  public async ValueTask<JsonElement> CallAsync(string id, string tool, JsonElement arguments, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var config = Find(id);
      if (!config.Enabled || config.DisabledTools?.Contains(tool, StringComparer.Ordinal) == true) throw new McpRefusal("This MCP tool is turned off.");
      if (!connected.TryGetValue(id, out var connection)) throw new McpRefusal("Connect this MCP server before calling its tools.");
      var tools = await connection.ToolsAsync(cancellationToken);
      var spec = tools.FirstOrDefault(t => t.Name == tool) ?? throw new McpRefusal("That tool is not offered by this MCP server.");
      McpSchema.Validate(spec.InputSchema, arguments);
      try { var data = await connection.CallAsync(tool, arguments, cancellationToken); return JsonSerializer.SerializeToElement(new { source = new { kind = "third-party-mcp", serverId = id, tool }, untrusted = true, data }); }
      catch (OperationCanceledException) { throw; }
      catch { Record(id, "A tool call failed. The server’s private error text was omitted."); throw new McpRefusal("This MCP server could not finish the action."); }
    }
    finally { gate.Release(); }
  }
  public McpServerConfig Preview(McpServerInput input) => Validate(input);
  public async ValueTask<JsonElement> ExportAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var s = Find(id);
      // Export can be shared: values, executable args and header credentials stay private.
      return JsonSerializer.SerializeToElement(new { s.Name, s.Scope, s.Folder, s.Transport, s.Url, commandConfigured = s.Executable is not null, environment = s.EnvironmentReferences.Keys, headers = s.HeaderReferences.Keys, s.Enabled, disabledTools = s.DisabledTools ?? [], log = diagnostics.GetValueOrDefault(id)?.ToArray() ?? [], redacted = true });
    }
    finally { gate.Release(); }
  }
  public ValueTask SetSecretAsync(string id, string name, string value, bool header, CancellationToken ct = default) =>
    EditPatchAsync(id, JsonSerializer.SerializeToElement(new Dictionary<string, object> { [header ? "headersSet" : "envSet"] = new Dictionary<string, string> { [name] = value } }), ct);

  public async ValueTask<McpServerSettings> SettingsAsync(string id, CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try
    {
      var s = Find(id);
      return new(new(s.Id, s.Name, s.Scope, s.Folder, s.Transport, s.Enabled, connected.ContainsKey(id)),
        s.Executable, [.. s.Arguments], s.Url, [.. s.EnvironmentReferences.Keys], [.. s.HeaderReferences.Keys], [.. s.DisabledTools ?? []]);
    }
    finally { gate.Release(); }
  }

  // Testing an off server owns a temporary connection and never changes its saved policy.
  public async ValueTask<IReadOnlyList<McpRemoteTool>> TestAsync(string id, CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try
    {
      var config = Find(id);
      try
      {
        await using var connection = await factory.ConnectAsync(config, secrets, ct);
        var tools = await connection.ToolsAsync(ct);
        toolCounts[id] = tools.Count; Changed?.Invoke();
        return tools;
      }
      catch (OperationCanceledException) { throw; }
      catch { Record(id, "Connection test failed. Check the server command or address and its protected credentials."); throw new McpRefusal("The connection test failed. Check the server command or address."); }
    }
    finally { gate.Release(); }
  }

  private void Record(string id, string message)
  {
    if (!diagnostics.TryGetValue(id, out var rows)) diagnostics[id] = rows = [];
    rows.Add(new(DateTimeOffset.UtcNow, message));
    if (rows.Count > 50) rows.RemoveAt(0);
  }

  public string ResolveId(string name, string scope, string? folder) => MakeId(name, scope, folder);
  private McpServerConfig Find(string id) => state.Servers.FirstOrDefault(s => s.Id == id) ?? throw new McpRefusal("Choose an MCP server from the list.");
  private McpServerConfig Validate(McpServerInput input, bool allowLegacyProject = false)
  {
    if (input.Scope == "project" && !allowLegacyProject) throw new McpRefusal("Shared project configuration is not available here. Choose a private project server or every project.");
    if (!Regex.IsMatch(input.Name, "^[a-zA-Z0-9_.-]{1,80}$") || input.Scope is not ("user" or "project" or "local") || input.Transport is not ("stdio" or "http" or "sse"))
      throw new McpRefusal("Choose an MCP server name, scope and connection type.");
    if (input.Scope != "user" && (string.IsNullOrWhiteSpace(input.Folder) || input.Folder.Contains('\0')))
      throw new McpRefusal("Choose a folder for this MCP server.");
    McpCommand? command = null;
    if (input.Transport == "stdio")
    {
      if (string.IsNullOrWhiteSpace(input.Command) || input.Command.Contains('\0')) throw new McpRefusal("Choose the command that starts this MCP server.");
      command = commands.Resolve(input.Command);
      if (string.IsNullOrWhiteSpace(command.Executable) || command.Executable.Contains('\0') || command.Arguments.Any(a => a.Contains('\0')))
        throw new McpRefusal("The MCP command could not be read safely.");
    }
    else if (!Uri.TryCreate(input.Url, UriKind.Absolute, out var uri) || uri.Scheme is not ("https" or "http") || uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0)
      throw new McpRefusal("Choose an HTTP or HTTPS address. Put credentials in protected headers.");
    if (input.Environment.Count > 64 || input.Headers.Count > 64 || input.Environment.Concat(input.Headers).Any(p => !Regex.IsMatch(p.Key, "^[a-zA-Z0-9_-]{1,128}$") || p.Value.Length > 2560))
      throw new McpRefusal("The MCP environment or headers are unusable.");
    return new(MakeId(input.Name, input.Scope, input.Folder), input.Name, input.Scope, input.Scope == "user" ? null : input.Folder, input.Transport,
      command?.Executable, command?.Arguments ?? [], input.Transport == "stdio" ? null : input.Url, [], []);
  }
  private static string MakeId(string name, string scope, string? folder) => scope == "user" ? "user:" + name : scope + ":" + folder + ":" + name;
  private async ValueTask<Dictionary<string, string>> ProtectAsync(Dictionary<string, string> input, List<string> written, CancellationToken ct)
  {
    var result = new Dictionary<string, string>();
    foreach (var (key, value) in input)
    {
      var reference = prefix + Guid.NewGuid().ToString("N");
      var bytes = System.Text.Encoding.UTF8.GetBytes(value);
      try { await secrets.WriteAsync(reference, bytes, ct); }
      finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(bytes); }
      written.Add(reference); result.Add(key, reference);
    }
    return result;
  }
  private async ValueTask DeleteReferencesAsync(McpServerConfig config)
  {
    foreach (var reference in config.EnvironmentReferences.Values.Concat(config.HeaderReferences.Values)) await secrets.DeleteAsync(reference);
  }
  private async ValueTask DisconnectOwnedAsync(string id) { if (connected.Remove(id, out var connection)) await connection.DisposeAsync(); }
  private void Save(McpManagerState next)
  {
    store.Save(next);
    foreach (var old in state.Servers)
    {
      if (!next.Servers.Any(s => s == old)) toolCounts.Remove(old.Id);
      if (!next.Servers.Any(s => s.Id == old.Id)) diagnostics.Remove(old.Id);
    }
    state = next; Changed?.Invoke();
  }
  public async ValueTask DisposeAsync()
  {
    await gate.WaitAsync();
    try { foreach (var connection in connected.Values) await connection.DisposeAsync(); connected.Clear(); }
    finally { gate.Release(); }
  }
}
