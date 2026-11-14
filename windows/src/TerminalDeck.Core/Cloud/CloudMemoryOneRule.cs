using System.Globalization;
using System.Text;

namespace TerminalDeck.Core.Cloud;

// The Macs' one rule for memory removals and moves (14 Nov 2026), on Windows. Read from the Mac (td lane/mac-next):
// TerminalDeckBackend DeckMemoryStoreOneRule.swift (DeckMemoryRemoval, the "understands" setting, cloudOneRuleSends,
// cloudJournalRemoval, cloudApplyRemoval, cloudAgainstRemoval, the held removals), CloudRemovalBrake.swift (the shared
// 15-minute brake), DeckMemoryStoreDefaultRule.swift + DeckMemoryStoreCloudMerge.cloudShippedSeedHashes (an untouched
// app default never beats his own text).
//
// - A removal or a move travels as an ordinary memory part of the same file: a new version whose bytes are a small
//   removal marker (front matter `td_removed: <ms>`, `td_removed_by`, `td_moved_to` for a move). No new record kind.
// - Every device that keeps memory says it understands these: one shared memory setting per device,
//   `onerule.understands.<device id>` = "v2:<service ms>", rewritten at every start and every 12 hours. A device sends
//   removals only while EVERY such device of the account said so within the last 3 days.
// - One brake: at most 50 files or 5% of the memory (whichever is smaller, at least 1) sent, and applied, per 15 minutes
//   by the Cloud's clock. Removals arriving past it are held, untouched, until the person answers.

/// One removal or move as it travels (DeckMemoryRemoval).
public sealed record CloudMemoryRemoval(long At, string By, string? MovedTo, bool ByAI = false, bool Confirmed = false)
{
  public const string Marker = "td_removed";

  /// The marker file: a complete memory note with its own fresh id, so an older Mac that places it as a note's text
  /// indexes it as it is and never sends it back as an edit.
  public byte[] Text(string id, string name)
  {
    var day = DateTimeOffset.FromUnixTimeMilliseconds(At).ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    var front = new List<string> { "id: " + OneLine(id), "type: removed", "status: removed", Marker + ": " + At.ToString(CultureInfo.InvariantCulture), "td_removed_by: " + OneLine(By) };
    if (!string.IsNullOrWhiteSpace(MovedTo)) front.Add("td_moved_to: " + OneLine(MovedTo));
    if (ByAI) front.Add("td_removed_by_ai: 1");
    if (Confirmed) front.Add("td_removed_confirmed: 1");
    var body = "# Removed: " + OneLine(name) + "\n\n"
      + (MovedTo is null ? "This was removed from your devices on " : "This moved to another place in memory on ") + day
      + ". Terminal Deck keeps the earlier text for 30 days; update Terminal Deck on this device to see it in the Bin.\n";
    return Encoding.UTF8.GetBytes("---\n" + string.Join("\n", front) + "\n---\n" + body);
  }
  private static string OneLine(string text) => text.Replace('\r', ' ').Replace('\n', ' ').Trim();

  /// DeckMemoryRemoval.parse: a marker under 16 KiB, front matter first, `td_removed` a whole number.
  public static CloudMemoryRemoval? Parse(byte[] bytes)
  {
    if (!CloudMemoryFormat.IsRemovalMarker(bytes)) return null;
    var front = FrontMatter.Of(Encoding.UTF8.GetString(bytes)).Values;
    if (!long.TryParse(front.GetValueOrDefault(Marker), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var at)) return null;
    return new(at, front.GetValueOrDefault("td_removed_by") ?? "", front.GetValueOrDefault("td_moved_to"),
      front.GetValueOrDefault("td_removed_by_ai") == "1", front.GetValueOrDefault("td_removed_confirmed") == "1");
  }

  /// A note id in the Mac's shape (`n-<yyyyMMdd>-<6 letters>`), taken from `seed` so a repeated capture makes the same one.
  public static string NoteId(long at, string seed)
  {
    const string letters = "abcdefghijklmnopqrstuvwxyz0123456789";
    var hash = CloudMemoryFormat.Hash(Encoding.UTF8.GetBytes(seed));
    var id = new StringBuilder();
    for (var i = 0; i < 6; i++) id.Append(letters[Convert.ToInt32(hash.Substring(i * 2, 2), 16) % letters.Length]);
    return "n-" + DateTimeOffset.FromUnixTimeMilliseconds(at).ToLocalTime().ToString("yyyyMMdd", CultureInfo.InvariantCulture) + "-" + id;
  }
}

/// The front matter of a memory note (DeckMemoryFile): the lines between a first `---` and the next one.
public sealed record FrontMatter(IReadOnlyDictionary<string, string> Values, string Body)
{
  public static FrontMatter Of(string text)
  {
    var lines = text.Split('\n');
    var values = new Dictionary<string, string>(StringComparer.Ordinal);
    if (!text.StartsWith("---", StringComparison.Ordinal) || lines[0].Trim() != "---") return new(values, text);
    var end = Array.FindIndex(lines, 1, l => l.Trim() == "---");
    if (end < 0) return new(values, text);
    for (var i = 1; i < end; i++)
    {
      var line = lines[i];
      var colon = line.IndexOf(':');
      if (colon <= 0 || line[0] is ' ' or '\t') continue;
      var key = line[..colon].Trim();
      if (key.Length == 0 || values.ContainsKey(key)) continue;
      var value = line[(colon + 1)..].Trim();
      if (value.Length >= 2 && (value[0] == '"' && value[^1] == '"' || value[0] == '\'' && value[^1] == '\'')) value = value[1..^1];
      if (value.Length > 0) values[key] = value;
    }
    return new(values, string.Join("\n", lines[(end + 1)..]));
  }
}

public static class CloudMemoryOneRule
{
  /// The format of the removal, move and cleanup records this build understands (the Mac's phase 2).
  public const int Format = 2;
  public const long FreshFor = 3 * 86_400_000L, RenewAfter = 12 * 3_600_000L, AheadAllowed = 3_600_000L;
  /// The shared brake (CloudRemovalBrake): its window and its limit.
  public const long Window = 15 * 60_000L;
  public static int Limit(int total) => Math.Max(1, Math.Min(50, total * 5 / 100));
  public static (long At, int Count) Current(long? at, int count, long now) => at is { } a && now >= a && now - a < Window ? (a, count) : (now, 0);

  public static string UnderstandsKey(string deviceId) => DeckMemoryCloudSchema.SharedSettingPrefix + deviceId.ToLowerInvariant();
  public static string UnderstandsValue(long at) => "v" + Format.ToString(CultureInfo.InvariantCulture) + ":" + at.ToString(CultureInfo.InvariantCulture);
  public static (int Format, long At)? ParseUnderstands(string? raw)
  {
    if (raw is null || !raw.StartsWith('v') || Encoding.UTF8.GetByteCount(raw) >= 40) return null;
    var colon = raw.IndexOf(':');
    if (colon <= 1) return null;
    if (!int.TryParse(raw[1..colon], NumberStyles.None, CultureInfo.InvariantCulture, out var format)
      || !long.TryParse(raw[(colon + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out var at) || format <= 0 || at <= 0) return null;
    return (format, at);
  }
  /// Counts only when it is this format or newer, renewed within the last 3 days, and not from the future.
  public static bool Fresh(string? raw, long now) =>
    ParseUnderstands(raw) is { } v && v.Format >= Format && v.At <= now + AheadAllowed && now - v.At <= FreshFor;
}

/// What the one rule needs from the app. `AccountDevices`: the account's devices that keep a copy of memory (active,
/// never a phone or a browser, not replaced by a newer sign-in of the same machine), lower-case ids; null while not
/// known (then nothing is sent). `Safety`: where this PC's safety copy of its memory goes.
public sealed record CloudMemoryOneRulePorts(Func<IReadOnlyCollection<string>?> AccountDevices, ICloudMemorySafety Safety);

/// The safety copy (the Mac's `memory-safety/<yyyyMMdd-HHmmss>`): one whole copy of this PC's memory, made before the
/// first removal is applied or sent. Returns where it is, or null when it could not be made (nothing is removed then).
public interface ICloudMemorySafety
{
  string? Make(long at);
  bool Exists(string made);
}

/// Safety copies in memory (tests): `Made` holds what was copied.
public sealed class CloudMemorySafetyInMemory(IDeckMemoryCloudStore memory) : ICloudMemorySafety
{
  public readonly List<IReadOnlyDictionary<string, byte[]>> Made = [];
  public bool Fails { get; set; }
  public string? Make(long at)
  {
    if (Fails) return null;
    Made.Add(memory.ListFiles().ToDictionary(f => f.Path, f => memory.ReadFile(f.Path) ?? [], StringComparer.Ordinal));
    return "safety/" + Made.Count;
  }
  public bool Exists(string made) => !Fails && made.StartsWith("safety/", StringComparison.Ordinal);
}

/// Safety copies on disk: `<account folder>\memory-safety\<yyyyMMdd-HHmmss>\` holds a copy of the whole memory folder
/// (notes, labels, store id). Outside the memory folder: never sent, never read as memory. Never removed by sync.
public sealed class CloudMemorySafetyFolder(string accountFolder) : ICloudMemorySafety
{
  public string? Make(long at)
  {
    try
    {
      var source = new DirectoryInfo(Path.Combine(accountFolder, "memory"));
      var root = Path.Combine(accountFolder, "memory-safety");
      var stamp = DateTimeOffset.FromUnixTimeMilliseconds(at).ToLocalTime();
      var target = Path.Combine(root, stamp.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture));
      // Named per second; one second later on a clash.
      while (Directory.Exists(target)) { stamp = stamp.AddSeconds(1); target = Path.Combine(root, stamp.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture)); }
      var partial = target + ".partial";
      if (Directory.Exists(partial)) Directory.Delete(partial, recursive: true);
      Directory.CreateDirectory(partial);
      if (source.Exists) Copy(source, partial);
      Directory.Move(partial, target);
      return target;
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
  }
  private static void Copy(DirectoryInfo from, string to)
  {
    foreach (var item in from.EnumerateFileSystemInfos())
    {
      if (item.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
      var target = Path.Combine(to, item.Name);
      if (item is DirectoryInfo folder) { Directory.CreateDirectory(target); Copy(folder, target); }
      else if (item is FileInfo file) file.CopyTo(target, overwrite: false);
    }
  }
  public bool Exists(string made) => Directory.Exists(made);
}

/// His own text beats an untouched app default (the Mac's cloudDefaultRule): between two texts of one file that are not
/// built on each other, a text the app ships on its own at that place never beats a text that is not one. "Shipped" is
/// the Mac's own list (cloudShippedSeedHashes): template cards (every shipped version), checklists and settings, a seat's
/// starter card and the starter playbook. Windows itself writes none of them.
public static class CloudMemoryDefaults
{
  /// true = `first` is used, false = `second` is used, null = this rule does not decide.
  public static bool? Decide(string path, string first, string second, Func<string, string?> seatTitle)
  {
    if (first == second) return null;
    var shipped = Hashes(path, seatTitle);
    return (shipped.Contains(first), shipped.Contains(second)) switch { (true, false) => false, (false, true) => true, _ => null };
  }

  public static IReadOnlySet<string> Hashes(string path, Func<string, string?> seatTitle) =>
    Texts(path, seatTitle).Select(t => CloudMemoryFormat.Hash(Encoding.UTF8.GetBytes(t))).ToHashSet(StringComparer.Ordinal);

  private static readonly string[] Categories = ["orchestrator", "lead", "agent"];
  private static readonly string[] Parts = ["card", "notes", "diary", "topics", "playbook", "board", "helper"];

  public static IReadOnlyList<string> Texts(string path, Func<string, string?> seatTitle)
  {
    var parts = path.Split('/');
    if (parts.Length == 3 && parts[0] == "templates" && Categories.Contains(parts[1]))
      return parts[2] switch
      {
        "card.md" => [Card(parts[1], 3), Card(parts[1], 1), Card(parts[1], 2)],
        "checklist.md" => [TemplateChecklist, FlowChecklist],
        "settings.md" => [Settings(parts[1], before28Oct: false), Settings(parts[1], before28Oct: true)],
        _ => []
      };
    if (Owner(path) is not { } owner) return [];
    var (key, kind, id) = owner;
    if (parts[^1] == "playbook.md") return kind is "hoot" or "lead" ? [Playbook] : [];
    var texts = new List<string> { Starter(kind, id, "") };
    if (seatTitle(key) is { } title) texts.Add(Starter(kind, id, title));
    return texts;
  }

  /// The owner of a seat's own `card.md` or `playbook.md` (DeckMemoryFiles.classify): its key, its kind and its id.
  private static (string Key, string Kind, string Id)? Owner(string path)
  {
    var p = path.Split('/');
    if (p[^1] is not ("card.md" or "playbook.md")) return null;
    static bool Plain(string s) => s.Length > 0 && !s.StartsWith('.') && s == s.Trim() && !s.Any(c => c is '/' or ':' or '\\' || c < 32 || c == 127);
    return p switch
    {
      ["hoot", _] => ("hoot", "hoot", ""),
      ["roles", var r, _] when Plain(r) => ("role:" + r, "role", r),
      ["projects", var id, _] when Plain(id) => ("project:" + id, "project", id),
      ["projects", var id, "lead", _] when Plain(id) => ("lead:" + id, "lead", id),
      ["projects", var id, "roles", var r, _] when Plain(id) && Plain(r) => ("role:" + id + "/" + r, "role", r),
      _ => null
    };
  }

  private static string Starter(string kind, string id, string name) => kind switch
  {
    "hoot" => "# Hoot\n\n## Top rules\n\n## The person\n\n## Projects (one line each)\n\n## Permissions\n",
    "project" => "# " + (name.Length == 0 ? id : name) + "\n\n## Top rules\n\n## What it is\n\n## Where things are\n",
    "lead" => "# " + (name.Length == 0 ? "Lead of " + id : name) + "\n\n## Top rules\n\n## What this seat is for\n\n## Permissions\n",
    _ => "# " + (name.Length == 0 ? id : name) + "\n\n## Top rules\n\n## What this seat is for\n"
  };

  public const string Playbook = "# Playbook\n\nFor each kind of job: which AI, model, effort and permission to start the session with, and what it is always told. Edit the table; the app reads it as it is. The row called \"default\" is used when no other row fits.\n"
    + "\n| Job | AI | Model | Effort | Permission | Standing instructions |\n|---|---|---|---|---|---|\n| default |  |  |  |  |  |\n";

  private static string Card(string category, int version)
  {
    const string rules = "## Top rules\n- Memory lives in the app, not in this chat. Trust your card, your topics, your notes and the board over your own recollection.\n- Exact facts (which build is installed, did it ship) are checked at the source, never from memory.\n";
    var call = version >= 2 ? "- To use a memory tool: look it up with tools_describe (it shows the tool's arguments), then call it with tools_run.\n" : "";
    var several = version >= 3 ? "- When a question needs several facts, search once for each fact.\n" : "";
    var memory = "## How to use memory\n" + call + several + "- Search before you assume: memory.search covers notes, topics, cards and the diary of every message.\n- Keep one \"where we are\" topic per open piece of work (memory.topic.update), so a clean desk can carry on.\n- Write a short note (memory.note.add) for a decision, a preference, a correction, a result, an open item or a lesson. A newer note replaces an older one; nothing is deleted.\n";
    const string report = "Done or not · the result in three lines · the proof · what you need. Long output stays in the session.\n";
    return category switch
    {
      "orchestrator" => "# Orchestrator\n\nYou are the orchestrator. You talk with the person, give project leads their goals and read their reports. You assign agents yourself only in projects that have no lead.\n\n" + rules + "\n" + memory + "- Follow the playbook whenever you start or steer a session.\n\n## What you expect back from leads and agents\n" + report,
      "lead" => "# Lead\n\nYou are the lead of a project. The orchestrator gives you goals; you run this project's agents and report back. The seat's memory was built by whoever held it before you and stays for whoever comes next.\n\n" + rules + "\n" + memory + "- Follow the playbook whenever you start or steer a session.\n\n## How you report\n" + report,
      _ => "# Agent\n\nYou hold a role (a seat). The seat's memory was built by whoever held it before you and stays for whoever comes next. Remember the why; read the files for the what.\n\n" + rules + "\n" + memory + "\n## How you report\n" + report
    };
  }

  private static string Settings(string category, bool before28Oct)
  {
    var parts = Parts.Where(p => category != "agent" || p != "playbook").ToList();
    if (before28Oct) parts.Insert(parts.IndexOf("helper"), "refresh");
    var everyone = category switch { "orchestrator" => "the Orchestrator", "lead" => "all Leads", _ => "all Agents" };
    var (seat, project) = category == "agent" ? (3, 12) : (1, 1);
    return "# Settings for " + everyone + "\n\nThese apply to every member of this category, now and for every future hire. Change the value after the colon.\n\n- parts: " + string.Join(", ", parts) + "\n"
      + (before28Oct ? "- refresh at: 0.5\n" : "")
      + "- helper ai: claude\n- helper model: sonnet\n- card limit: 6000\n- hands per seat: " + seat.ToString(CultureInfo.InvariantCulture)
      + "\n- hands per project: " + project.ToString(CultureInfo.InvariantCulture) + "\n";
  }

  private const string TemplateChecklist = "# What the helper looks for\n\nAfter a turn the helper reads only the new part of the diary and writes short dated notes. When unsure, it keeps the note.\n\n- A decision the person made, and why.\n- A preference or a standing rule the person stated.\n- A correction: something that was done wrong and what is right.\n- A result: what was finished, with where the proof is.\n- An open item: something asked for and not done yet.\n- A lesson: something that will matter the next time this kind of job comes up.\n";

  private const string FlowChecklist = "# What the note helper writes down\n\nEdit this list freely: it is read again before every run.\n\n## Write a note when the new text contains\n"
    + "1. A correction from the person (highest priority; quote their words).\n2. A stated preference or standing rule from the person.\n3. A decision, with the reason and what it replaced.\n"
    + "4. A result: what now works or exists, where, and its state word (attempted / reported / verified). Never raise the state yourself.\n5. An open item: who is waiting for what.\n"
    + "6. A lesson: a trap, its cause, how to avoid it.\n7. A how-to: how to run, test, build or release this project, once it has worked.\n\n## How to write it\n"
    + "- One fact per note, 15 to 80 words, understandable alone. No \"it\", \"he\", \"that file\".\n- Exact names, numbers, versions, paths that will still exist. Never round or generalise.\n"
    + "- Dates in full. Work them out from the date stamped on the message, not from today.\n- For a change: from what, to what, why.\n- Say who: \"the person said\", \"Hoot proposed\", \"the agent did\".\n"
    + "- State the fact, not that it was discussed.\n- Use only what the new text says. Do not borrow details from the older notes shown to you.\n"
    + "- A plan with a deadline is true from the day it was said; keep the deadline in the sentence.\n\n## Do not write a note for\n"
    + "- Anything a search of the diary or a look at the files answers just as well: routine steps, listings, installs, status checks.\n- Line numbers, exact error text, temporary paths, ports, commit ids.\n"
    + "- A proposal nobody accepted.\n- The same outcome confirmed again. Once is enough.\n- The AI repeating back what the person said.\n- A preference guessed from one passing remark.\n"
    + "- Passwords, keys, tokens, ever.\n\n## When unsure\n- About something the person said (a correction, a preference, a decision): write the note.\n- About routine work detail: skip it, the diary has it.\n\n"
    + "## Corrections from you\n(When you tell the app \"you should have noted X\", it is added here.)\n";
}
