using System.Collections.Immutable;
using System.Text.Json;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Cloud;

// The AGENTS and their instruction text (row I10, domain `agents`), the Mac's BackendCloudLeanAgents.swift on Windows.
// - Travels: the signed field list only (name, role, preferred and avoided tools, model, effort, icon, reports-to, and
//   the widening fields); the instruction text as its own record `instruction:<agent id>.md`.
// - Never sent: this PC's account (login), every path (instruction file, picture, working folder), and every field not on
//   the signed list. A Windows agent is written in the Mac's row shape (`role`, `provider`, `permissionMode` …).
// - Widening fields (the AI, permission mode, tool lists, skills, run limits, status, project, seat) apply from another
//   device only under automatic trust (Windows: "Automatically, with my account", the default); otherwise only an equal
//   or narrower value applies and the rest waits, listed.
// - The delete rule (lane D2, the Mac's 87941cff8 BackendCloudLeanAgents): an agent deleted in the app, or by an AI, goes
//   into the Bin on every device for 30 days with its instruction text (agents are always "Everywhere"); an edit made on
//   top of a removal wins by ancestry and brings it back. An instruction file gone by hand is "Not on this PC" (never
//   sent, never put back by sync); gone by an AI in a Terminal Deck session (the witness) it goes into every Bin. A
//   missing instructions folder is never a delete.
// - Names that would capture mentions meant for someone else (hoot, me, another agent) are refused.
// - Nothing from the Cloud starts work: an arrival is one save, no run, no session.
// - Values this PC cannot hold (a Mac's run limits, blocked tools …) are kept here exactly as they came and travel
//   back unchanged, so an edit here never overwrites them on the Macs.
public sealed class CloudAgentsOwner : ICloudRecordOwner, ICloudDeleteOwning
{
  public const string DomainName = "agents", InventoryRowName = "I10", SourceIdName = "task-config-agents";
  /// An agent's instruction text: `instruction:<agent id>.md`.
  public static readonly CloudMergeTable InstructionTable = CloudMergeTablesV2.Instruction;
  public static readonly CloudRecordKind InstructionKind = new("instruction:", InstructionTable, ".md");
  /// An agent row; it is applied only after its instruction record has arrived here.
  public static readonly CloudRecordKind AgentKind = new("agent:", CloudMergeTablesV2.Agent, "", new HashSet<string>(StringComparer.Ordinal) { "name", "model", "effort" },
    id => "instruction:" + id + ".md");
  /// Instruction records first: within one moment an agent's text is sent before the agent.
  public static readonly IReadOnlyList<CloudRecordKind> Kinds = [InstructionKind, AgentKind];
  public static readonly IReadOnlyList<string> Exclusions =
  [
    "Each agent's login, permissions, tools, skills and run limits are set on each device; with \"Ask me for each new device\" a wider value from another device waits on this PC.",
    "Agent pictures, working folders and instruction file locations stay on this PC.",
  ];
  public static readonly string[] SharedFields = ["role", "toolsPreferred", "toolsAvoided", "model", "effort", "icon", "reportsTo"];
  public static readonly string[] WideningFields = ["provider", "permissionMode", "allowedTools", "blockedTools", "skillsOff", "toolUseRestrictions", "claudeAgent", "skills",
    "maxConcurrent", "maxRunMinutes", "keepAliveMinutes", "keepAliveUntilClose", "status", "projectId", "seat"];
  /// Names that route mentions to the person or to Hoot.
  public static readonly string[] ReservedNames = ["hoot", "me"];
  public const string WaitingReason = "Set on another device. It can widen what this agent may do, so it is not applied here; set it on this PC if you want it.";
  public const string FolderGone = "Your agent instructions folder is not on this PC";
  public const string FollowsRemoval = "These instructions follow their agent's removal.";
  public const string ProjectNotHere = "This agent waits for its project, which is not on this PC yet. It is added with its project and seat when that project is here.";
  public const string NotHeldHere = "This PC cannot hold this value; it stays as it is on your other devices.";

  private sealed class Ledger
  {
    /// Every name each agent has had on this PC, lower-cased.
    public Dictionary<string, List<string>> Names { get; set; } = [];
    /// The last value the Cloud gave each agent: fields this PC cannot hold travel back from here unchanged.
    public Dictionary<string, string> Carried { get; set; } = [];
    /// The status this PC last saw for each agent and when it saw it change (the Mac's `statusAt`).
    public Dictionary<string, string> Status { get; set; } = [];
    public Dictionary<string, long> StatusAt { get; set; } = [];
  }

  private readonly IAgents agents;
  private readonly IProjects projects;
  private readonly Func<bool?> fullAccess;
  private readonly Func<string> defaultProvider;
  private readonly Func<long> now;
  private readonly string? ledgerFile;
  private Ledger ledger;
  private readonly CloudRecordsDeleteLedger deletes;
  private readonly CloudDeleteWitnessSlot witness;
  private readonly Func<DateTimeOffset> clock;
  private readonly Dictionary<string, DateTimeOffset> gone = new(StringComparer.Ordinal);
  private readonly Dictionary<string, string> removalWaits = new(StringComparer.Ordinal);
  /// Tests only: runs after the roster is read in a capture pass (a delete landing while the pass runs).
  public Action? AfterRosterRead { get; set; }
  public CloudRecordsDeleteLedger Deletes => deletes;

  /// `ledgerFile`: this PC's own record of agent names, carried values and status times (never sent).
  public CloudAgentsOwner(IAgents agents, IProjects projects, CloudRecordsDeleteLedger deletes, Func<bool?>? fullAccess = null, string? ledgerFile = null,
    Func<string>? defaultProvider = null, Func<long>? now = null, CloudDeleteWitnessSlot? witness = null, Func<DateTimeOffset>? clock = null)
  {
    this.agents = agents; this.deletes = deletes; this.witness = witness ?? CloudDeleteWitnessSlot.Shared; this.clock = clock ?? (() => DateTimeOffset.UtcNow); this.projects = projects; this.fullAccess = fullAccess ?? (() => false); this.ledgerFile = ledgerFile;
    this.defaultProvider = defaultProvider ?? (() => "claude"); this.now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    ledger = new Ledger();
    if (ledgerFile is not null && File.Exists(ledgerFile))
      try { ledger = JsonSerializer.Deserialize<Ledger>(File.ReadAllBytes(ledgerFile)) ?? new Ledger(); } catch (JsonException) { }
  }
  private void SaveLedger() { if (ledgerFile is not null) new CloudFileSlot(ledgerFile).Write(JsonSerializer.SerializeToUtf8Bytes(ledger)); }

  public CloudRecordAdapter Adapter(CloudRecordStore store, string account, string deviceId, CloudRecordOrigins origins)
  {
    deletes.Bind(store, deviceId);
    return new(DomainName, InventoryRowName, SourceIdName, Kinds, store, account, deviceId, this, origins, Exclusions);
  }

  // ---- rules (pure) ----

  public static bool ValidId(string id) => id.Length is > 0 and <= 40 && char.IsAsciiLetterOrDigit(id[0]) && id.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-') && !char.IsAsciiLetterUpper(id[0]);
  /// Why a name from another device is not taken on this PC, or null when it may be: (a) it equals or begins a reserved
  /// name (hoot, me); (b) it equals or begins the name of a DIFFERENT agent here; (c) a rename to a name a different agent
  /// here has ever had. A name that only BEGINS WITH another name is accepted and listed once.
  public static string? NameProblem(string name, string id, IReadOnlyDictionary<string, string> others, IReadOnlyDictionary<string, List<string>> history, bool rename)
  {
    if (name != name.Trim() || name.Length > 60 || !CloudProjectsOwner.PlainLine(name, 240)) return "The name set on another device is not one plain line.";
    var lower = name.ToLowerInvariant();
    foreach (var reserved in ReservedNames) if (reserved.StartsWith(lower, StringComparison.Ordinal)) return "The name set on another device would answer to mentions of \"" + reserved + "\".";
    foreach (var other in others.Keys.OrderBy(k => k, StringComparer.Ordinal).Where(o => o != id))
      if (others[other].ToLowerInvariant().StartsWith(lower, StringComparison.Ordinal)) return "The name set on another device would answer to mentions of another agent on this PC (" + others[other] + ").";
    if (rename)
      foreach (var other in history.Keys.OrderBy(k => k, StringComparer.Ordinal).Where(o => o != id))
        if (history[other].Contains(lower)) return "The name set on another device was once the name of another agent on this PC.";
    return null;
  }
  public static string? AlsoAnswers(string name, string id, IReadOnlyDictionary<string, string> others)
  {
    var lower = name.ToLowerInvariant();
    var shorter = ReservedNames.Where(r => lower != r && lower.StartsWith(r, StringComparison.Ordinal)).ToList();
    foreach (var other in others.Keys.OrderBy(k => k, StringComparer.Ordinal).Where(o => o != id))
    {
      var theirs = others[other];
      if (theirs.Length > 0 && lower != theirs.ToLowerInvariant() && lower.StartsWith(theirs.ToLowerInvariant(), StringComparison.Ordinal)) shorter.Add(theirs);
    }
    return shorter.Count == 0 ? null : string.Join("; ", shorter.Select(s => "'" + s + "' also answers to mentions of '" + name + "'"));
  }
  private static int? Rank(CloudJson? status) => CloudRecordJson.Nullish(status) ? 2 : CloudRecordJson.Text(status) switch { "active" => 2, "paused" => 1, "archived" => 0, _ => null };
  /// May a widening-class value from another device replace this PC's? Everything under full access; otherwise only the
  /// same value or one this PC can tell is narrower (a status further off, a subset of skills). Anything else waits.
  public static bool MayApply(string field, CloudJson? cloud, CloudJson? local, string defaultProvider, bool fullAccess)
  {
    if (fullAccess) return true;
    if (CloudRecordJson.Same(CloudRecordJson.Nullish(local) ? CloudJson.Null.Value : local, CloudRecordJson.Nullish(cloud) ? CloudJson.Null.Value : cloud)) return true;
    switch (field)
    {
      case "provider":
        return (CloudRecordJson.Text(cloud) ?? defaultProvider) == (CloudRecordJson.Text(local) ?? defaultProvider) && (CloudRecordJson.Nullish(cloud) || CloudRecordJson.Text(cloud) is not null);
      case "skills":
        if (!CloudRecordJson.Nullish(cloud) && CloudRecordJson.Items(cloud) is null) return false;
        var had = (CloudRecordJson.Items(local) ?? []).Select(CloudRecordJson.Text).OfType<string>().ToHashSet(StringComparer.Ordinal);
        return (CloudRecordJson.Items(cloud) ?? []).All(s => CloudRecordJson.Text(s) is { } name && had.Contains(name));
      case "status":
        return Rank(local) is { } was && Rank(cloud) is { } next && next <= was;
      default:
        return false;
    }
  }

  // ---- the Mac's row shape ↔ this PC's SavedAgent ----

  private static readonly Dictionary<string, (string Ask, string Plan, string Auto)> PermissionNames = new(StringComparer.Ordinal)
  {
    ["claude"] = ("default", "plan", "acceptEdits"), ["codex"] = ("default", "read-only", "workspace-write"), ["gemini"] = ("default", "plan", "auto_edit"),
  };
  private static CloudJson Strings(IEnumerable<string> values) => CloudJson.Arr(values.Select(v => (CloudJson)CloudJson.From(v)));
  private static ImmutableArray<string> StringsOf(CloudJson? value) => (CloudRecordJson.Items(value) ?? []).Select(CloudRecordJson.Text).OfType<string>().ToImmutableArray();
  private static string StatusName(SavedAgentStatus status) => status switch { SavedAgentStatus.Paused => "paused", SavedAgentStatus.Archived => "archived", _ => "active" };
  private static string DefaultSeat(string id) => id[..Math.Min(64, id.Length)];

  private static CloudJson PermissionOut(string? mode, string provider) =>
    mode is not null && PermissionNames.TryGetValue(provider, out var names) ? CloudJson.From(mode switch { "ask" => names.Ask, "plan" => names.Plan, _ => names.Auto }) : CloudJson.Null.Value;
  private static string? PermissionIn(string? mode, string provider)
  {
    if (mode is null || !PermissionNames.TryGetValue(provider, out var names)) return null;
    return mode == names.Ask ? "ask" : mode == names.Plan ? "plan" : mode == names.Auto ? "auto" : null;
  }
  private static int? Limit(double? value) => value is { } n && n >= 1 ? (int)Math.Min(n, 5) : null;
  /// One field this PC holds: how a SavedAgent writes it (null = absent) and how a value from the row is taken in.
  private sealed record Mapped(string Key, Func<SavedAgent, CloudJson?> Out, Func<CloudJson?, SavedAgent, SavedAgent> In);
  private IReadOnlyList<Mapped> Fields() =>
  [
    new("name", a => CloudJson.From(a.Name), (v, a) => a with { Name = CloudRecordJson.Text(v) ?? a.Name }),
    new("role", a => CloudJson.From(a.Description.Length == 0 ? "general" : a.Description), (v, a) => a with { Description = CloudRecordJson.Text(v) is { } r && r != "general" ? r : "" }),
    new("provider", a => CloudJson.From(a.Provider), (v, a) => a with { Provider = CloudRecordJson.Text(v) ?? defaultProvider() }),
    new("model", a => a.Model.Length == 0 ? CloudJson.Null.Value : CloudJson.From(a.Model), (v, a) => a with { Model = CloudRecordJson.Text(v) ?? "" }),
    new("effort", a => CloudJson.From(a.Effort), (v, a) => a with { Effort = CloudRecordJson.Text(v) ?? "auto" }),
    new("icon", a => CloudJson.From(a.Icon), (v, a) => a with { Icon = CloudRecordJson.Text(v) ?? "person" }),
    new("reportsTo", a => a.ReportsTo is null ? null : CloudJson.From(a.ReportsTo), (v, a) => a with { ReportsTo = CloudRecordJson.Text(v) is { Length: > 0 } boss ? boss : null }),
    new("projectId", a => CloudJson.From(a.ProjectId), (v, a) => a with { ProjectId = CloudRecordJson.Text(v) ?? ProjectIdentity.IndependentId }),
    new("seat", a => CloudJson.From(a.Seat.Length == 0 ? DefaultSeat(a.Id) : a.Seat), (v, a) => a with { Seat = CloudRecordJson.Text(v) ?? DefaultSeat(a.Id) }),
    new("status", a => CloudJson.From(StatusName(a.Status)), (v, a) => a with
    {
      Status = CloudRecordJson.Text(v) switch { "paused" => SavedAgentStatus.Paused, "archived" => SavedAgentStatus.Archived, _ => SavedAgentStatus.Active }
    }),
    new("skills", a => Strings(a.Skills.IsDefault ? [] : a.Skills), (v, a) => a with { Skills = StringsOf(v) }),
    new("skillsOff", a => CloudJson.From(a.Settings.SkillsOff), (v, a) => a with { Options = a.Settings with { SkillsOff = CloudRecordJson.Bool(v) == true } }),
    new("toolsPreferred", a => Strings(a.Settings.ToolsPreferred.IsDefault ? [] : a.Settings.ToolsPreferred), (v, a) => a with { Options = a.Settings with { ToolsPreferred = StringsOf(v) } }),
    new("toolsAvoided", a => Strings(a.Settings.ToolsAvoided.IsDefault ? [] : a.Settings.ToolsAvoided), (v, a) => a with { Options = a.Settings with { ToolsAvoided = StringsOf(v) } }),
    new("permissionMode", a => PermissionOut(a.Settings.PermissionMode, a.Provider), (v, a) => a with { Options = a.Settings with { PermissionMode = PermissionIn(CloudRecordJson.Text(v), a.Provider) } }),
    new("maxConcurrent", a => CloudJson.From(a.MaxConcurrentTasks ?? 0), (v, a) => a with { MaxConcurrentTasks = Limit(CloudRecordJson.Number(v)) }),
  ];
  /// What a fresh agent row holds on the Mac for the fields this PC has no place for.
  private static readonly (string Key, CloudJson Value)[] Defaults =
  [
    ("blockedTools", CloudJson.Arr([])), ("maxRunMinutes", CloudJson.From(0)), ("keepAliveMinutes", CloudJson.From(60)), ("keepAliveUntilClose", CloudJson.From(false)),
    ("claudeAgent", CloudJson.Null.Value), ("allowedTools", CloudJson.Null.Value),
  ];

  private CloudJson.Object? Carried(string id) => ledger.Carried.TryGetValue(id, out var text) ? CloudJson.Parse(text) as CloudJson.Object : null;
  /// The agent as the Mac's row (travelling fields only). A field whose value here is what the carried Cloud value already
  /// means travels as that carried value, so nothing is rewritten by the difference in shape.
  private CloudJson.Object Row(SavedAgent agent, CloudJson.Object? carried, bool observe)
  {
    var fields = new List<(string, CloudJson)> { ("id", CloudJson.From(agent.Id)) };
    foreach (var map in Fields())
    {
      var mine = map.Out(agent);
      var theirs = CloudRecordJson.Get(carried, map.Key);
      var same = carried is not null && CloudRecordJson.Same(map.Out(map.In(theirs, agent)), mine);
      var value = same ? theirs : mine;
      if (value is not null) fields.Add((map.Key, value));
    }
    foreach (var (key, fallback) in Defaults) fields.Add((key, CloudRecordJson.Has(carried, key) ? CloudRecordJson.Get(carried, key)! : fallback));
    foreach (var key in new[] { "toolUseRestrictions", "instructionHash" }) if (CloudRecordJson.Has(carried, key)) fields.Add((key, CloudRecordJson.Get(carried, key)!));
    // The status time travels with the status (the Mac's `statusAt`).
    var status = StatusName(agent.Status);
    if (carried is not null && CloudRecordJson.Text(CloudRecordJson.Get(carried, "status")) == status && CloudRecordJson.Has(carried, "statusAt"))
      fields.Add(("statusAt", CloudRecordJson.Get(carried, "statusAt")!));
    else if (status == "active")
    {
      // An active agent says no status time unless the Cloud gave it one (the Mac's lifecycle).
      if (observe && ledger.Status.TryGetValue(agent.Id, out var was) && was != status) { ledger.Status[agent.Id] = status; ledger.StatusAt.Remove(agent.Id); SaveLedger(); }
      fields.Add(("statusAt", CloudJson.Null.Value));
    }
    else
    {
      // Paused or archived here: the time this PC first saw it so, kept so it never changes by itself.
      if (observe && (ledger.Status.GetValueOrDefault(agent.Id) != status || !ledger.StatusAt.ContainsKey(agent.Id)))
      { ledger.Status[agent.Id] = status; ledger.StatusAt[agent.Id] = now(); SaveLedger(); }
      fields.Add(("statusAt", CloudJson.From(ledger.StatusAt.TryGetValue(agent.Id, out var at) ? at : now())));
    }
    return CloudRecordJson.Object(fields);
  }
  private SavedAgent Taken(CloudJson.Object row, SavedAgent agent)
  {
    foreach (var map in Fields()) if (CloudRecordJson.Has(row, map.Key)) agent = map.In(CloudRecordJson.Get(row, map.Key), agent);
    return agent;
  }
  private SavedAgent Fresh(string id, string name) => new(id, name, defaultProvider());
  private static CloudJson.Object Instruction(string id, string text) => CloudRecordJson.Object([("id", CloudJson.From(id)), ("text", CloudJson.From(text))]);
  private string Text(string id) { try { return agents.ReadInstructions(id); } catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException) { return ""; } }
  private void Remember(string id, string name)
  {
    var lower = name.ToLowerInvariant();
    if (!ledger.Names.TryGetValue(id, out var list)) ledger.Names[id] = list = [];
    if (list.Contains(lower)) return;
    list.Add(lower); SaveLedger();
  }

  // ---- ICloudRecordOwner ----

  public IReadOnlyDictionary<string, CloudJson.Object> CloudRecords()
  {
    var result = new Dictionary<string, CloudJson.Object>(StringComparer.Ordinal);
    var roster = agents.List();
    AfterRosterRead?.Invoke();
    var now = clock().ToUnixTimeMilliseconds();
    foreach (var agent in roster)
    {
      var entity = InstructionKind.Entity(agent.Id);
      var value = Instruction(agent.Id, Text(agent.Id));
      var missing = agent.InstructionsFile is { } file && !File.Exists(file);
      // A file gone is not an edit to empty text: it is looked at as a removal (CloudMissing), never sent as "".
      if (!missing || deletes.LastSeen(entity) is null || deletes.Restoring(entity))
      {
        var shown = value;
        if (deletes.Mark(entity) is not null && !missing)
        {
          // The file is back. An older text coming back where a newer one exists in the Cloud is replaced by the newest.
          var newest = deletes.Newest(entity, InstructionTable);
          var mine = CloudRecordJson.Text(CloudRecordJson.Get(value, "text"));
          if (newest is not null && mine != CloudRecordJson.Text(CloudRecordJson.Get(newest, "text"))
            && deletes.PriorValues(entity).Any(v => CloudRecordJson.Text(CloudRecordJson.Get(v, "text")) == mine))
          {
            WriteText(agent.Id, CloudRecordJson.Text(CloudRecordJson.Get(newest, "text")) ?? "");
            shown = Instruction(agent.Id, CloudRecordJson.Text(CloudRecordJson.Get(newest, "text")) ?? "");
          }
          deletes.ClearMark(entity);
        }
        result[entity] = shown;
        if (!CloudRecordJson.Same(deletes.Saved(entity), shown)) { deletes.Put(entity, shown); deletes.RememberVersion(entity, shown); }
        if (!missing && (deletes.LastSeen(entity) is not { } seen || now - seen >= 10_000 || seen > now)) deletes.Seen(entity, now);
        gone.Remove(entity);
      }
      // An agent back in the list while its Bin copy exists counts as put back only when no delete intent exists and the
      // Bin copy is still the one seen (a delete landing while this pass runs keeps its Bin copy and travels).
      var agentEntity = AgentKind.Entity(agent.Id);
      if (deletes.BinnedGroup(agentEntity) is { } group && deletes.Intent(agentEntity) is null && deletes.Intent(entity) is null
        && agents.List().Any(a => a.Id == agent.Id) && deletes.BinnedGroup(agentEntity) == group)
      {
        deletes.Put(agentEntity, CloudJson.From(true), restoring: true);
        deletes.Put(entity, value, restoring: true);
        deletes.TakeBin(agentEntity);
      }
      result[agentEntity] = Row(agent, Carried(agent.Id), observe: true);
      Remember(agent.Id, agent.Name);
    }
    return result;
  }

  public CloudRecordPlan CloudPlan(string entity, CloudJson.Object? cloud)
  {
    if (InstructionKind.IdOf(entity) is not null && cloud is not null) deletes.RememberVersion(entity, cloud);
    if (deletes.Mark(entity) is { } mark) return new(null, Waiting: CloudDeleteText.Title(mark.Mark));
    if (InstructionKind.IdOf(entity) is { } textId)
    {
      if (agents.List().FirstOrDefault(a => a.Id == textId)?.InstructionsFile is { } file && deletes.LastSeen(entity) is not null && !Directory.Exists(Path.GetDirectoryName(file)))
        return new(null, Waiting: FolderGone);
      if (cloud is null && deletes.Merged(entity, InstructionTable)?.Shown() is { } removal && CloudRecordJson.Bool(CloudRecordJson.Get(removal, "deletedWithAgent")) == true
        && CloudRecordJson.Text(CloudRecordJson.Get(removal, "deletedGroup")) is { } group && !deletes.RemovalSeen(AgentKind.Entity(textId), group, AgentKind.Table))
      {
        removalWaits[textId] = group;
        return new(null, Waiting: FollowsRemoval);
      }
      removalWaits.Remove(textId);
      return PlanInstruction(textId, cloud);
    }
    var id = AgentKind.IdOf(entity) ?? throw new CloudRecordRefusal("This is not an agent record.");
    return PlanAgent(id, cloud);
  }
  private CloudRecordPlan PlanInstruction(string id, CloudJson.Object? cloud)
  {
    var current = agents.List().FirstOrDefault(a => a.Id == id);
    var kept = current is null ? null : Instruction(id, Text(id));
    if (cloud is null) return new(null);
    if (!ValidId(id)) return new(kept, Waiting: "This instruction file's name is not an agent id this PC can use.");
    // The text is written when its agent is on this PC: a text without its agent is kept, not placed.
    if (current is null) return new(null, Waiting: "These instructions wait for their agent to be added on this PC.");
    if (CloudRecordJson.Text(CloudRecordJson.Get(cloud, "text")) is not { } text || text.Length > 32_000 || text.Contains('\0'))
      return new(kept, new Dictionary<string, string> { ["text"] = "The instructions set on another device are too long for this PC or are not text." });
    return new(Instruction(id, text.Trim()));
  }
  private CloudRecordPlan PlanAgent(string id, CloudJson.Object? cloud)
  {
    var list = agents.List();
    var current = list.FirstOrDefault(a => a.Id == id);
    var carried = Carried(id);
    var kept = current is null ? null : CloudRecordAdapter.Travelling(Row(current, carried, observe: false), AgentKind.Table);
    // Removed in the Cloud: into the Bin here (CloudRemove).
    if (cloud is null) return new(null);
    if (!ValidId(id)) return new(kept, Waiting: "This agent's id is not one this PC can use.");
    // The merge's existence field already resolved ancestry: an edit made on top of a removal wins, and the agent comes
    // back from the Bin with this PC's own settings kept.
    var retired = Retired(id);
    var basis = current ?? retired;
    var held = new Dictionary<string, string>(StringComparer.Ordinal);
    var row = kept ?? (retired is null ? null : CloudRecordAdapter.Travelling(Row(retired, carried, observe: false), AgentKind.Table)) ?? CloudRecordJson.Object([("id", CloudJson.From(id))]);

    // 1. The name decides who an @name mention reaches.
    var others = list.Where(a => a.Id != id).ToDictionary(a => a.Id, a => a.Name, StringComparer.Ordinal);
    var theirName = CloudRecordJson.Text(CloudRecordJson.Get(cloud, "name"));
    if (CloudRecordJson.Has(cloud, "name") && theirName != current?.Name)
    {
      if (NameProblem(theirName ?? "", id, others, ledger.Names, current is not null) is { } problem) held["name"] = problem;
      else row = CloudRecordJson.Set(row, "name", CloudJson.From(theirName!));
    }
    if (CloudRecordJson.Text(CloudRecordJson.Get(row, "name")) is not { } name || current is null && held.ContainsKey("name"))
      return new(null, Waiting: "This agent is not added on this PC. " + (held.GetValueOrDefault("name") ?? "It has no name."));
    var note = theirName == name ? AlsoAnswers(name, id, others) : null;

    // 2. Plain shared fields: newest wins (the merge decided).
    foreach (var field in SharedFields.Where(f => CloudRecordJson.Has(cloud, f)))
    {
      var value = CloudRecordJson.Get(cloud, field)!;
      if (field == "model" && CloudRecordJson.Text(value) is { } model && !CloudMergeTables.IsValidModel(model))
      { held[field] = "The model set on another device is not a model name this PC accepts."; continue; }
      row = CloudRecordJson.Nullish(value) ? CloudRecordJson.Remove(row, field) : CloudRecordJson.Set(row, field, value);
    }

    // 3. Widening fields, by the one rule. A new agent is compared with what a fresh agent would hold here.
    var full = fullAccess() == true;
    var fallback = defaultProvider();
    if (current is null && full && CloudRecordJson.Text(CloudRecordJson.Get(cloud, "projectId")) is { Length: > 0 } wanted && wanted != ProjectIdentity.IndependentId
      && !projects.List().Any(p => p.Id == wanted)) return new(null, Waiting: ProjectNotHere);
    var @base = basis is null ? CloudRecordAdapter.Travelling(Row(Fresh(id, name), null, observe: false), AgentKind.Table) : CloudRecordAdapter.Travelling(Row(basis, carried, observe: false), AgentKind.Table);
    foreach (var field in WideningFields.Where(f => CloudRecordJson.Has(cloud, f)))
    {
      var value = CloudRecordJson.Get(cloud, field)!;
      if (MayApply(field, value, CloudRecordJson.Get(@base, field), fallback, full))
      {
        row = CloudRecordJson.Nullish(value) ? CloudRecordJson.Remove(row, field) : CloudRecordJson.Set(row, field, value);
        if (field == "status")
          row = CloudRecordJson.Nullish(CloudRecordJson.Get(cloud, "statusAt")) ? CloudRecordJson.Remove(row, "statusAt") : CloudRecordJson.Set(row, "statusAt", CloudRecordJson.Get(cloud, "statusAt")!);
      }
      else
      {
        held[field] = WaitingReason;
        if (field == "status") held["statusAt"] = WaitingReason;
        if (basis is null) row = CloudRecordJson.Has(@base, field) ? CloudRecordJson.Set(row, field, CloudRecordJson.Get(@base, field)!) : CloudRecordJson.Remove(row, field);
      }
    }

    // 4. Exactly as this PC will store it: the agent made from the row, written back in the row's shape. A value this PC
    //    cannot hold is not applied, and is listed.
    var agent = Taken(row, basis ?? Fresh(id, name));
    var planned = CloudRecordAdapter.Travelling(Row(agent, Merge(carried, row), observe: false), AgentKind.Table);
    foreach (var field in new[] { "name" }.Concat(SharedFields).Concat(WideningFields))
      if (CloudRecordJson.Has(cloud, field) && !held.ContainsKey(field) && !CloudRecordAdapter.Equal(Value(planned, field), Value(cloud, field)))
        held[field] = NotHeldHere;
    return new(planned, held, Note: note);
  }
  private static CloudJson Value(CloudJson.Object o, string field) => CloudRecordJson.Has(o, field) && !CloudRecordJson.Nullish(CloudRecordJson.Get(o, field)) ? CloudRecordJson.Get(o, field)! : CloudJson.Null.Value;
  /// The carried value after a write: the row's travelling fields over what was carried before.
  private static CloudJson.Object Merge(CloudJson.Object? carried, CloudJson.Object row)
  {
    var result = carried ?? CloudRecordJson.Object([]);
    foreach (var member in CloudRecordAdapter.Travelling(CloudRecordsDeleteLedger.Clearing(row), CloudMergeTables.Agent).Members) result = CloudRecordJson.Set(result, member.Key, member.Value);
    foreach (var field in SharedFields.Concat(WideningFields).Append("statusAt")) if (!CloudRecordJson.Has(row, field)) result = CloudRecordJson.Remove(result, field);
    return result;
  }

  public void CloudWrite(string entity, CloudJson.Object value, CloudJson.Object? expecting)
  {
    var list = agents.List();
    var changed = new CloudRecordRefusal("This agent changed on this PC while a change from another device was being applied; it is applied on the next try.");
    if (InstructionKind.IdOf(entity) is { } textId)
    {
      var owner = list.FirstOrDefault(a => a.Id == textId);
      if (CloudRecordJson.Text(CloudRecordJson.Get(value, "text")) is not { } text || owner is null) throw new CloudFailure("invalid_request");
      if (!CloudRecordAdapter.Equal(Instruction(textId, Text(textId)), expecting)) throw changed;
      try { agents.SaveInstructions(textId, text); }
      catch (Exception error) when (error is ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException) { throw Refusal(error); }
      return;
    }
    var id = AgentKind.IdOf(entity) ?? throw new CloudFailure("invalid_request");
    var current = list.FirstOrDefault(a => a.Id == id);
    var carried = Carried(id);
    if (!CloudRecordAdapter.Equal(current is null ? null : CloudRecordAdapter.Travelling(Row(current, carried, observe: false), AgentKind.Table), expecting)) throw changed;
    var name = CloudRecordJson.Text(CloudRecordJson.Get(value, "name")) ?? throw new CloudFailure("invalid_request");
    var retired = current is null ? Retired(id) : null;
    var agent = Taken(value, current ?? retired ?? Fresh(id, name));
    try
    {
      if (current is null && retired is not null && agents is ICloudAgentEntries entries) entries.CloudPutBack(agent with { InstructionsFile = null });
      else agents.Save(agent, expected: current, createOnly: current is null);
    }
    catch (Exception error) when (error is ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException) { throw Refusal(error); }
    ledger.Carried[id] = CloudRecordJson.Encode(Merge(carried, value));
    SaveLedger();
    if (current is null)
    {
      // Back from a removal: its newest instruction text (or the Bin's) comes back with it.
      var textEntity = InstructionKind.Entity(id);
      var newest = deletes.Newest(textEntity, InstructionTable);
      if ((CloudRecordJson.Text(CloudRecordJson.Get(newest, "text")) ?? CloudRecordJson.Text(CloudRecordJson.Get(deletes.BinnedValue(AgentKind.Entity(id)), "text"))) is { } text)
      {
        WriteText(id, text);
        if (newest is null) deletes.Put(textEntity, Instruction(id, text), restoring: true);
      }
    }
    Remember(id, agent.Name);
  }
  private static CloudRecordRefusal Refusal(Exception error) => new("Not applied on this PC: " + error.Message + " It is tried again later.");

  public void CloudImported(IReadOnlyList<string> entities) { }
  private void WriteText(string id, string text)
  {
    try { agents.SaveInstructions(id, text); }
    catch (Exception error) when (error is ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException) { throw Refusal(error); }
  }
  private static CloudJson AgentJson(SavedAgent agent) => CloudJson.Parse(System.Text.Encoding.UTF8.GetString(JsonSerializer.SerializeToUtf8Bytes(agent)));
  private static SavedAgent? AgentOf(CloudJson? value)
  {
    if (value is not CloudJson.Object) return null;
    try { return JsonSerializer.Deserialize<SavedAgent>(CloudRecordJson.Encode(value)); } catch (JsonException) { return null; }
  }
  /// The agent as a delete put it in the Bin, or null.
  private SavedAgent? Retired(string id) => AgentOf(CloudRecordJson.Get(deletes.BinnedValue(AgentKind.Entity(id)), "row"));

  // ---- the delete rule ----

  public void ConfigureDeleteRule(Func<bool>? gate = null, Func<string, string?>? deviceName = null, Func<long?>? serviceNow = null) => deletes.Configure(gate, deviceName, serviceNow);
  /// The app's delete (and a tool's): always EVERYWHERE, into the Bin on every device for 30 days.
  public CloudBinGroup RemoveByApp(string id, CloudDeleteActor? actor = null) =>
    DeleteItemsAsync([new CloudDeleteItem(AgentKind.Entity(id), "agent", "Agent")], CloudDeleteScope.Everywhere, actor ?? deletes.Actor()).GetAwaiter().GetResult();

  /// The agent and its instruction text into the Bin, then its entry out. `notify`: a delete made here (its removal
  /// travels); an arriving removal only applies.
  private void RemoveAgentRecord(string id, CloudDeleteActor actor, bool notify)
  {
    if (agents.List().FirstOrDefault(a => a.Id == id) is not { } agent) return;
    var entity = AgentKind.Entity(id); var textEntity = InstructionKind.Entity(id);
    var instructionBin = deletes.BinRows("agent").FirstOrDefault(r => r.Item.Id == textEntity && r.Actor.Group == actor.Group);
    var current = Text(id);
    var text = current.Length > 0 ? current : CloudRecordJson.Text(CloudRecordJson.Get(instructionBin.Value, "text"))
      ?? CloudRecordJson.Text(CloudRecordJson.Get(deletes.Saved(textEntity), "text")) ?? "";
    var reports = agents.List().Where(a => a.ReportsTo == id).Select(a => (CloudJson)CloudJson.From(a.Id));
    var leads = projects.List().Where(p => p.Lead == "agent:" + id).Select(p => (CloudJson)CloudJson.From(p.Id));
    var payload = CloudRecordJson.Object([("row", AgentJson(agent)), ("text", CloudJson.From(text)), ("reports", CloudJson.Arr(reports)), ("leads", CloudJson.Arr(leads))]);
    deletes.PutBin("agent", entity, agent.Name, payload, actor);
    if (instructionBin.Item is not null) deletes.TakeBin(textEntity, permanently: true);
    if (notify)
    {
      deletes.SaveIntent(actor.Intent(entity, CloudDeleteScope.Everywhere));
      deletes.SaveIntent(actor.Intent(textEntity, CloudDeleteScope.Everywhere));
    }
    try
    {
      if (agents is ICloudAgentEntries entries) entries.CloudRemoveEntry(id);
      else
      {
        if (agent.Status != SavedAgentStatus.Archived) agents.Save(agent with { Status = SavedAgentStatus.Archived }, expected: agent);
        agents.Remove(id);
      }
    }
    catch (Exception error) when (error is ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException)
    {
      if (notify) { deletes.ClearIntent(entity); deletes.ClearIntent(textEntity); }
      throw Refusal(error);
    }
    deletes.ClearSaved(entity); deletes.ClearSaved(textEntity);
  }
  /// The instruction text alone into the Bin; the agent stays with empty instructions.
  private void RemoveInstructions(string id, string previous, CloudDeleteActor actor, bool intended = false)
  {
    if (agents.List().FirstOrDefault(a => a.Id == id) is not { } agent) return;
    var entity = InstructionKind.Entity(id);
    var current = Text(id);
    var text = current.Length == 0 ? previous : current;
    deletes.PutBin("agent", entity, agent.Name + " instructions", CloudRecordJson.Object([("row", AgentJson(agent)), ("text", CloudJson.From(text)), ("instructionOnly", CloudJson.From(true))]), actor);
    if (intended) deletes.SaveIntent(actor.Intent(entity, CloudDeleteScope.Everywhere));
    WriteText(id, "");
    if (deletes.Mark(entity) is null) deletes.ClearSaved(entity);
  }

  public bool CloudLocalOnly(string entity) => deletes.Mark(entity) is not null;
  public bool CloudRestoring(string entity) => deletes.Restoring(entity);
  public void CloudCaptured(string entity, bool removed) => deletes.Captured(entity, removed);
  public IReadOnlyList<string> CloudPendingRemovals() => [.. deletes.Pending(AgentKind.Prefix), .. deletes.Pending(InstructionKind.Prefix)];
  public CloudJson.Object? CloudRemovalBase(string entity)
  {
    if (AgentKind.IdOf(entity) is { } id) return Retired(id) is { } agent ? CloudRecordAdapter.Travelling(Row(agent, Carried(id), observe: false), AgentKind.Table) : null;
    if (InstructionKind.IdOf(entity) is { } textId)
    {
      if (deletes.BinnedValue(AgentKind.Entity(textId)) is { } withAgent) return Instruction(textId, CloudRecordJson.Text(CloudRecordJson.Get(withAgent, "text")) ?? "");
      if (deletes.BinnedValue(entity) is { } alone) return Instruction(textId, CloudRecordJson.Text(CloudRecordJson.Get(alone, "text")) ?? "");
    }
    return deletes.Saved(entity) as CloudJson.Object;
  }
  public CloudRecordMissing? CloudMissing(string entity, CloudJson.Object last)
  {
    // A delete intent wins over a put-back flag left from before it.
    var intent = deletes.Intent(entity);
    if (deletes.Mark(entity) is not null || intent is null && deletes.Restoring(entity)) return null;
    if (intent is null && InstructionKind.IdOf(entity) is { } id && agents.List().FirstOrDefault(a => a.Id == id) is { InstructionsFile: { } path })
    {
      if (File.Exists(path)) return null;
      // A missing or unreadable folder is never evidence against one instruction file.
      if (Path.GetDirectoryName(path) is not { } folder || !Directory.Exists(folder)) return null;
      var now = clock();
      if (!gone.TryGetValue(entity, out var first)) { gone[entity] = now; return null; }
      if (now - first < TimeSpan.FromSeconds(3)) return null;
      var lastSeen = deletes.LastSeen(entity) is { } ms ? DateTimeOffset.FromUnixTimeMilliseconds(ms) : first;
      var answer = witness.WhoAsync(path, lastSeen, now).GetAwaiter().GetResult();
      if (answer.Kind == CloudDeleteWitnessAnswer.Kinds.Ai)
      {
        var local = deletes.Actor();
        var actor = local with { By = CloudDeleteBy.Ai, Session = answer.Session, Agent = answer.Agent, At = deletes.Now(), Group = answer.Group ?? local.Group };
        RemoveInstructions(id, CloudRecordJson.Text(CloudRecordJson.Get(last, "text")) ?? "", actor, intended: true);
        intent = actor.Intent(entity, CloudDeleteScope.Everywhere);
      }
      else
      {
        // Gone by hand: "Not on this PC". Never sent, never put back by sync.
        deletes.Put(entity, last);
        deletes.PutMark(entity, CloudLocalMark.NotOnThisPc, deletes.Now());
        return null;
      }
    }
    if (intent is null) return null;
    if (!deletes.IsOpen() || !CloudDeleteText.IsUuid(intent.Group)) return new(null);
    var metadata = CloudRecordsDeleteLedger.Metadata(intent, deletes.MacName(intent.Mac));
    if (InstructionKind.IdOf(entity) is { } textId && deletes.BinRows("agent").Any(r => r.Item.Id == AgentKind.Entity(textId) && r.Actor.Group == intent.Group))
      metadata = CloudRecordJson.Set(metadata, "deletedWithAgent", CloudJson.From(true));
    return new(metadata);
  }
  public void CloudTombstone(string entity, CloudJson.Object removal, string device, long at)
  {
    if (InstructionKind.IdOf(entity) is not { } id || deletes.Saved(entity) is not { } saved || agents.List().FirstOrDefault(a => a.Id == id) is not { } agent) return;
    var missing = agent.InstructionsFile is { } file && !File.Exists(file);
    if (deletes.Mark(entity) is null && !missing) return;
    var actor = deletes.Arriving(removal, device, at);
    if (deletes.BinRows("agent").Any(r => r.Item.Id == AgentKind.Entity(id) && r.Actor.Group == actor.Group)) return;
    deletes.PutBin("agent", entity, agent.Name + " instructions",
      CloudRecordJson.Object([("row", AgentJson(agent)), ("text", CloudRecordJson.Get(saved, "text") ?? CloudJson.From("")), ("instructionOnly", CloudJson.From(true))]), actor);
  }
  public void CloudRemove(string entity, CloudJson.Object? expecting, CloudJson.Object removal, string device, long at)
  {
    if (deletes.Mark(entity) is not null) return;
    var list = agents.List();
    var actor = deletes.Arriving(removal, device, at);
    if (AgentKind.IdOf(entity) is { } id)
    {
      var current = list.FirstOrDefault(a => a.Id == id);
      if (!CloudRecordAdapter.Equal(current is null ? null : CloudRecordAdapter.Travelling(Row(current, Carried(id), observe: false), AgentKind.Table), expecting))
        throw new CloudRecordRefusal("This agent changed while its removal arrived.");
      if (current is not null) RemoveAgentRecord(id, actor, notify: false);
    }
    else if (InstructionKind.IdOf(entity) is { } textId)
    {
      if (list.FirstOrDefault(a => a.Id == textId) is null) return;
      var text = Text(textId);
      if (!CloudRecordAdapter.Equal(Instruction(textId, text), expecting)) throw new CloudRecordRefusal("These instructions changed while their removal arrived.");
      if (CloudRecordJson.Bool(CloudRecordJson.Get(removal, "deletedWithAgent")) == true && deletes.Newest(AgentKind.Entity(textId), AgentKind.Table) is not null)
      {
        // The row's ancestry kept an edit: its bundled instruction removal loses with the row's removal.
        deletes.Put(entity, Instruction(textId, text), restoring: true);
        return;
      }
      RemoveInstructions(textId, text, actor);
    }
  }

  public Task<CloudBinGroup> DeleteItemsAsync(IReadOnlyList<CloudDeleteItem> items, CloudDeleteScope scope, CloudDeleteActor by)
  {
    var removed = new List<CloudDeleteItem>();
    foreach (var item in items)
    {
      var id = AgentKind.IdOf(item.Id) ?? item.Id;
      if (agents.List().FirstOrDefault(a => a.Id == id) is not { } agent) continue;
      RemoveAgentRecord(id, by, notify: true);
      removed.Add(new(AgentKind.Entity(id), "agent", agent.Name));
    }
    return Task.FromResult(new CloudBinGroup(by.Group, by.By, by.MacName, by.Session, by.Agent, by.At, removed));
  }
  public Task<IReadOnlyList<CloudDeleteItem>> BringBackAsync(IReadOnlyList<CloudDeleteItem> items, CloudBringBackDestination to)
  {
    foreach (var item in items)
    {
      if (InstructionKind.IdOf(item.Id) is not { } id) continue;
      WriteText(id, CloudRecordJson.Text(CloudRecordJson.Get(deletes.Newest(item.Id, InstructionTable), "text")) ?? "");
      deletes.ClearMark(item.Id);
    }
    return Task.FromResult(items);
  }
  public Task<IReadOnlyList<CloudNotHereItem>> NotHereAsync()
  {
    var list = agents.List();
    return Task.FromResult<IReadOnlyList<CloudNotHereItem>>(deletes.Marks().Select(m => InstructionKind.IdOf(m.Place) is { } id && list.FirstOrDefault(a => a.Id == id) is { } agent
      ? new CloudNotHereItem(new(m.Place, "agent", agent.Name + " instructions"), m.Mark, m.At) : null).OfType<CloudNotHereItem>().ToArray());
  }
  public Task<IReadOnlyList<CloudBinGroup>> BinGroupsAsync() => Task.FromResult(CloudRecordsDeleteLedger.Groups(deletes.BinRows("agent").Select(r => (r.Item, r.Actor))));
  public Task<IReadOnlyList<CloudDeleteItem>> PutBackGroupAsync(string group) => Task.FromResult(PutBackAll(group).Restored);
  /// "Put back all": every item is tried; one that fails never stops the rest. An agent comes back with what its delete
  /// cleared: who reported to it and the projects it led.
  public CloudRecordsPutBack PutBackAll(string group)
  {
    var restored = new List<CloudDeleteItem>(); var failed = new List<CloudDeleteItem>();
    foreach (var row in deletes.BinRows("agent").Where(r => r.Actor.Group == group))
    {
      try { PutBack(row.Value); deletes.TakeBin(row.Item.Id); restored.Add(row.Item); }
      catch (Exception error) when (error is not OutOfMemoryException) { failed.Add(row.Item); }
    }
    return new(restored, failed);
  }
  private void PutBack(CloudJson.Object saved)
  {
    var agent = AgentOf(CloudRecordJson.Get(saved, "row")) ?? throw new CloudFailure("invalid_request");
    var id = agent.Id;
    var only = CloudRecordJson.Bool(CloudRecordJson.Get(saved, "instructionOnly")) == true;
    var text = CloudRecordJson.Text(CloudRecordJson.Get(saved, "text")) ?? "";
    if (!only && agents.List().All(a => a.Id != id))
    {
      try
      {
        if (agents is ICloudAgentEntries entries) entries.CloudPutBack(agent with { InstructionsFile = null });
        else agents.Save(agent with { InstructionsFile = null }, createOnly: true);
      }
      catch (Exception error) when (error is ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException) { throw Refusal(error); }
    }
    WriteText(id, text);
    foreach (var entity in new[] { AgentKind.Entity(id), InstructionKind.Entity(id) })
    {
      deletes.ClearIntent(entity); deletes.ClearMark(entity);
      deletes.Put(entity, entity.StartsWith(AgentKind.Prefix, StringComparison.Ordinal) ? CloudJson.From(true) : Instruction(id, text), restoring: true);
    }
    if (only) return;
    foreach (var report in (CloudRecordJson.Items(CloudRecordJson.Get(saved, "reports")) ?? []).Select(CloudRecordJson.Text).OfType<string>())
      if (agents.List().FirstOrDefault(a => a.Id == report) is { ReportsTo: null } other) agents.Save(other with { ReportsTo = id }, expected: other);
    foreach (var lead in (CloudRecordJson.Items(CloudRecordJson.Get(saved, "leads")) ?? []).Select(CloudRecordJson.Text).OfType<string>())
      if (projects.List().FirstOrDefault(p => p.Id == lead) is { Lead: null }) projects.SetLead(lead, "agent:" + id, agent.Name);
  }
  public Task DeleteForGoodAsync(IReadOnlyList<CloudDeleteItem> items)
  {
    foreach (var item in items)
    {
      deletes.TakeBin(item.Id, permanently: true);
      if (deletes.Mark(item.Id) is null) deletes.ClearSaved(item.Id);
    }
    return Task.CompletedTask;
  }

  /// What a waiting agent's plan depends on outside its own row: the trust setting and this PC's project ids.
  public string CloudContext()
  {
    var access = fullAccess() switch { true => "access:full ", false => "access:ask ", null => "access:? " };
    var removals = string.Join(',', removalWaits.Keys.OrderBy(k => k, StringComparer.Ordinal)
      .Select(id => id + (deletes.RemovalSeen(AgentKind.Entity(id), removalWaits[id], AgentKind.Table) ? ":seen" : ":waiting")));
    return access + "removals:" + removals + " projects:" + string.Join(',', projects.List().Select(p => p.Id).OrderBy(p => p, StringComparer.Ordinal));
  }
}
