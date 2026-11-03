using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Store;

namespace TerminalDeck.Platform.Windows;

public sealed partial class CommunityStoreOperations(string root, McpManager mcp, Action<HootRoutine> saveRoutine, Action<string> removeRoutine, string? userHome = null, Func<string, HootRoutine?>? getRoutine = null)
{
  private sealed record Write(string Path, string? Before, string AfterHash, string? Block = null);
  private sealed record Receipt(string Kind, Write[] Writes, string? Registration = null, string[]? Directories = null, string? RegistrationHash = null);
  public async ValueTask<StoreInstallation> InstallAsync(StoreEntry entry, StoreInstallOptions options, HttpClient http, CancellationToken ct)
  {
    var manifest = entry.Manifest ?? throw new IOException("The verified community manifest is missing.");
    var kind = manifest.GetProperty("kind").GetString(); var install = manifest.GetProperty("install");
    var known = manifest.GetProperty("agents").EnumerateArray().Select(a => a.GetString()!).ToArray();
    var agents = (options.Agents ?? known).Distinct().ToArray();
    if (agents.Any(a => a is not ("claude" or "codex" or "gemini") || !known.Contains(a))) throw new ArgumentException("Choose agents supported by this item.");
    if (kind is not ("skill" or "instructions" or "routine" or "mcp")) throw new IOException("This community kind is listed but is not installed by this product.");
    if (kind != "routine" && agents.Length == 0) throw new ArgumentException("Choose at least one supported coding AI.");
    if (kind == "routine" && (options.Folder is null || !Directory.Exists(options.Folder))) throw new ArgumentException("Choose the existing project folder this routine will run in.");
    var token = entry.Id.Replace('/', '.'); if (!Regex.IsMatch(token, "^[a-z0-9.-]{3,90}$")) throw new IOException("Invalid community item identity.");
    var stage = Path.Combine(root, "community", "pending-" + Guid.NewGuid().ToString("N"));
    var writes = new List<Write>(); var directories = new List<string>(); string? registration = null; string? registrationHash = null;
    Receipt? previous = options.PreviousReceipt is { } prior ? JsonSerializer.Deserialize<Receipt>(prior) : null;
    if (previous is not null && previous.Kind != kind) throw new IOException("The item changed kind. Remove the previous installation after reviewing it first.");
    (string Path, byte[] Bytes)[] oldFiles = []; var previousRemoved = false;
    Directory.CreateDirectory(stage);
    try
    {
      string? packageRoot = null;
      if (kind != "mcp")
      {
        var artifact = manifest.GetProperty("artifact"); var address = artifact.GetProperty("url").GetString()!; var expected = artifact.GetProperty("sha256").GetString()!; var limit = artifact.GetProperty("bytes").GetInt64();
        if (limit is < 1 or > 32 * 1024 * 1024 || !Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme != "https" || !string.IsNullOrEmpty(uri.UserInfo)) throw new IOException("The community archive lacks a bounded HTTPS source.");
        using var request = StoreNetwork.Get(uri.AbsoluteUri); using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct); response.EnsureSuccessStatusCode();
        if (response.RequestMessage?.RequestUri?.Scheme != "https" || response.Content.Headers.ContentLength is { } length && length != limit) throw new IOException("The community archive size or address changed.");
        using var data = new MemoryStream(); await using var input = await response.Content.ReadAsStreamAsync(ct); var buffer = new byte[32768];
        while (true) { var count = await input.ReadAsync(buffer, ct); if (count == 0) break; if (data.Length + count > limit) throw new IOException("The archive exceeds its declared size."); data.Write(buffer, 0, count); }
        var bytes = data.ToArray(); if (bytes.Length != limit || !Convert.ToHexStringLower(SHA256.HashData(bytes)).Equals(expected, StringComparison.OrdinalIgnoreCase)) throw new IOException("The community archive fingerprint did not match.");
        await SafeStoreArchive.ExtractAsync(bytes, stage, ct);
        var manifests = Directory.EnumerateFiles(stage, "terminaldeck.json", SearchOption.AllDirectories).Take(2).ToArray(); if (manifests.Length != 1) throw new IOException("The archive must contain one community manifest.");
        if (new FileInfo(manifests[0]).Length > 65536) throw new IOException("The community manifest exceeds 64 KB.");
        var actual = JsonNode.Parse(await File.ReadAllTextAsync(manifests[0], ct))!;
        if (actual["publisher"]?.GetValue<string>() + "/" + actual["id"]?.GetValue<string>() != entry.Id || actual["version"]?.GetValue<string>() != entry.Version || actual["kind"]?.GetValue<string>() != kind || !JsonNode.DeepEquals(actual["install"], JsonNode.Parse(install.GetRawText()))) throw new IOException("The archive manifest does not match the signed catalogue entry.");
        packageRoot = Path.GetDirectoryName(manifests[0]);
      }
      if (options.EnsureCurrent is { } refresh) await refresh(ct);
      // Validate the replacement before removing any earlier, app-owned installation.
      if (previous is not null && kind is "skill" or "instructions")
      {
        oldFiles = previous.Writes.Select(w => (w.Path, File.ReadAllBytes(w.Path))).ToArray();
        await RemoveAsync(entry, options.PreviousReceipt!, ct); previousRemoved = true;
      }
      if (kind == "mcp")
      {
        var runtime = install.GetProperty("runtime").GetString(); var package = install.GetProperty("package").GetString()!;
        if (!Regex.IsMatch(package, "^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]{0,127}(?:@[A-Za-z0-9._-]{1,64})?$")) throw new IOException("The MCP package name is invalid.");
        var values = options.Values ?? []; var environment = new Dictionary<string, string>();
        if (install.TryGetProperty("inputs", out var inputs)) foreach (var field in inputs.EnumerateArray())
        {
          var key = field.GetProperty("key").GetString()!; var required = !field.TryGetProperty("required", out var need) || need.GetBoolean();
          if (!values.TryGetValue(key, out var value)) { if (required) throw new ArgumentException("Fill in " + key + " before installation."); continue; }
          if (value.Length > 4096 || value.Any(char.IsControl)) throw new ArgumentException("Use a single bounded value for " + key + ".");
          if (field.GetProperty("into").GetString() == "env") environment[key] = value;
        }
        var rawArguments = install.GetProperty("args").EnumerateArray().Select(a => a.GetString()!).ToArray();
        var secretKeys = install.GetProperty("inputs").EnumerateArray().Where(f => f.GetProperty("kind").GetString() == "secret" && f.GetProperty("into").GetString() == "arg").Select(f => f.GetProperty("key").GetString()!).ToHashSet(StringComparer.Ordinal);
        var protectedArguments = new Dictionary<int, string>();
        var arguments = rawArguments.Select((argument, index) => Regex.Replace(argument, @"^\$\{input:([A-Z][A-Z0-9_]*)\}$", match =>
        {
          var key = match.Groups[1].Value; var value = values.GetValueOrDefault(key) ?? throw new ArgumentException("Fill in " + key);
          if (secretKeys.Contains(key)) { protectedArguments[index + (runtime == "node" ? 3 : 1)] = value; return "[protected]"; }
          return value;
        })).ToArray();
        string command;
        if (runtime == "node")
        {
          var nodeHomes = new[] { Path.Combine(AppContext.BaseDirectory, "ai"), Path.Combine(AppContext.BaseDirectory, "tools", "staysfixed"), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "nodejs") };
          var nodeHome = nodeHomes.FirstOrDefault(h => File.Exists(Path.Combine(h, "node.exe")) && File.Exists(Path.Combine(h, "node_modules", "npm", "bin", "npx-cli.js"))) ?? throw new IOException("This MCP item needs Node.js with npm. Install Node.js, then retry.");
          command = WindowsCommandLine.Quote(Path.Combine(nodeHome, "node.exe")) + " " + WindowsCommandLine.Quote(Path.Combine(nodeHome, "node_modules", "npm", "bin", "npx-cli.js")) + " --yes " + WindowsCommandLine.Quote(package);
        }
        else if (runtime == "python")
        {
          var paths = (Accounts.WindowsAiEnvironment.Read().GetValueOrDefault("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries).Concat(new[] { Path.Combine(userHome ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin") });
          var uvx = paths.Select(p => Path.Combine(p, "uvx.exe")).FirstOrDefault(File.Exists) ?? throw new IOException("This MCP item needs uv with uvx.exe. Install uv, then retry.");
          command = WindowsCommandLine.Quote(uvx) + " " + WindowsCommandLine.Quote(package);
        }
        else throw new IOException("This MCP runtime is unsupported.");
        command += " " + string.Join(' ', arguments.Select(WindowsCommandLine.Quote));
        var serverName = "td-" + token; if (serverName.Length > 80) serverName = serverName[..80];
        var input = new McpServerInput { Name = serverName, Scope = "user", Transport = "stdio", Command = command, Environment = environment, SecretArguments = protectedArguments };
        if (previous?.Registration is { } existing) { await mcp.EditAsync(existing, input, ct); registration = existing; }
        else { var server = await mcp.AddAsync(input, ct); registration = server.Id; }
      }
      else if (kind == "routine")
      {
        var text = await File.ReadAllTextAsync(Inside(packageRoot!, install.GetProperty("file").GetString()!), ct);
        var interval = Regex.Match(text, @"(?im)^everyMinutes:\s*(\d+)\s*$"); var minutes = interval.Success ? int.Parse(interval.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture) : 1440;
        registration = previous?.Registration ?? Guid.NewGuid().ToString(); var routine = new HootRoutine(registration, entry.Name, entry.Summary, Path.GetFullPath(options.Folder!), minutes, text, Enabled: false);
        saveRoutine(routine); registrationHash = Hash(JsonSerializer.SerializeToUtf8Bytes(routine));
      }
      else foreach (var agent in agents)
      {
        if (options.EnsureCurrent is { } current) await current(ct);
        var home = Path.Combine(userHome ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "." + agent);
        if (kind == "skill")
        {
          var from = install.GetProperty("dir").GetString()!; var source = from == "." ? packageRoot! : Inside(packageRoot!, from);
          if (!File.Exists(Path.Combine(source, "SKILL.md"))) throw new IOException("This skill has no SKILL.md.");
          var target = Path.Combine(home, "skills", token); NoLinks(target); if (Directory.Exists(target) || File.Exists(target)) throw new IOException("A skill already exists at " + target + ".");
          Directory.CreateDirectory(target); directories.Add(target);
          foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories)) WriteFile(Inside(target, Path.GetRelativePath(source, file)), File.ReadAllBytes(file), writes);
        }
        else
        {
          var source = Inside(packageRoot!, install.GetProperty("file").GetString()!); var text = await File.ReadAllTextAsync(source, ct);
          var target = Path.Combine(home, "instructions", token + ".md"); WriteFile(target, Encoding.UTF8.GetBytes(text), writes);
          var memory = Path.Combine(home, agent == "claude" ? "CLAUDE.md" : agent == "codex" ? "AGENTS.md" : "GEMINI.md");
          NoLinks(memory); var before = File.Exists(memory) ? File.ReadAllText(memory) : ""; var marker = "<!-- terminaldeck-store:" + token;
          if (before.Contains(marker, StringComparison.Ordinal)) throw new IOException("These instructions are already linked in " + memory + ".");
          var addition = (before.EndsWith('\n') ? "\n" : "\n\n") + marker + " -->\n" + (agent == "codex" ? "Standing instructions: " + target : "@instructions/" + token + ".md") + "\n<!-- /terminaldeck-store:" + token + " -->\n";
          WriteFile(memory, Encoding.UTF8.GetBytes(before + addition), writes); writes[^1] = writes[^1] with { Block = addition };
        }
      }
      return new(JsonSerializer.Serialize(new Receipt(kind!, writes.ToArray(), registration, directories.ToArray(), registrationHash)), entry.Version);
    }
    catch
    {
      if (registration is not null && previous is null) { if (kind == "mcp") await mcp.RemoveAsync(registration, CancellationToken.None); else if (kind == "routine") removeRoutine(registration); }
      Restore(writes);
      if (previousRemoved) foreach (var old in oldFiles)
      {
        NoLinks(old.Path); var expected = previous!.Writes.Single(w => w.Path == old.Path).Before;
        var current = File.Exists(old.Path) ? File.ReadAllBytes(old.Path) : null;
        if ((expected is null) != (current is null) || expected is not null && !Convert.FromBase64String(expected).AsSpan().SequenceEqual(current)) throw new IOException("A concurrent edit prevents restoring the previous Store version: " + old.Path);
        WriteFile(old.Path, old.Bytes, []);
      }
      foreach (var directory in directories.OrderByDescending(d => d.Length)) if (Directory.Exists(directory))
      { foreach (var child in Directory.EnumerateDirectories(directory, "*", SearchOption.AllDirectories).OrderByDescending(d => d.Length)) if (!Directory.EnumerateFileSystemEntries(child).Any()) Directory.Delete(child); if (!Directory.EnumerateFileSystemEntries(directory).Any()) Directory.Delete(directory); }
      throw;
    }
    finally { Directory.Delete(stage, true); }
  }
  public async ValueTask RemoveAsync(StoreEntry entry, string receipt, CancellationToken ct)
  {
    var saved = JsonSerializer.Deserialize<Receipt>(receipt) ?? throw new IOException("The community receipt is missing.");
    foreach (var write in saved.Writes) { NoLinks(write.Path); if (!File.Exists(write.Path) || Hash(File.ReadAllBytes(write.Path)) != write.AfterHash && (write.Block is null || !File.ReadAllText(write.Path).Contains(write.Block, StringComparison.Ordinal))) throw new IOException("An installed file has been edited. Review it before removal: " + write.Path); }
    if (saved.Kind == "routine" && saved.Registration is { } routineId && getRoutine?.Invoke(routineId) is { } current && saved.RegistrationHash != Hash(JsonSerializer.SerializeToUtf8Bytes(current))) throw new IOException("This routine was edited after installation. Review it before removal.");
    foreach (var directory in saved.Directories ?? [])
    {
      var expected = saved.Writes.Select(w => w.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
      foreach (var file in OwnedFiles(directory)) if (!expected.Contains(file)) throw new IOException("The installed skill contains a new file. Review it before removal: " + file);
    }
    if (saved.Registration is { } id) { if (saved.Kind == "mcp") await mcp.RemoveAsync(id, ct); else if (saved.Kind == "routine") removeRoutine(id); }
    Restore(saved.Writes);
    foreach (var directory in (saved.Directories ?? []).OrderByDescending(d => d.Length)) if (Directory.Exists(directory))
    { NoLinks(directory); foreach (var child in Directory.EnumerateDirectories(directory, "*", SearchOption.AllDirectories).OrderByDescending(d => d.Length)) if (!Directory.EnumerateFileSystemEntries(child).Any()) Directory.Delete(child); if (!Directory.EnumerateFileSystemEntries(directory).Any()) Directory.Delete(directory); }
  }
  private static void Restore(IEnumerable<Write> writes)
  {
    foreach (var write in writes.Reverse())
    {
      NoLinks(write.Path);
      if (File.Exists(write.Path) && Hash(File.ReadAllBytes(write.Path)) != write.AfterHash)
      {
        if (write.Block is { } block) { var text = File.ReadAllText(write.Path); if (text.IndexOf(block, StringComparison.Ordinal) >= 0 && text.IndexOf(block, text.IndexOf(block, StringComparison.Ordinal) + block.Length, StringComparison.Ordinal) < 0) { File.WriteAllText(write.Path, text.Replace(block, "", StringComparison.Ordinal)); continue; } }
        throw new IOException("A concurrent edit prevents rollback: " + write.Path);
      }
      if (write.Before is null) File.Delete(write.Path); else File.WriteAllBytes(write.Path, Convert.FromBase64String(write.Before));
    }
  }
  private static void WriteFile(string path, byte[] bytes, List<Write> writes)
  {
    NoLinks(path); var before = File.Exists(path) ? File.ReadAllBytes(path) : null; if (before?.Length > 2 * 1024 * 1024) throw new IOException("The destination exceeds the safe write limit.");
    Directory.CreateDirectory(Path.GetDirectoryName(path)!); var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
    try { File.WriteAllBytes(temp, bytes); NoLinks(path); if ((File.Exists(path) ? File.ReadAllBytes(path) : null) is { } current && (before is null || !current.AsSpan().SequenceEqual(before))) throw new IOException("The destination changed during installation."); File.Move(temp, path, before is not null); writes.Add(new(path, before is null ? null : Convert.ToBase64String(before), Hash(bytes))); }
    finally { if (File.Exists(temp)) File.Delete(temp); }
  }
  private static IEnumerable<string> OwnedFiles(string directory)
  {
    NoLinks(directory); var pending = new Stack<string>(); pending.Push(directory); var count = 0;
    while (pending.Count > 0) foreach (var entry in Directory.EnumerateFileSystemEntries(pending.Pop()))
    { if (++count > 20000) throw new IOException("The installed tree exceeds its inspection limit."); NoLinks(entry); if (Directory.Exists(entry)) pending.Push(entry); else yield return entry; }
  }
  private static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
  private static string Inside(string rootPath, string relative)
  { if (Path.IsPathRooted(relative) || relative.Replace('\\', '/').Split('/').Any(p => p is "." or "..")) throw new IOException("The item names an unsafe path."); var path = Path.GetFullPath(Path.Combine(rootPath, relative)); if (!path.StartsWith(rootPath.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new IOException("The item names an outside path."); NoLinks(path); return path; }
  private static void NoLinks(string path)
  { for (FileSystemInfo? part = new FileInfo(path); part is not null; part = part is FileInfo file ? file.Directory : ((DirectoryInfo)part).Parent) if (part.Exists && (part.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("A Store destination is linked: " + part.FullName); }
}
