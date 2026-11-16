using System.Text.RegularExpressions;
using TerminalDeck.Core.Code;

namespace TerminalDeck.Core.Cloud;

// His MCP servers travel with saved passwords (the Mac's BackendCloudSecretsMCPStore.travelling + BackendCloudSecretsClaudeMCP,
// with review fixes 1-4 of 15 Nov). "User scope" = Claude Code's own list in `.claude.json` (CLAUDE_CONFIG_DIR, else his
// user folder). This app never writes that file: a server is added only through Claude Code's own command
// `claude mcp add-json --scope user -- <name> <json>` (add-only) and removed through `claude mcp remove --scope user -- <name>`
// (compare-and-remove). A server whose program is not on this PC is still listed and shows its normal "cannot start".
// Rules kept from the Mac:
// - The definition (with its env/header values) travels; the sending device's name rides beside it, never part of "the same".
// - Same server under the same name: one. The same server under another name here: one (kept both, never remembered as
//   present). A different one under the same name: his stays, the other is added beside it as "<name>-<device>".
// - Unchanged here since the last exchange: the newer one replaces it in place (remove, then add; his previous one goes
//   back if the add fails).
// - A missing settings file, an unreadable or invalid one, or two or more known servers gone with an empty list:
//   "cannot tell", nothing is judged. Exactly one gone (even his last) is a removal: an AI's own `claude mcp remove`
//   = everywhere, else his hand = not on this PC.

/// An AI's own `claude mcp remove <name>` (user scope, or no scope given), the only thing that names one MCP server for
/// the AI delete witness: a stand-in path, never a real file (the Mac's BackendAIDeleteWitness.mcpRemoved/mcpUserServerPath).
public static partial class CloudMcpRemoveCommand
{
  public static string StandInPath(string name) => "/.terminal-deck-mcp-servers/user/" + name;
  [GeneratedRegex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")] internal static partial Regex NamePattern();
  public static bool IsClaude(string verb) => verb is "claude" or "claude.exe" or "claude.cmd";
  /// The arguments after `claude` (text, unreadable-from-the-text, glob). null unless it is exactly that command.
  public static string? Removed(IReadOnlyList<(string Text, bool Dynamic, bool Glob)> args)
  {
    if (args.Count < 3 || args[0].Text != "mcp" || args[1].Text != "remove") return null;
    string? scope = null; (string Text, bool Dynamic, bool Glob)? name = null;
    for (var i = 2; i < args.Count; i++)
    {
      var word = args[i];
      if (word.Text == "--") { if (i + 1 < args.Count) name = args[i + 1]; break; }
      if (word.Text is "-s" or "--scope") { scope = i + 1 < args.Count ? args[i + 1].Text : null; i++; continue; }
      if (word.Text.StartsWith("--scope=", StringComparison.Ordinal)) { scope = word.Text[8..]; continue; }
      if (word.Text.StartsWith('-')) continue;
      name = word; break;
    }
    if (name is not { } n || n.Dynamic || n.Glob || scope is not (null or "user") || !NamePattern().IsMatch(n.Text)) return null;
    return n.Text;
  }
}

/// Claude Code's user-scope MCP list on this PC: read only, changed only through `claude mcp`.
public sealed class ClaudeMcpUserList(Func<string> claudeJsonPath, ICodeProcessRunner runner, string workingDirectory)
{
  public const long MaximumConfigBytes = 64L * 1024 * 1024;
  /// Fields Claude Code keeps for a server. Others are dropped by its schema.
  private static readonly HashSet<string> KnownFields = ["type", "command", "args", "env", "url", "headers", "headersHelper", "oauth", "timeout", "cwd"];
  public string Path => claudeJsonPath();
  /// The list, or null when the settings file is missing. Unreadable or invalid: throws (never "everything removed").
  public CloudJson.Object? Read()
  {
    var file = new FileInfo(Path);
    if (!file.Exists) return null;
    if (file.Length > MaximumConfigBytes) throw new CloudFailure("invalid_request");
    if (CloudJson.Parse(File.ReadAllBytes(file.FullName)) is not CloudJson.Object root) throw new CloudFailure("invalid_request");
    return root["mcpServers"] switch
    {
      null => new CloudJson.Object([]),
      CloudJson.Object list => list,
      _ => throw new CloudFailure("invalid_request")
    };
  }
  public CloudJson.Object Definitions() => Read() ?? new CloudJson.Object([]);
  public static bool Acceptable(string name) => CloudMcpRemoveCommand.NamePattern().IsMatch(name);
  /// Whether `stored` (as Claude Code saved it) is this definition: every saved field equals the given one, except
  /// defaults Claude may add (a `type`, or an empty list, object or text), and every field Claude knows was saved.
  public static bool Matches(CloudJson? stored, CloudJson incoming)
  {
    if (stored is not CloudJson.Object saved || incoming is not CloudJson.Object given) return false;
    var byKey = new Dictionary<string, CloudJson>(StringComparer.Ordinal);
    foreach (var m in given.Members) byKey.TryAdd(m.Key, m.Value);
    foreach (var field in saved.Members)
    {
      if (byKey.TryGetValue(field.Key, out var value))
      {
        if (!CloudCanonical.Encode(field.Value).AsSpan().SequenceEqual(CloudCanonical.Encode(value))) return false;
      }
      else if (field.Key != "type" && !EmptyDefault(field.Value)) return false;
    }
    var savedKeys = saved.Members.Select(m => m.Key).ToHashSet(StringComparer.Ordinal);
    return given.Members.All(m => savedKeys.Contains(m.Key) || !KnownFields.Contains(m.Key));
  }
  private static bool EmptyDefault(CloudJson value) => value switch
  {
    CloudJson.Array a => a.Items.Count == 0,
    CloudJson.Object o => o.Members.Count == 0,
    CloudJson.String s => s.Value.Length == 0,
    CloudJson.Null => true,
    _ => false
  };
  private Task<CodeProcessResult> RunAsync(IReadOnlyList<string> arguments) => runner.RunAsync("claude", arguments, workingDirectory, TimeSpan.FromSeconds(30), CancellationToken.None);
  /// Add-only: an existing name is never replaced (a different one stays; the other stays sealed in Cloud).
  public async Task<CloudApplyStatus> AddAsync(string name, CloudJson definition)
  {
    if (definition is not CloudJson.Object) throw new CloudFailure("invalid_request");
    var before = Definitions()[name];
    if (before is not null) return Matches(before, definition) ? CloudApplyStatus.AlreadyPresent : CloudApplyStatus.KeptBoth;
    // A name that could be read as an option waits (it stays saved in Cloud).
    if (!Acceptable(name)) throw new CloudFailure("unavailable");
    var json = System.Text.Encoding.UTF8.GetString(CloudCanonical.Encode(definition));
    var output = await RunAsync(["mcp", "add-json", "--scope", "user", "--", name, json]);
    var after = Definitions()[name];
    if (after is not null)
    {
      if (Matches(after, definition)) return output.Ok ? CloudApplyStatus.Applied : CloudApplyStatus.AlreadyPresent;
      return CloudApplyStatus.KeptBoth; // Something else saved this name meanwhile; ours stays sealed.
    }
    // Claude Code missing or refusing: the item waits (its words are never passed on: they can echo a value).
    throw new CloudFailure("unavailable");
  }
  /// The same writer as a person's MCP Remove. No token or definition is passed on the removal command line.
  public async Task<bool> RemoveAsync(string name, CloudJson definition)
  {
    if (!Acceptable(name)) throw new CloudFailure("invalid_request");
    var before = Definitions()[name];
    if (before is null) return true;
    if (!Matches(before, definition)) return false;
    var result = await RunAsync(["mcp", "remove", "--scope", "user", "--", name]);
    if (!result.Ok) throw new CloudFailure("unavailable");
    return Definitions()[name] is null;
  }
}

/// Source `mcp-user`, domain mcp: one record per server name; value { definition, from? }.
public sealed class CloudKeysMcpStore(ClaudeMcpUserList claude, Func<string?> thisDevice, string sourceId = "mcp-user") : ICloudSecretsStore, ICloudSecretsFileFound
{
  public string SourceId => sourceId;
  public string InventoryRow => "I16";
  public string Domain => CloudSecretsDomains.Mcp;
  private CloudSecretsDeleteOwner? exchanged;

  private CloudSecretRecord Record(string name, CloudJson definition, string? from) =>
    new(SourceId, name, Domain, CloudJson.Obj(("definition", definition), ("from", from is { } f ? CloudJson.From(f) : null)));
  /// (definition, from) of a record, strictly as the Mac decodes it.
  public static (CloudJson Definition, string? From) Value(CloudSecretRecord record, string sourceId)
  {
    if (record.SourceId != sourceId || record.Domain != CloudSecretsDomains.Mcp || record.RecordId.Length == 0 || System.Text.Encoding.UTF8.GetByteCount(record.RecordId) > 512
      || record.RecordId.Any(c => c is '\n' or '\r' or '\u0085' or '\u2028' or '\u2029') || record.Payload is not CloudJson.Object o
      || o.Members.Any(m => m.Key is not ("definition" or "from")) || o["definition"] is not CloudJson.Object definition) throw new CloudFailure("invalid_request");
    var from = CloudFields.OptionalText(o, "from");
    if (o["from"] is CloudJson.Null || CloudKeysTravel.Length(from ?? "") > 128) throw new CloudFailure("invalid_request");
    return (definition, from);
  }
  private CloudJson? Definition(CloudSecretRecord? record) { if (record is null) return null; try { return Value(record, SourceId).Definition; } catch (Exception) { return null; } }

  public async Task<IReadOnlyList<CloudSecretRecord>> CaptureAsync() => (await CaptureReadAsync()).Records;
  /// The capture plus whether the settings file was there (false = missing: nobody can tell what went). An unreadable
  /// or invalid file throws.
  public Task<(IReadOnlyList<CloudSecretRecord> Records, bool? FileFound)> CaptureReadAsync()
  {
    var device = thisDevice();
    if (claude.Read() is not { } all) return Task.FromResult<(IReadOnlyList<CloudSecretRecord>, bool?)>(([], false));
    var output = new List<CloudSecretRecord>();
    foreach (var field in all.Members)
    {
      // Still the server last exchanged for this name: that very record again (no echo).
      if (exchanged?.LastExchanged(field.Key) is { } last && Definition(last) is { } before && ClaudeMcpUserList.Matches(field.Value, before)) { output.Add(last); continue; }
      output.Add(Record(field.Key, field.Value, device));
    }
    return Task.FromResult<(IReadOnlyList<CloudSecretRecord>, bool?)>((output, true));
  }
  public Task ValidateAsync(CloudSecretRecord record) { _ = Value(record, SourceId); return Task.CompletedTask; }
  /// The copy's name for a different server under the same name: "<name>-<other device>" (the MCP name rule holds).
  public static string ApartName(string name, string? from)
  {
    var suffix = "-" + CloudKeysTravel.Slug(from);
    return name[..Math.Min(name.Length, Math.Max(1, 64 - suffix.Length))] + suffix;
  }
  private static async Task<T> Owned<T>(Func<Task<T>> step)
  {
    try { return await step(); } catch (Exception) { throw new CloudFailure("unavailable"); }
  }
  public async Task<CloudApplyStatus> MergeAsync(CloudSecretRecord record)
  {
    var (incoming, from) = Value(record, SourceId);
    var all = claude.Definitions();
    var local = all[record.RecordId];
    if (local is not null && ClaudeMcpUserList.Matches(local, incoming)) return CloudApplyStatus.AlreadyPresent;
    // The same server under another name here (a copy made earlier, or his own): one server. Kept both, so this name is
    // not taken as one this PC has (a later look must never read it as removed here).
    if (all.Members.Any(m => ClaudeMcpUserList.Matches(m.Value, incoming))) return CloudApplyStatus.KeptBoth;
    if (local is null) return await Owned(() => claude.AddAsync(record.RecordId, incoming));
    // Unchanged here since the last server exchanged for this name: the newer one replaces it in place. Both changed:
    // his stays and the other is added beside it.
    if (Definition(exchanged?.LastExchanged(record.RecordId)) is { } before && ClaudeMcpUserList.Matches(local, before))
    {
      if (await Owned(() => claude.RemoveAsync(record.RecordId, before)))
      {
        try { return await claude.AddAsync(record.RecordId, incoming); }
        catch (Exception)
        {
          // The new one could not be added: his previous one goes back, nothing is lost.
          try { await claude.AddAsync(record.RecordId, before); } catch (Exception) { }
          throw new CloudFailure("unavailable");
        }
      }
    }
    var copy = ApartName(record.RecordId, from);
    if (all[copy] is { } existing) return ClaudeMcpUserList.Matches(existing, incoming) ? CloudApplyStatus.AlreadyPresent : CloudApplyStatus.KeptBoth;
    await Owned(() => claude.AddAsync(copy, incoming));
    return CloudApplyStatus.KeptBoth;
  }
  public Task<bool> VerifyAsync(CloudSecretRecord record, CloudApplyStatus outcome)
  {
    var (incoming, _) = Value(record, SourceId);
    var all = claude.Definitions();
    if (outcome == CloudApplyStatus.KeptBoth && all[record.RecordId] is not null) return Task.FromResult(true);
    return Task.FromResult(all.Members.Any(m => ClaudeMcpUserList.Matches(m.Value, incoming)));
  }
  /// Put back: added only when the name is free here.
  public async Task<CloudApplyStatus> RestoreAsync(CloudSecretRecord record)
  {
    var (expected, _) = Value(record, SourceId);
    if (claude.Definitions()[record.RecordId] is { } current) return ClaudeMcpUserList.Matches(current, expected) ? CloudApplyStatus.AlreadyPresent : CloudApplyStatus.KeptBoth;
    return await Owned(() => claude.AddAsync(record.RecordId, expected));
  }
  public async Task<bool> RemoveAsync(CloudSecretRecord record)
  {
    var (expected, _) = Value(record, SourceId);
    var current = claude.Definitions()[record.RecordId];
    if (current is null) return true;
    if (!ClaudeMcpUserList.Matches(current, expected)) return false;
    return await Owned(() => claude.RemoveAsync(record.RecordId, expected));
  }
  /// The definition alone decides "the same removed server" (the sending device's name rides beside it).
  public static bool SameValue(CloudSecretRecord one, CloudSecretRecord other)
  {
    if (one.RecordId != other.RecordId) return false;
    try { return CloudCanonical.Encode(Value(one, one.SourceId).Definition).AsSpan().SequenceEqual(CloudCanonical.Encode(Value(other, other.SourceId).Definition)); }
    catch (Exception) { return false; }
  }
  /// This store under the saved passwords' delete rule. `vanished`: who removed a server outside the app (the AI
  /// witness asked for the server's stand-in path only).
  public CloudSecretsDeleteOwner DeleteRuleOwner(string stateRoot, Func<bool> gate, Func<string, string?>? deviceName = null, Func<long?>? serviceClock = null,
    CloudSecretsVanished? vanished = null, Func<long>? now = null)
  {
    var made = new CloudSecretsDeleteOwner(this, stateRoot, gate, r => r.RecordId, RemoveAsync, RestoreAsync, deviceName, serviceClock, now, SameValue, vanished);
    exchanged = made;
    return made;
  }
  /// The vanished witness for this store: an AI session's own `claude mcp remove <name>` = everywhere; else his hand.
  public static CloudSecretsVanished Witness(ICloudDeleteWitness witness, Func<string?> device, Func<string> deviceName) => new(
    (id, seen, gone) => witness.WhoAsync(CloudMcpRemoveCommand.StandInPath(id), DateTimeOffset.FromUnixTimeMilliseconds(seen), DateTimeOffset.FromUnixTimeMilliseconds(gone)),
    device, deviceName);
}
