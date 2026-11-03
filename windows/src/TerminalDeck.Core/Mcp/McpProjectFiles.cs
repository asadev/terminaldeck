using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Mcp;

// Shared project files contain portable connection facts and environment names,
// never values from the machine's protected credential store. Private ledger
// entries are the ownership receipt; foreign names cannot be replaced silently.
public static class McpProjectFiles
{
  public sealed record Change(string Path, byte[]? Before, byte[] After);
  public static string Variable(string reference) => "TD_MCP_" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(reference)))[..24];
  public static JsonObject Entry(McpServerConfig server)
  {
    var node = server.Transport == "stdio" ? new JsonObject { ["type"] = "stdio", ["command"] = server.Executable, ["args"] = new JsonArray(server.Arguments.Select((a, index) => (JsonNode)JsonValue.Create(server.ArgumentReferences is { } references && references.TryGetValue(index, out var reference) ? "${" + Variable(reference) + "}" : a)!).ToArray()) } :
      new JsonObject { ["type"] = server.Transport, ["url"] = server.Url };
    if (server.EnvironmentReferences.Count > 0) node["env"] = new JsonObject(server.EnvironmentReferences.Select(p => new KeyValuePair<string, JsonNode?>(p.Key, JsonValue.Create("${" + Variable(p.Value) + "}"))));
    if (server.HeaderReferences.Count > 0) node["headers"] = new JsonObject(server.HeaderReferences.Select(p => new KeyValuePair<string, JsonNode?>(p.Key, JsonValue.Create("${" + Variable(p.Value) + "}"))));
    // Disabled project entries stay private, rather than introducing a vendor
    // switch other clients ignore and starting a server the person turned off.
    return node;
  }
  public static Change[] Prepare(McpManagerState before, McpManagerState after)
  {
    var folders = before.Servers.Concat(after.Servers).Where(s => s.Scope == "project").Select(s => Path.GetFullPath(s.Folder!)).Distinct(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
    var changes = new List<Change>();
    foreach (var folder in folders)
    {
      var oldRows = before.Servers.Where(s => s.Scope == "project" && Same(s.Folder!, folder)).ToArray();
      var newRows = after.Servers.Where(s => s.Scope == "project" && Same(s.Folder!, folder)).ToArray();
      if (JsonSerializer.Serialize(oldRows) == JsonSerializer.Serialize(newRows)) continue;
      if (!Directory.Exists(folder)) throw new McpRefusal("The shared project folder no longer exists.");
      var file = Path.Combine(folder, ".mcp.json"); NoLinks(file);
      var bytes = Read(file); var root = bytes is null || bytes.Length == 0 ? new JsonObject() : JsonNode.Parse(bytes, documentOptions: new JsonDocumentOptions { MaxDepth = 32 }) as JsonObject ?? throw new McpRefusal("The project's .mcp.json must be an object. It was left untouched.");
      if (root["mcpServers"] is not null && root["mcpServers"] is not JsonObject) throw new McpRefusal("The project's MCP list could not be merged safely.");
      var servers = root["mcpServers"] as JsonObject ?? new JsonObject(); if (root["mcpServers"] is null) root["mcpServers"] = servers;
      foreach (var old in oldRows)
      {
        if (servers[old.Name] is { } existing)
        {
          if (!old.Enabled || !JsonNode.DeepEquals(existing, Entry(old))) throw new McpRefusal("The shared MCP entry changed outside the app. Review .mcp.json before replacing it.");
          servers.Remove(old.Name);
        }
        else if (old.Enabled && newRows.Any(n => n.Id == old.Id && n.Enabled)) throw new McpRefusal("The shared MCP entry was removed outside the app. Review it before saving.");
      }
      foreach (var next in newRows.Where(s => s.Enabled))
      {
        if (servers.ContainsKey(next.Name)) throw new McpRefusal("A foreign shared MCP entry already uses this name. Choose another name.");
        servers[next.Name] = Entry(next);
      }
      var output = JsonSerializer.SerializeToUtf8Bytes(root, new JsonSerializerOptions { WriteIndented = true });
      if (bytes is not null && bytes.AsSpan().SequenceEqual(output)) continue;
      changes.Add(new(file, bytes, output));
    }
    return changes.ToArray();
  }
  public static void Apply(Change[] changes, Action saveLedger)
  {
    var written = new List<Change>();
    try
    {
      foreach (var change in changes)
      {
        NoLinks(change.Path); if (!Equal(Read(change.Path), change.Before)) throw new McpRefusal("The shared project configuration changed during this edit. Try again.");
        Atomic(change.Path, change.After); written.Add(change);
        if (!Equal(Read(change.Path), change.After)) throw new IOException("The shared project configuration did not pass readback.");
      }
      saveLedger();
    }
    catch
    {
      foreach (var change in written.AsEnumerable().Reverse())
      {
        if (!Equal(Read(change.Path), change.After)) continue;
        if (change.Before is null) File.Delete(change.Path); else Atomic(change.Path, change.Before);
      }
      throw;
    }
  }
  private static void Atomic(string path, byte[] bytes)
  {
    var temp = path + ".td-" + Guid.NewGuid().ToString("N");
    try { File.WriteAllBytes(temp, bytes); File.Move(temp, path, true); } finally { if (File.Exists(temp)) File.Delete(temp); }
  }
  private static byte[]? Read(string path)
  {
    if (!File.Exists(path)) return null; using var stream = File.OpenRead(path);
    if (stream.Length > 2 * 1024 * 1024) throw new McpRefusal("The shared project MCP file exceeds its size limit.");
    var bytes = new byte[(int)stream.Length]; stream.ReadExactly(bytes); return bytes;
  }
  private static bool Equal(byte[]? a, byte[]? b) => a is null ? b is null : b is not null && a.AsSpan().SequenceEqual(b);
  private static bool Same(string a, string b) => string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
  private static void NoLinks(string path)
  {
    for (var current = Path.GetDirectoryName(path); current is not null; current = Path.GetDirectoryName(current))
      if (Directory.Exists(current) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new McpRefusal("Linked project folders cannot hold shared MCP configuration here.");
    if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new McpRefusal("Linked shared MCP files were left untouched.");
  }
}
