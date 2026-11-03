using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Hooks;

public sealed record ProviderHookStatus(string Id, string File, bool FileExists, string State, string[] InstalledEvents, string[] MissingEvents, int ForeignHooks, string? BackupPath, string Message);
public sealed record ProviderHookEvent(string Provider, string Event, string? SessionId, string? ConversationId, string? Folder, DateTimeOffset At);

// Paths come from the resolved account homes, never request arguments. This
// owner merges only its marked commands and preserves every other JSON value.
public sealed class ProviderHooks(IReadOnlyDictionary<string, string> settingsFiles, string backupDirectory, Func<string, string, string> command)
{
  public const string Marker = "td-native-windows-hooks-v1";
  public static IReadOnlyDictionary<string, string[]> Events { get; } = new Dictionary<string, string[]>
  {
    ["claude"] = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"],
    ["codex"] = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"],
    ["gemini"] = ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "AfterAgent", "Notification", "SessionEnd"]
  };
  private readonly object gate = new();
  public ProviderHookStatus[] Status() => settingsFiles.Keys.Select(Status).ToArray();
  public ProviderHookStatus Status(string provider)
  {
    lock (gate)
    {
      var path = PathFor(provider);
      try
      {
        var root = Read(path); var hooks = root["hooks"] as JsonObject; var installed = new List<string>(); var foreign = 0; var stale = false;
        foreach (var eventName in Events[provider])
          if (hooks?[eventName] is JsonArray groups)
            foreach (var group in groups.OfType<JsonObject>())
              if (group["hooks"] is JsonArray entries)
                foreach (var entry in entries.OfType<JsonObject>())
                {
                  var text = entry["command"]?.GetValue<string>() ?? "";
                  if (text == command(provider, eventName)) installed.Add(eventName); else if (!text.Contains(Marker, StringComparison.Ordinal)) foreign++; else stale = true;
                }
        var missing = Events[provider].Except(installed).ToArray();
        return new(provider, path, File.Exists(path), missing.Length == 0 ? "complete" : stale ? "stale" : installed.Count == 0 ? "none" : "partial", installed.Distinct().ToArray(), missing, foreign,
          File.Exists(Backup(provider)) ? Backup(provider) : null, provider == "codex" ? "Codex also needs hooks = true under [features] in config.toml, then Trust all when it asks." : "Only this app's marked hook commands are managed here.");
      }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException) { return new(provider, path, File.Exists(path), "error", [], Events[provider], 0, null, "The provider settings could not be read safely. They were left untouched."); }
    }
  }
  public ProviderHookStatus Install(string provider) => Change(provider, true);
  public ProviderHookStatus Remove(string provider) => Change(provider, false);
  private ProviderHookStatus Change(string provider, bool install)
  {
    lock (gate)
    {
      var path = PathFor(provider);
      if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Linked provider settings were left untouched.");
      var before = File.Exists(path) ? BoundedBytes(path) : null;
      var root = before is null || before.Length == 0 ? new JsonObject() : JsonNode.Parse(before, documentOptions: new JsonDocumentOptions { MaxDepth = 48 }) as JsonObject ?? throw new IOException("Provider settings must be a JSON object.");
      if (root["hooks"] is not null && root["hooks"] is not JsonObject) throw new IOException("This provider's hooks are not a JSON object. They were left untouched.");
      var hooks = root["hooks"] as JsonObject ?? new JsonObject();
      if (root["hooks"] is null) root["hooks"] = hooks;
      foreach (var eventName in Events[provider])
      {
        if (hooks[eventName] is not null && hooks[eventName] is not JsonArray) throw new IOException("This provider event is not a hook list. It was left untouched.");
        var groups = hooks[eventName] as JsonArray ?? new JsonArray();
        for (var i = groups.Count - 1; i >= 0; i--)
        {
          if (groups[i] is not JsonObject group || group["hooks"] is not JsonArray entries) continue;
          for (var j = entries.Count - 1; j >= 0; j--)
            if (entries[j] is JsonObject entry && entry["command"] is JsonValue value && value.TryGetValue<string>(out var text) && text.Contains(Marker, StringComparison.Ordinal)) entries.RemoveAt(j);
          if (entries.Count == 0) groups.RemoveAt(i);
        }
        if (install) groups.Add(new JsonObject { ["matcher"] = "*", ["hooks"] = new JsonArray(new JsonObject { ["type"] = "command", ["command"] = command(provider, eventName), ["timeout"] = 5 }) });
        if (groups.Count == 0) hooks.Remove(eventName); else if (hooks[eventName] is null) hooks[eventName] = groups;
      }
      Directory.CreateDirectory(backupDirectory); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
      if (File.Exists(path) && !File.Exists(Backup(provider))) File.Copy(path, Backup(provider), false);
      var output = JsonSerializer.SerializeToUtf8Bytes(root, new JsonSerializerOptions { WriteIndented = true });
      var temp = path + ".td-hook-" + Guid.NewGuid().ToString("N");
      try
      {
        if (before is null ? File.Exists(path) : !File.Exists(path) || !BoundedBytes(path).AsSpan().SequenceEqual(before)) throw new IOException("The provider settings changed while installing hooks. Try again.");
        File.WriteAllBytes(temp, output); File.Move(temp, path, true);
      } finally { if (File.Exists(temp)) File.Delete(temp); }
      return Status(provider);
    }
  }
  private string PathFor(string provider) => Events.ContainsKey(provider) && settingsFiles.TryGetValue(provider, out var path) && Path.IsPathFullyQualified(path) ? path : throw new ArgumentException("Choose a supported coding AI account home.");
  private string Backup(string provider) => Path.Combine(backupDirectory, provider + "-" + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(PathFor(provider))))[..16] + ".settings.before-hooks.json");
  private static byte[] BoundedBytes(string path)
  {
    using var stream = File.OpenRead(path);
    if (stream.Length > 8 * 1024 * 1024) throw new IOException("Provider settings exceed the safe size limit.");
    var bytes = new byte[(int)stream.Length]; stream.ReadExactly(bytes); return bytes;
  }
  private static JsonObject Read(string path)
  {
    if (!File.Exists(path)) return new();
    if (new FileInfo(path).Length > 8 * 1024 * 1024 || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("This provider settings file cannot be edited safely.");
    var bytes = BoundedBytes(path); if (bytes.Length == 0) return new();
    return JsonNode.Parse(bytes, documentOptions: new JsonDocumentOptions { MaxDepth = 48 }) as JsonObject ?? throw new IOException("Provider settings must be a JSON object.");
  }
}
