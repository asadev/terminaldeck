using System.Globalization;
using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// The 15 Nov delete rule, ported one to one from the Mac (td-mac-next2 CloudDeleteRule.swift, the shared half of
// BackendCloudFolderRules.swift `CloudFileDeleteRecords`, BackendCloudDeleteWitness.swift). Every kind's owner on Windows
// (memory, instruction files, records, Cloud folder, artifacts, saved passwords) uses these types and nothing else:
// - BY HAND in a folder (Explorer, a terminal, any program outside a Terminal Deck session): gone on THIS PC ONLY, a
//   local mark "Not on this PC", never sent; sync never brings it back by itself.
// - The person inside Terminal Deck: "Cloud" (the Cloud copy goes to the Bin, every device keeps its own as "Only on
//   this PC") or "Everywhere" (Bin on every device for 30 days, removed everywhere). Tasks and agents: always everywhere.
// - An AI (a tool, or a command seen by the witness inside a Terminal Deck session): always everywhere, into the Bin.
// - The Bin: 30 days, by hand only, grouped (one press / tool call / AI command = one group), "Put back all".
// Windows wording says "PC" where the Mac says "Mac"; every value that travels is the Mac's, byte for byte.

public enum CloudDeleteScope { Everywhere, Cloud }

public enum CloudDeleteBy { Person, Ai }

public enum CloudLocalMark { NotOnThisPc, OnlyOnThisPc }

public enum CloudBringBackDestination { ThisPc, Cloud }

public enum CloudBinEra { Current, OlderVersion, BeforeNewRule }

/// The travelling (and stored) spellings, the Mac's raw values.
public static class CloudDeleteText
{
  public static string Raw(CloudDeleteScope scope) => scope == CloudDeleteScope.Everywhere ? "everywhere" : "cloud";
  public static string Raw(CloudDeleteBy by) => by == CloudDeleteBy.Person ? "person" : "ai";
  public static string Raw(CloudLocalMark mark) => mark == CloudLocalMark.NotOnThisPc ? "not-on-this-mac" : "only-on-this-mac";
  public static CloudDeleteScope? Scope(string? raw) => raw switch { "everywhere" => CloudDeleteScope.Everywhere, "cloud" => CloudDeleteScope.Cloud, _ => null };
  public static CloudDeleteBy? By(string? raw) => raw switch { "person" => CloudDeleteBy.Person, "ai" => CloudDeleteBy.Ai, _ => null };
  public static CloudLocalMark? Mark(string? raw) => raw switch { "not-on-this-mac" => CloudLocalMark.NotOnThisPc, "only-on-this-mac" => CloudLocalMark.OnlyOnThisPc, _ => null };
  public static string Title(CloudLocalMark mark) => mark == CloudLocalMark.NotOnThisPc ? CloudDeleteWords.NotOnThisPc : CloudDeleteWords.OnlyOnThisPc;
  /// Swift's `UUID(uuidString:)`: exactly 8-4-4-4-12 hex, either case.
  public static bool IsUuid(string? text) => text is { Length: 36 } && Guid.TryParseExact(text, "D", out _);
}

/// Written BEFORE a kind changes its file/record. One group for the whole press, tool call or AI command. `Place` is
/// the owner's stable path/record key; every time here is service milliseconds.
public sealed record CloudDeleteIntent(string Place, CloudDeleteScope Scope, CloudDeleteBy By, string Mac, string? Session, string? Agent, long At, string Group);

public sealed class CloudDeleteRuleException(string code) : Exception("The delete rule could not read this.")
{
  public const string InvalidTravelFields = "invalid_travel_fields", InvalidState = "invalid_state";
  public string Code { get; } = code;
}

/// A removal as read from what travelled: no new-rule field = an older version's removal (applied as Everywhere, with
/// the older-version Bin label); otherwise the intent it carries.
public sealed record CloudDeleteTravelRemoval(CloudDeleteIntent? Intent)
{
  public static readonly CloudDeleteTravelRemoval OlderVersion = new((CloudDeleteIntent?)null);
  public bool IsOlderVersion => Intent is null;
}

/// The SAME six fields in memory markers' front matter and in the file engines' about-records. The carrier supplies the
/// place, the removing device and the service time.
public static class CloudDeleteTravel
{
  public const string Rule = "td_delete_rule", Scope = "td_scope", By = "td_by", Session = "td_session", Agent = "td_agent", Group = "td_group";
  public static readonly IReadOnlyList<string> Fields = [Rule, Scope, By, Session, Agent, Group];

  public static void Write(CloudDeleteIntent intent, IDictionary<string, string> fields)
  {
    fields[Rule] = "1";
    fields[Scope] = CloudDeleteText.Raw(intent.Scope);
    fields[By] = CloudDeleteText.Raw(intent.By);
    if (intent.Session is { } s) fields[Session] = s; else fields.Remove(Session);
    if (intent.Agent is { } a) fields[Agent] = a; else fields.Remove(Agent);
    fields[Group] = intent.Group;
  }

  /// Malformed or unknown NEW fields are an error, never silently read as an older Everywhere removal.
  public static CloudDeleteTravelRemoval Read(IReadOnlyDictionary<string, string> fields, string place, string mac, long at)
  {
    if (!fields.TryGetValue(Rule, out var version)) return CloudDeleteTravelRemoval.OlderVersion;
    if (version != "1" || CloudDeleteText.Scope(fields.GetValueOrDefault(Scope)) is not { } scope || CloudDeleteText.By(fields.GetValueOrDefault(By)) is not { } by
      || !fields.TryGetValue(Group, out var group) || !CloudDeleteText.IsUuid(group)) throw new CloudDeleteRuleException(CloudDeleteRuleException.InvalidTravelFields);
    return new(new CloudDeleteIntent(place, scope, by, mac, fields.GetValueOrDefault(Session), fields.GetValueOrDefault(Agent), at, group));
  }
}

public sealed record CloudDeleteMark(string Place, CloudLocalMark Mark, long At);

/// The owner's intents and local marks, one atomic file in the owner's own state folder (the Mac keeps them as two
/// tables in the owner's database). Marks are never sent. Only the owning adapter touches it.
public sealed class CloudDeleteState
{
  private sealed class Body
  {
    public Dictionary<string, Stored> Intents { get; set; } = [];
    public Dictionary<string, StoredMark> Marks { get; set; } = [];
  }
  private sealed class Stored
  {
    public string Scope { get; set; } = ""; public string By { get; set; } = ""; public string Mac { get; set; } = "";
    public string? Session { get; set; } public string? Agent { get; set; } public long At { get; set; } public string Group { get; set; } = "";
  }
  private sealed class StoredMark { public string Mark { get; set; } = ""; public long At { get; set; } }

  private readonly ICloudLedgerSlot slot;
  private readonly Body body;
  public CloudDeleteState(ICloudLedgerSlot slot)
  {
    this.slot = slot;
    body = slot.Read() is { } bytes ? JsonSerializer.Deserialize<Body>(bytes) ?? new Body() : new Body();
  }
  private void Save() => slot.Write(JsonSerializer.SerializeToUtf8Bytes(body));

  public void PutIntent(CloudDeleteIntent intent)
  {
    if (!CloudDeleteText.IsUuid(intent.Group)) throw new CloudDeleteRuleException(CloudDeleteRuleException.InvalidState);
    body.Intents[intent.Place] = new Stored
    {
      Scope = CloudDeleteText.Raw(intent.Scope), By = CloudDeleteText.Raw(intent.By), Mac = intent.Mac, Session = intent.Session, Agent = intent.Agent,
      At = intent.At, Group = intent.Group
    };
    Save();
  }
  public CloudDeleteIntent? Intent(string place)
  {
    if (!body.Intents.TryGetValue(place, out var s)) return null;
    if (CloudDeleteText.Scope(s.Scope) is not { } scope || CloudDeleteText.By(s.By) is not { } by || !CloudDeleteText.IsUuid(s.Group))
      throw new CloudDeleteRuleException(CloudDeleteRuleException.InvalidState);
    return new(place, scope, by, s.Mac, s.Session, s.Agent, s.At, s.Group);
  }
  public IReadOnlyList<string> IntentPlaces() => body.Intents.Keys.OrderBy(k => k, StringComparer.Ordinal).ToArray();
  /// Cleared only AFTER the removal was journaled (or the act was cancelled); reads never consume it.
  public void ClearIntent(string place) { if (body.Intents.Remove(place)) Save(); }
  public void PutMark(CloudDeleteMark mark) { body.Marks[mark.Place] = new StoredMark { Mark = CloudDeleteText.Raw(mark.Mark), At = mark.At }; Save(); }
  public CloudDeleteMark? Mark(string place) =>
    body.Marks.TryGetValue(place, out var m) ? new(place, CloudDeleteText.Mark(m.Mark) ?? throw new CloudDeleteRuleException(CloudDeleteRuleException.InvalidState), m.At) : null;
  public IReadOnlyList<CloudDeleteMark> Marks() => body.Marks.Keys.Select(k => Mark(k)!).OrderBy(m => m.At).ThenBy(m => m.Place, StringComparer.Ordinal).ToArray();
  public void ClearMark(string place) { if (body.Marks.Remove(place)) Save(); }
}

/// Who removed a file that was seen gone. `Command` is the command's start time, never its text.
public sealed record CloudDeleteWitnessAnswer(CloudDeleteWitnessAnswer.Kinds Kind, string? Session = null, string? Agent = null, DateTimeOffset? Command = null, string? Group = null)
{
  public enum Kinds { Ai, NotAi, CannotKnow }
  public static readonly CloudDeleteWitnessAnswer NotAi = new(Kinds.NotAi), CannotKnow = new(Kinds.CannotKnow);
  public static CloudDeleteWitnessAnswer Ai(string session, string? agent, DateTimeOffset command, string group) => new(Kinds.Ai, session, agent, command, group);
  public CloudDeleteBy By => Kind == Kinds.Ai ? CloudDeleteBy.Ai : CloudDeleteBy.Person;
}

public interface ICloudDeleteWitness
{
  Task<CloudDeleteWitnessAnswer> WhoAsync(string removedPath, DateTimeOffset lastSeen, DateTimeOffset seenGoneAt);
}

public sealed class CloudDeleteUnknownWitness : ICloudDeleteWitness
{
  public Task<CloudDeleteWitnessAnswer> WhoAsync(string removedPath, DateTimeOffset lastSeen, DateTimeOffset seenGoneAt) => Task.FromResult(CloudDeleteWitnessAnswer.CannotKnow);
}

/// The composition installs the witness ONCE, before engines start. Until then every gone file is by hand.
public sealed class CloudDeleteWitnessSlot
{
  public static CloudDeleteWitnessSlot Shared { get; } = new();
  private readonly object gate = new();
  private ICloudDeleteWitness? witness;
  public bool InstallOnce(ICloudDeleteWitness witness)
  {
    lock (gate)
    {
      if (this.witness is not null) return false;
      this.witness = witness;
      return true;
    }
  }
  public Task<CloudDeleteWitnessAnswer> WhoAsync(string removedPath, DateTimeOffset lastSeen, DateTimeOffset seenGoneAt)
  {
    if (!Path.IsPathFullyQualified(removedPath) || lastSeen > seenGoneAt) return Task.FromResult(CloudDeleteWitnessAnswer.CannotKnow);
    ICloudDeleteWitness current;
    lock (gate) current = witness ?? new CloudDeleteUnknownWitness();
    return current.WhoAsync(removedPath, lastSeen, seenGoneAt);
  }
}

/// The gate: "Cloud" deletes and the new form travel only while EVERY computer of the account announced the delete rule
/// (`v1:<ms>`, at most 3 days old) or opted out with `none` (J-1: applies no removals, sends none; never waited for).
public static class CloudDeleteGate
{
  public const string Feature = "deleterule";
  public const int Format = 1;
  public const long FreshFor = 3L * 24 * 60 * 60 * 1000, RenewAfter = 12L * 60 * 60 * 1000;
  public const string None = "none";
  public static string Key(string device) => "onerule.understands.deleterule." + device.ToLowerInvariant();
  public static string Value(long at) => "v1:" + at.ToString(CultureInfo.InvariantCulture);

  /// `computers`: the account's computers (null/empty or an unknown service clock fails closed). `announcements` is
  /// keyed by the FULL setting key.
  public static bool IsOpen(IReadOnlyCollection<string>? computers, IReadOnlyDictionary<string, string> announcements, long? now)
  {
    if (computers is null || computers.Count == 0 || now is not { } n || n <= 0) return false;
    return computers.All(device =>
    {
      if (device.Length == 0 || !announcements.TryGetValue(Key(device), out var raw)) return false;
      if (raw == None) return true;
      if (!raw.StartsWith("v1:", StringComparison.Ordinal) || !long.TryParse(raw[3..], NumberStyles.None, CultureInfo.InvariantCulture, out var at) || at <= 0 || at > n) return false;
      return n - at <= FreshFor;
    });
  }
  /// Has this device announced the rule (`v1`, or `none`)? Used to read an arriving removal with no about-record.
  public static bool Announced(string? raw) => raw is not null && (raw.StartsWith("v1:", StringComparison.Ordinal) || raw == None);
}

/// Shared page/tool input. `Id` and `Place` route; pages show ONLY the name and dates.
public sealed record CloudDeleteItem(string Id, string Kind, string Name, string? Place = null);

/// One call's attribution: ONE group reused across every kind owner the call touches.
public sealed record CloudDeleteActor(CloudDeleteBy By, string Mac, string MacName, string? Session, string? Agent, long At, string Group)
{
  public CloudDeleteIntent Intent(string place, CloudDeleteScope scope) => new(place, scope, By, Mac, Session, Agent, At, Group);
}

public sealed record CloudNotHereItem(CloudDeleteItem Item, CloudLocalMark Mark, long At);

public sealed record CloudBinGroup(string Id, CloudDeleteBy By, string MacName, string? Session, string? Agent, long At, IReadOnlyList<CloudDeleteItem> Items,
  CloudBinEra Era = CloudBinEra.Current)
{
  public const long RetentionMilliseconds = 30L * 24 * 60 * 60 * 1000;
  public int Count => Items.Count;
  public string Title => Era switch
  {
    CloudBinEra.BeforeNewRule => CloudDeleteWords.BeforeNewRule,
    CloudBinEra.OlderVersion => CloudDeleteWords.RemovedOlderVersion(MacName),
    _ => By == CloudDeleteBy.Ai ? CloudDeleteWords.RemovedByAi(MacName) : CloudDeleteWords.Removed(MacName)
  };
  public bool SameAs(CloudBinGroup o) => Id == o.Id && By == o.By && MacName == o.MacName && Session == o.Session && Agent == o.Agent && At == o.At
    && Era == o.Era && Items.SequenceEqual(o.Items);
}

/// Every kind's owner adopts this. Tasks/agents force Everywhere; "Cloud" needs the gate. The intent and the keeper
/// bytes are stored BEFORE removal. BinGroups/PutBackGroup/DeleteForGood belong to the person's page ONLY; never to an
/// AI tool.
public interface ICloudDeleteOwning
{
  Task<CloudBinGroup> DeleteItemsAsync(IReadOnlyList<CloudDeleteItem> items, CloudDeleteScope scope, CloudDeleteActor by);
  Task<IReadOnlyList<CloudDeleteItem>> BringBackAsync(IReadOnlyList<CloudDeleteItem> items, CloudBringBackDestination to);
  Task<IReadOnlyList<CloudNotHereItem>> NotHereAsync();
  Task<IReadOnlyList<CloudBinGroup>> BinGroupsAsync();
  Task<IReadOnlyList<CloudDeleteItem>> PutBackGroupAsync(string group);
  Task DeleteForGoodAsync(IReadOnlyList<CloudDeleteItem> items);
  /// Whether a delete can be honoured now (secret kinds: false while locked or with no sealed Bin). Pages hide both
  /// buttons when false.
  Task<bool> CanDeleteEverywhereAsync() => Task.FromResult(true);
}

public static class CloudDeleteWords
{
  public const string NotOnThisPc = "Not on this PC", BringBack = "Bring back", BringAllBack = "Bring all back", OnlyOnThisPc = "Only on this PC",
    PutInCloudAgain = "Put in Cloud again", BeforeNewRule = "Before the new rule", PutBackAll = "Put back all", Cloud = "Cloud", Everywhere = "Everywhere",
    CloudNeedsUpdatedDevices = "Cloud only works once your other devices are updated", ThisPc = "This PC", AnotherDevice = "Another of your devices";
  public static string RemovedByAi(string device) => "Removed by an AI on " + device;
  public static string Removed(string device) => "Removed on " + device;
  public static string RemovedOlderVersion(string device) => Removed(device) + " (older version)";
}

/// The file engines' removal attribution (instruction files, Cloud folder, artifacts): an about-record `put` beside the
/// engine's unchanged `archive`, in the same pack, sent immediately before it. Byte for byte the Mac's
/// (`CloudFileDeleteRecords` in BackendCloudFolderRules.swift).
public static class CloudFileDeleteRecords
{
  public const long Day = 86_400_000;
  public const string AboutRefusal = "Refused: a delete note this PC cannot read (from a newer or damaged version). Its file is kept here.";
  public const string AboutSignerRefusal = "Refused: a delete note that speaks for another device. Its file is kept here.";
  public const string NotRemovedLine = "This could not be removed. It is kept on every device.";

  public sealed record About(string Operation, string Place, string Mac, long At, IReadOnlyDictionary<string, string> Fields)
  {
    public CloudDeleteTravelRemoval Travel => CloudDeleteTravel.Read(Fields, Place, Mac, At);
    public CloudJson ToJson() => CloudJson.Obj(("operation", CloudJson.From(Operation)), ("place", CloudJson.From(Place)), ("mac", CloudJson.From(Mac)),
      ("at", CloudJson.From(At)), ("fields", CloudJson.Obj(Fields.OrderBy(f => f.Key, StringComparer.Ordinal).Select(f => (f.Key, (CloudJson?)CloudJson.From(f.Value))).ToArray())));
    public bool Same(About o) => Operation == o.Operation && Place == o.Place && Mac == o.Mac && At == o.At
      && Fields.Count == o.Fields.Count && Fields.All(f => o.Fields.TryGetValue(f.Key, out var v) && v == f.Value);
    public static About FromJson(CloudJson value)
    {
      if (value is not CloudJson.Object o || o.Members.Any(m => m.Key is not ("operation" or "place" or "mac" or "at" or "fields"))
        || o["fields"] is not CloudJson.Object f) throw new CloudDeleteRuleException(CloudDeleteRuleException.InvalidTravelFields);
      var fields = new Dictionary<string, string>(StringComparer.Ordinal);
      foreach (var (k, v) in f.Members) fields[k] = v.AsString ?? throw new CloudDeleteRuleException(CloudDeleteRuleException.InvalidTravelFields);
      return new(o["operation"]?.AsString ?? throw Bad(), o["place"]?.AsString ?? throw Bad(), o["mac"]?.AsString ?? throw Bad(), o["at"]?.AsInteger ?? throw Bad(), fields);
    }
    private static CloudDeleteRuleException Bad() => new(CloudDeleteRuleException.InvalidTravelFields);
  }

  /// A removal that arrived and waits for its place: the version it removes over (`Parents`), who, when, the fields.
  public sealed record Head(string Place, string Version, IReadOnlyList<string> Parents, long At, string Mac, IReadOnlyDictionary<string, string> Fields)
  {
    public CloudDeleteTravelRemoval Travel => CloudDeleteTravel.Read(Fields, Place, Mac, At);
    public static Head Of(string place, string version, IReadOnlyList<string> parents, long at, string mac, CloudDeleteTravelRemoval travel)
    {
      var fields = new Dictionary<string, string>(StringComparer.Ordinal);
      if (travel.Intent is { } intent) CloudDeleteTravel.Write(intent, fields);
      return new(place, version, parents.ToArray(), at, mac, fields);
    }
  }

  public static bool IsAbout(CloudOperation operation) => operation.Source.RecordId.StartsWith("about/", StringComparison.Ordinal);
  public static string AboutKey(string group, string removal) => "about/" + group + "/" + removal;
  public static string AboutId(string removal) => CloudMemoryFormat.OperationId("delete-about\n" + removal);

  /// The about-record for one of this device's removals (`removal` is the engine's archive record).
  public static CloudOperation Operation(CloudOperation removal, CloudDeleteIntent intent)
  {
    var fields = new Dictionary<string, string>(StringComparer.Ordinal);
    CloudDeleteTravel.Write(intent, fields);
    var payload = new About(removal.OpId, intent.Place, intent.Mac, intent.At, fields).ToJson();
    var id = AboutId(removal.OpId);
    var key = AboutKey(intent.Group, removal.OpId);
    return new CloudOperation(1, id, removal.OriginDevice, removal.Domain, CloudMemoryFormat.Uuid(key), id, [], "put", removal.ProjectId, removal.RootId,
      new CloudSourceReference(removal.Source.SourceId, key), removal.CreatedAt, payload, CloudOperation.PayloadHashOf(payload));
  }

  /// A damaged, newer-format or misaddressed about-record: a refusal of that one record (the removal is then applied
  /// the safe way). Null = refused.
  public static About? Read(CloudOperation operation)
  {
    try
    {
      var bytes = CloudCanonical.Encode(operation.Payload);
      if (bytes.Length > 65_536) return null;
      var about = About.FromJson(operation.Payload);
      if (operation.V != 1 || operation.Kind != "put" || CloudBytes.Sha256Hex(bytes) != operation.PayloadHash || !CloudDeleteText.IsUuid(about.Operation)
        || operation.OpId != AboutId(about.Operation) || !string.Equals(about.Mac, operation.OriginDevice, StringComparison.OrdinalIgnoreCase)
        || about.Travel.Intent is not { } intent || operation.Revision != operation.OpId || operation.Parents.Count != 0
        || operation.Source.RecordId != AboutKey(intent.Group, about.Operation) || operation.EntityId != CloudMemoryFormat.Uuid(AboutKey(intent.Group, about.Operation)))
        return null;
      return about;
    }
    catch (Exception e) when (e is CloudDeleteRuleException or CloudFailure or FormatException) { return null; }
  }

  /// How an ARRIVING removal is applied. Everywhere only with its own valid about-record from the same verified signer
  /// at the same place. Missing/refused/unreadable = the SAFE way (the file is kept, "Only on this PC"), unless the
  /// signer never announced the delete rule (an older build): then the old-format Everywhere.
  public static CloudDeleteTravelRemoval ArrivedRemoval(CloudOperation removal, string place, string signer, bool announced, About? about, bool aboutRefused)
  {
    var safe = new CloudDeleteTravelRemoval(SafeIntent(removal, place, signer));
    if (about is not null)
    {
      if (!string.Equals(about.Mac, signer, StringComparison.OrdinalIgnoreCase) || about.Place != place) return safe;
      try { return about.Travel.Intent is { } intent ? new(intent) : safe; } catch (CloudDeleteRuleException) { return safe; }
    }
    if (aboutRefused) return safe;
    return announced ? safe : CloudDeleteTravelRemoval.OlderVersion;
  }
  /// A removal applied the safe way: one group per device and day, as a person's "Cloud" removal on that device.
  public static CloudDeleteIntent SafeIntent(CloudOperation removal, string place, string signer) =>
    new(place, CloudDeleteScope.Cloud, CloudDeleteBy.Person, signer.ToLowerInvariant(), null, null, removal.CreatedAt,
      CloudMemoryFormat.Uuid("delete-safe\n" + signer.ToLowerInvariant() + "\n" + (removal.CreatedAt / Day).ToString(CultureInfo.InvariantCulture)));

  public static string LegacyGroupId(string mac, long at, CloudBinEra era) =>
    CloudMemoryFormat.Uuid(EraRaw(era) + "\n" + mac + "\n" + (at / Day).ToString(CultureInfo.InvariantCulture));
  public static CloudBinGroup LegacyGroup(CloudDeleteItem item, string mac, string macName, long at, CloudBinEra era) =>
    new(LegacyGroupId(mac, at, era), CloudDeleteBy.Person, macName, null, null, at, [item], era);
  public static string EraRaw(CloudBinEra era) => era switch { CloudBinEra.OlderVersion => "olderVersion", CloudBinEra.BeforeNewRule => "beforeNewRule", _ => "current" };

  /// One group per id, its items together; newest first.
  public static IReadOnlyList<CloudBinGroup> Merge(IEnumerable<CloudBinGroup> groups) =>
    groups.GroupBy(g => g.Id).Select(rows =>
    {
      var first = rows.First();
      return first with { Items = rows.SelectMany(r => r.Items).ToArray() };
    }).OrderByDescending(g => g.At).ThenBy(g => g.Id, StringComparer.Ordinal).ToArray();
}
