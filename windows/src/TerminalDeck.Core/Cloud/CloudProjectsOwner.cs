using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Cloud;

// The LIST OF PROJECTS (row I11, domain `projects`), the Mac's BackendCloudLeanProjects.swift on Windows. What travels of
// a project: its id, name, icon and colour, and its lead (with the lead's name) when that is an agent. NEVER a folder
// path: a project's folders are this PC's own. A project that arrives and is not on this PC gets its own folder by itself
// (CloudProjectFolders) and is added with it; nothing is fetched into it. Nothing from the Cloud starts work.
//
// Windows differences, on purpose: the Independent project is each device's own (its picture differs per platform) and
// is never sent or changed by the Cloud.
//
// The delete rule (lane D2, the Mac's 87941cff8 BackendCloudLeanProjects): a project removed in the app (RemoveByApp /
// DeleteItems "Everywhere") goes into the Bin on every device for 30 days; only the list ENTRY goes, his folders and files
// on every device stay. "Cloud" keeps each device's entry as "Only on this PC". "Remove from this PC" hides the entry here
// only ("Not on this PC"), sends nothing, and Bring back restores its folder map. An edit made on top of a removal wins.
public sealed class CloudProjectsOwner : ICloudRecordOwner, ICloudDeleteOwning
{
  public const string DomainName = "projects", InventoryRowName = "I11", SourceIdName = "project-registry";
  public static readonly CloudRecordKind Kind = new("project:", CloudMergeTablesV2.Project, ListedValues: new HashSet<string>(StringComparer.Ordinal) { "name" });
  public static readonly IReadOnlyList<string> Exclusions =
  [
    "Project folders are chosen on each device and are never sent.",
    "Project logo pictures, dashboards and a lead that is a live session stay on this PC in this version.",
  ];
  public const int MaximumNameLength = 80;

  private readonly IProjects projects;
  private readonly CloudProjectFolders? folders;
  private readonly Func<bool?> fullAccess;
  private readonly Action projectsAdded;
  private readonly string? seenFile;
  private readonly HashSet<string> seen;
  private HashSet<string> known = new(StringComparer.Ordinal);
  private readonly CloudRecordsDeleteLedger deletes;
  public CloudRecordsDeleteLedger Deletes => deletes;

  /// `fullAccess`: true while "How this PC trusts your other devices" is "Automatically, with my account" (the default);
  /// then a project lead chosen on the account's own device is applied with no click. `projectsAdded`: a project became
  /// known on this PC (arrived or made here): project memory that waited for it is placed. `seenFile`: this PC's list of
  /// every project id it has held (never sent).
  public CloudProjectsOwner(IProjects projects, CloudProjectFolders? folders, CloudRecordsDeleteLedger deletes, Func<bool?>? fullAccess = null, Action? projectsAdded = null,
    string? seenFile = null)
  {
    this.projects = projects; this.deletes = deletes; this.folders = folders; this.fullAccess = fullAccess ?? (() => false); this.projectsAdded = projectsAdded ?? (() => { });
    this.seenFile = seenFile;
    seen = new(StringComparer.Ordinal);
    if (seenFile is not null && File.Exists(seenFile))
      try { seen.UnionWith(JsonSerializer.Deserialize<List<string>>(File.ReadAllBytes(seenFile)) ?? []); } catch (JsonException) { }
  }

  public CloudRecordAdapter Adapter(CloudRecordStore store, string account, string deviceId, CloudRecordOrigins origins)
  {
    deletes.Bind(store, deviceId);
    return new(DomainName, InventoryRowName, SourceIdName, [Kind], store, account, deviceId, this, origins, Exclusions);
  }

  /// One plain line: no control character, no line break, within `maximum` UTF-8 bytes.
  public static bool PlainLine(string value, int maximum, bool optional = false) =>
    Encoding.UTF8.GetByteCount(value) <= maximum && !value.Any(c => char.IsControl(c) || c is '\u2028' or '\u2029') && (optional || value.Trim().Length > 0);
  /// A name from another device as one plain line: control characters and line breaks become spaces, trimmed, at most
  /// `maximum` characters; nothing left is "Project".
  public static string PlainName(string name, int maximum = MaximumNameLength)
  {
    var spaced = new string(name.Select(c => char.IsControl(c) || c is '\u2028' or '\u2029' ? ' ' : c).ToArray());
    var result = string.Join(' ', spaced.Split(' ', StringSplitOptions.RemoveEmptyEntries));
    if (result.Length > maximum) result = result[..maximum];
    if (result.Length > 0 && char.IsHighSurrogate(result[^1])) result = result[..^1];
    result = result.Trim();
    return result.Length == 0 ? "Project" : result;
  }
  /// What travels of a project. A folder is never in it; a lead that is a live session of this PC is not either.
  public static CloudJson.Object Record(Project project)
  {
    var fields = new List<(string, CloudJson)> { ("id", CloudJson.From(project.Id)), ("name", CloudJson.From(project.Name)),
      ("icon", CloudJson.From(project.Icon)), ("colour", CloudJson.From(project.Colour)) };
    if (project.Lead?.StartsWith("session:", StringComparison.Ordinal) != true)
    {
      fields.Add(("lead", CloudJson.From(project.Lead ?? "")));
      fields.Add(("leadName", CloudJson.From(project.Lead is null ? "" : project.LeadName)));
    }
    return CloudRecordJson.Object(fields);
  }
  private static CloudJson.Object Travelling(Project project) => CloudRecordAdapter.Travelling(Record(project), Kind.Table);
  /// The whole entry as this PC keeps it, folders included (for Bring back; never sent).
  public static CloudJson.Object Wire(Project p) => CloudRecordJson.Object([("id", CloudJson.From(p.Id)), ("name", CloudJson.From(p.Name)), ("icon", CloudJson.From(p.Icon)),
    ("colour", CloudJson.From(p.Colour)), ("lead", p.Lead is null ? CloudJson.Null.Value : CloudJson.From(p.Lead)), ("leadName", CloudJson.From(p.LeadName)),
    ("folders", CloudJson.Arr((p.Folders.IsDefault ? [] : p.Folders).Select(f => (CloudJson)CloudJson.From(f))))]);
  private static Project? FromWire(CloudJson? v)
  {
    if (CloudRecordJson.Text(CloudRecordJson.Get(v, "id")) is not { Length: > 0 } id || CloudRecordJson.Text(CloudRecordJson.Get(v, "name")) is not { } name) return null;
    return new Project(id, name, (CloudRecordJson.Items(CloudRecordJson.Get(v, "folders")) ?? []).Select(CloudRecordJson.Text).OfType<string>().ToImmutableArray(),
      CloudRecordJson.Text(CloudRecordJson.Get(v, "icon")) ?? "folder", CloudRecordJson.Text(CloudRecordJson.Get(v, "colour")) ?? "blue",
      Lead: CloudRecordJson.Text(CloudRecordJson.Get(v, "lead")) is { Length: > 0 } lead ? lead : null, LeadName: CloudRecordJson.Text(CloudRecordJson.Get(v, "leadName")) ?? "");
  }
  private static CloudJson.Object? Kept(Project? project) => project is null || project.Id == ProjectIdentity.IndependentId ? null : Travelling(project);

  /// This PC's project ids; true when one is new (memory that waited for it is placed).
  private void Refresh(IReadOnlyList<Project> list)
  {
    var next = list.Select(p => p.Id).ToHashSet(StringComparer.Ordinal);
    var grew = next.Except(known).Any();
    known = next;
    if (next.Except(seen).Any())
    {
      seen.UnionWith(next);
      if (seenFile is not null) new CloudFileSlot(seenFile).Write(JsonSerializer.SerializeToUtf8Bytes(seen.OrderBy(s => s, StringComparer.Ordinal).ToList()));
    }
    if (grew) projectsAdded();
  }
  /// For project memory (CloudMemoryAdapter's `projects`): memory scoped to a project is placed under the SAME id once
  /// that project is on this PC (arrived or made here; no folder needed).
  public string? MemoryProject(string projectId, string originStore) => projects.List().Any(p => p.Id == projectId) ? projectId : null;

  // ---- ICloudRecordOwner ----

  public IReadOnlyDictionary<string, CloudJson.Object> CloudRecords()
  {
    var list = projects.List();
    Refresh(list);
    return list.Where(p => p.Id != ProjectIdentity.IndependentId && deletes.Mark(Kind.Entity(p.Id)) is null).ToDictionary(p => Kind.Entity(p.Id), Record, StringComparer.Ordinal);
  }

  public CloudRecordPlan CloudPlan(string entity, CloudJson.Object? cloud)
  {
    var id = Kind.IdOf(entity) ?? throw new CloudRecordRefusal("This is not a project record.");
    // Independent is each device's own.
    if (id == ProjectIdentity.IndependentId) return new(null);
    var list = projects.List();
    var current = list.FirstOrDefault(p => p.Id == id);
    var kept = Kept(current);
    if (deletes.Mark(entity) is { } mark && (mark.Mark == CloudLocalMark.NotOnThisPc || cloud is null)) return new(null, Waiting: CloudDeleteText.Title(mark.Mark));
    // Removed in the Cloud: the entry goes into the Bin here (CloudRemove).
    if (cloud is null) return new(null);
    if (!ProjectIdentity.ValidId(id)) return new(kept, Waiting: "This project's id is not one this PC can use.");
    // An edit made on top of a removal brings the project back from the Bin, with its folders here.
    current ??= FromWire(deletes.BinnedValue(entity));
    var held = new Dictionary<string, string>(StringComparer.Ordinal);
    string? Line(string key, int maximum, bool optional = false) =>
      CloudRecordJson.Text(CloudRecordJson.Get(cloud, key)) is { } value && PlainLine(value, maximum, optional) ? value : null;
    var name = current?.Name ?? "";
    if (CloudRecordJson.Has(cloud, "name"))
    {
      if (Line("name", 256) is { } theirs && theirs.Trim().Length <= MaximumNameLength) name = theirs.Trim();
      else
      {
        held["name"] = "The name set on another device is not one plain line of at most 80 characters, so this PC keeps its own.";
        // A project NEW to this PC is never left out because of its name: it arrives under the plain form of that name.
        if (current is null) name = PlainName(CloudRecordJson.Text(CloudRecordJson.Get(cloud, "name")) ?? "");
      }
    }
    // A project new to this PC always has a name this PC can show, so it is never left out.
    if (current is null && name.Length == 0) name = PlainName("");
    var icon = current?.Icon ?? "folder";
    if (CloudRecordJson.Has(cloud, "icon"))
    {
      if (Line("icon", 128) is { Length: <= 80 } theirs) icon = theirs; else held["icon"] = "The icon set on another device is not one this PC can show.";
    }
    var colour = current?.Colour ?? "";
    if (CloudRecordJson.Has(cloud, "colour"))
    {
      if (Line("colour", 64, optional: true) is { } theirs && (theirs.Length == 0 || ProjectIdentity.Colours.Contains(theirs))) { if (theirs.Length > 0) colour = theirs; }
      else held["colour"] = "The colour set on another device is not one this PC can show.";
    }
    if (colour.Length == 0) colour = ProjectIdentity.Colours[list.Count(p => p.Id != ProjectIdentity.IndependentId) % ProjectIdentity.Colours.Length];
    // The lead decides which agent may direct the project's agents. With full access (the default trust setting) the lead
    // chosen on the account's own device is taken; otherwise only "no lead" (narrower) is taken and another lead waits.
    var lead = current?.Lead; var leadName = current?.Lead is null ? "" : current.LeadName;
    var full = fullAccess() == true;
    var theirLead = CloudRecordJson.Text(CloudRecordJson.Get(cloud, "lead"));
    if (CloudRecordJson.Has(cloud, "lead") && lead?.StartsWith("session:", StringComparison.Ordinal) != true && theirLead is not null && theirLead != (lead ?? ""))
    {
      if (theirLead.Length == 0) { lead = null; leadName = ""; }
      else if (full && PlainLine(theirLead, 200) && theirLead.StartsWith("agent:", StringComparison.Ordinal) && theirLead.Length > 6)
      {
        lead = theirLead;
        leadName = Line("leadName", 200, optional: true) is { Length: <= 120 } given ? given : "";
      }
      else
      {
        held["lead"] = "A project lead chosen on another device is not applied here. Choose the lead on this PC.";
        held["leadName"] = held["lead"];
      }
    }
    else if (theirLead is not null && theirLead == (lead ?? "") && lead is not null && Line("leadName", 200, optional: true) is { Length: <= 120 } given) leadName = given;
    var planned = (current ?? new Project(id, name, [])) with { Name = name, Icon = icon, Colour = colour, Lead = lead, LeadName = lead is null ? "" : leadName };
    return new(Travelling(planned), held);
  }

  public void CloudWrite(string entity, CloudJson.Object value, CloudJson.Object? expecting)
  {
    var id = Kind.IdOf(entity) ?? throw new CloudFailure("invalid_request");
    if (CloudRecordJson.Text(CloudRecordJson.Get(value, "name")) is not { } name) throw new CloudFailure("invalid_request");
    var list = projects.List();
    var current = list.FirstOrDefault(p => p.Id == id);
    var mark = deletes.Mark(entity);
    if (!CloudRecordAdapter.Equal(mark is null ? Kept(current) : null, expecting))
      throw new CloudRecordRefusal("This project changed on this PC while a change from another device was being applied; it is applied on the next try.");
    var binned = current is null ? FromWire(deletes.BinnedValue(entity)) : null;
    var icon = CloudRecordJson.Text(CloudRecordJson.Get(value, "icon")) ?? current?.Icon ?? "folder";
    var colour = CloudRecordJson.Text(CloudRecordJson.Get(value, "colour")) ?? current?.Colour;
    if (mark?.Mark == CloudLocalMark.OnlyOnThisPc && current is not null) deletes.KeepReplacement("project", entity, current.Name, Wire(current));
    try
    {
      if (current is null && binned is not null && Restore(binned with { Name = name, Icon = icon, Colour = colour ?? binned.Colour }) is { } back)
      {
        current = back;
        deletes.TakeBin(entity);
      }
      else if (current is null)
      {
        // A project new to this PC gets its own folder by itself, made once. The folder never travels.
        if (folders is null) throw new CloudRecordRefusal("This PC has no place for project folders yet; the project waits.");
        string? folder;
        try { folder = folders.FolderFor(id, name, list.SelectMany(p => p.Folders)); }
        catch (CloudProjectFolders.DiskProblem problem) { throw new CloudRecordRefusal(problem.Message); }
        if (folder is null) throw new CloudRecordRefusal(folders.Problem ?? "The folder for " + name + " could not be made on this PC yet. Tried again in a few minutes.");
        current = projects.Save(new ProjectDraft(id, name, [folder], icon, colour), createOnly: true);
        folders.Attached(id);
      }
      else if (current.Name != name || current.Icon != icon || colour is not null && current.Colour != colour)
        current = projects.Save(new ProjectDraft(id, name, current.Folders, icon, colour), expected: current);
      if (CloudRecordJson.Has(value, "lead"))
      {
        var lead = CloudRecordJson.Text(CloudRecordJson.Get(value, "lead")) is { Length: > 0 } wanted ? wanted : null;
        var leadName = lead is null ? "" : CloudRecordJson.Text(CloudRecordJson.Get(value, "leadName")) ?? "";
        if (current.Lead != lead || current.Lead is not null && current.LeadName != leadName) projects.SetLead(id, lead, leadName);
      }
    }
    catch (Exception error) when (error is ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException)
    {
      throw new CloudRecordRefusal("Not applied on this PC: " + error.Message + " It is tried again later.");
    }
    if (mark?.Mark == CloudLocalMark.OnlyOnThisPc) { deletes.ClearMark(entity); deletes.TakeBin(entity); }
    Refresh(projects.List());
  }
  /// Puts an entry back with its folder map (only the entry: nothing in the folders is read, written or removed). A folder
  /// no longer on this PC is left out; with none left the project gets its own folder, as an arriving one does.
  private Project? Restore(Project saved)
  {
    var list = projects.List();
    var folderList = (saved.Folders.IsDefault ? [] : saved.Folders).Where(Directory.Exists).ToImmutableArray();
    if (folderList.IsEmpty && folders?.FolderFor(saved.Id, saved.Name, list.SelectMany(p => p.Folders)) is { } made) { folderList = [made]; folders.Attached(saved.Id); }
    if (folderList.IsEmpty) return null;
    var back = projects.Save(new ProjectDraft(saved.Id, saved.Name, folderList, saved.Icon, saved.Colour), createOnly: true);
    if (saved.Lead is not null) back = projects.SetLead(saved.Id, saved.Lead, saved.LeadName);
    return back;
  }

  public void CloudImported(IReadOnlyList<string> entities) { }


  // ---- the delete rule ----

  /// Sets the gate and the device names (the composition's one call).
  public void ConfigureDeleteRule(Func<bool>? gate = null, Func<string, string?>? deviceName = null, Func<long?>? serviceNow = null) => deletes.Configure(gate, deviceName, serviceNow);
  private void RemoveEntry(string id)
  {
    try { projects.Remove(id); }
    catch (Exception error) when (error is ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException) { throw new CloudRecordRefusal(error.Message); }
  }
  private Project? Here(string id) => projects.List().FirstOrDefault(p => p.Id == id);

  /// The app's Remove (and a tool's): EVERYWHERE, into the Bin for 30 days, no question. Only the list entry goes.
  public CloudBinGroup RemoveByApp(string id, CloudDeleteActor? actor = null) =>
    DeleteItemsAsync([new CloudDeleteItem(Kind.Entity(id), "project", "Project")], CloudDeleteScope.Everywhere, actor ?? deletes.Actor()).GetAwaiter().GetResult();
  /// "Remove from this PC": the entry is hidden here only and its folder map kept for Bring back. Nothing is sent.
  public void RemoveFromThisPc(string id)
  {
    if (id == ProjectIdentity.IndependentId || Here(id) is not { } project) throw new CloudFailure("invalid_request");
    var entity = Kind.Entity(id);
    deletes.Put(entity, Wire(project));
    deletes.ClearIntent(entity);
    deletes.PutMark(entity, CloudLocalMark.NotOnThisPc, deletes.Now());
    try { RemoveEntry(id); } catch { deletes.ClearMark(entity); throw; }
    Refresh(projects.List());
  }
  public bool CloudLocalOnly(string entity) => deletes.Mark(entity) is not null;
  public bool CloudRestoring(string entity) => deletes.Restoring(entity);
  public void CloudCaptured(string entity, bool removed) => deletes.Captured(entity, removed);
  public IReadOnlyList<string> CloudPendingRemovals() => deletes.Pending(Kind.Prefix);
  public CloudJson.Object? CloudRemovalBase(string entity) => FromWire(deletes.Saved(entity)) is { } p ? Record(p) : null;
  public CloudRecordMissing? CloudMissing(string entity, CloudJson.Object last)
  {
    if (deletes.Intent(entity) is not { } intent) return null;
    return new(deletes.IsOpen() && CloudDeleteText.IsUuid(intent.Group) ? CloudRecordsDeleteLedger.Metadata(intent, deletes.MacName(intent.Mac)) : null);
  }
  public void CloudTombstone(string entity, CloudJson.Object removal, string device, long at)
  {
    if (deletes.Mark(entity) is not { } mark || FromWire(deletes.Saved(entity)) is not { } saved) return;
    var actor = deletes.Arriving(removal, device, at);
    deletes.PutBin("project", entity, saved.Name, Wire(saved), actor);
    if (mark.Mark == CloudLocalMark.OnlyOnThisPc && CloudRecordJson.Text(CloudRecordJson.Get(removal, "deletedScope")) != CloudDeleteText.Raw(CloudDeleteScope.Cloud)
      && Kind.IdOf(entity) is { } id)
    {
      if (Here(id) is not null) RemoveEntry(id);
      deletes.ClearMark(entity);
      Refresh(projects.List());
    }
  }
  public void CloudRemove(string entity, CloudJson.Object? expecting, CloudJson.Object removal, string device, long at)
  {
    if (Kind.IdOf(entity) is not { } id || id == ProjectIdentity.IndependentId) throw new CloudFailure("invalid_request");
    if (Here(id) is not { } project) return;
    if (!CloudRecordAdapter.Equal(Kept(project), expecting)) throw new CloudRecordRefusal("This project changed while its removal arrived.");
    var actor = deletes.Arriving(removal, device, at);
    deletes.PutBin("project", entity, project.Name, Wire(project), actor);
    deletes.Put(entity, Wire(project));
    if (CloudRecordJson.Text(CloudRecordJson.Get(removal, "deletedScope")) == CloudDeleteText.Raw(CloudDeleteScope.Cloud)) deletes.PutMark(entity, CloudLocalMark.OnlyOnThisPc, actor.At);
    else { RemoveEntry(id); Refresh(projects.List()); }
  }

  public Task<CloudBinGroup> DeleteItemsAsync(IReadOnlyList<CloudDeleteItem> items, CloudDeleteScope scope, CloudDeleteActor by)
  {
    if (scope == CloudDeleteScope.Cloud && !deletes.IsOpen()) throw new CloudRecordRefusal(CloudDeleteWords.CloudNeedsUpdatedDevices);
    var removed = new List<CloudDeleteItem>();
    foreach (var item in items)
    {
      var id = Kind.IdOf(item.Id) ?? item.Id;
      if (id == ProjectIdentity.IndependentId || Here(id) is not { } project) continue;
      var entity = Kind.Entity(id);
      deletes.PutBin("project", entity, project.Name, Wire(project), by);
      deletes.Put(entity, Wire(project));
      deletes.ClearRestoring(entity);
      deletes.SaveIntent(by.Intent(entity, scope));
      if (scope == CloudDeleteScope.Cloud) deletes.PutMark(entity, CloudLocalMark.OnlyOnThisPc, by.At);
      else
      {
        try { RemoveEntry(id); deletes.ClearMark(entity); }
        catch { deletes.ClearIntent(entity); throw; }
      }
      removed.Add(new(entity, "project", project.Name));
    }
    Refresh(projects.List());
    return Task.FromResult(new CloudBinGroup(by.Group, by.By, by.MacName, by.Session, by.Agent, by.At, removed));
  }
  public Task<IReadOnlyList<CloudDeleteItem>> BringBackAsync(IReadOnlyList<CloudDeleteItem> items, CloudBringBackDestination to)
  {
    var restored = new List<CloudDeleteItem>();
    foreach (var item in items)
    {
      if (Kind.IdOf(item.Id) is not { } id || FromWire(deletes.Saved(item.Id)) is not { } project) continue;
      var current = Here(id);
      var newest = deletes.Newest(item.Id, Kind.Table);
      if (to == CloudBringBackDestination.ThisPc && newest is null && deletes.HasHistory(item.Id, DomainName)) continue;
      if (to == CloudBringBackDestination.ThisPc && newest is not null)
        project = project with
        {
          Name = CloudRecordJson.Text(CloudRecordJson.Get(newest, "name")) ?? project.Name, Icon = CloudRecordJson.Text(CloudRecordJson.Get(newest, "icon")) ?? project.Icon,
          Colour = CloudRecordJson.Text(CloudRecordJson.Get(newest, "colour")) is { Length: > 0 } c ? c : project.Colour,
          Lead = CloudRecordJson.Text(CloudRecordJson.Get(newest, "lead")) is { } l ? (l.Length > 0 ? l : null) : project.Lead,
          LeadName = CloudRecordJson.Text(CloudRecordJson.Get(newest, "leadName")) ?? project.LeadName,
        };
      else if (current is not null) project = current;
      // Restores the local folder MAP only. It never reads, writes or removes anything in those folders.
      try
      {
        if (current is null) { if (Restore(project) is not { } back) continue; project = back; }
        else if (current.Name != project.Name || current.Icon != project.Icon || current.Colour != project.Colour)
          project = projects.Save(new ProjectDraft(id, project.Name, current.Folders, project.Icon, project.Colour), expected: current);
      }
      catch (Exception error) when (error is ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException) { continue; }
      deletes.ClearMark(item.Id); deletes.ClearIntent(item.Id);
      deletes.Put(item.Id, Wire(project), restoring: to == CloudBringBackDestination.Cloud);
      if (to == CloudBringBackDestination.Cloud) deletes.TakeBin(item.Id);
      restored.Add(item);
    }
    Refresh(projects.List());
    return Task.FromResult<IReadOnlyList<CloudDeleteItem>>(restored);
  }
  public Task<IReadOnlyList<CloudNotHereItem>> NotHereAsync() => Task.FromResult<IReadOnlyList<CloudNotHereItem>>(deletes.Marks()
    .Where(m => Kind.IdOf(m.Place) is not null && deletes.Saved(m.Place) is not null)
    .Select(m => new CloudNotHereItem(new(m.Place, "project", CloudRecordJson.Text(CloudRecordJson.Get(deletes.Saved(m.Place), "name")) ?? "Project"), m.Mark, m.At)).ToArray());
  public Task<IReadOnlyList<CloudBinGroup>> BinGroupsAsync() =>
    Task.FromResult(CloudRecordsDeleteLedger.Groups(deletes.BinRows("project").Select(r => (r.Item, r.Actor))));
  public Task<IReadOnlyList<CloudDeleteItem>> PutBackGroupAsync(string group) => Task.FromResult(PutBackAll(group).Restored);
  /// "Put back all": every item is tried; one that fails never stops the rest. The answer names both.
  public CloudRecordsPutBack PutBackAll(string group)
  {
    var restored = new List<CloudDeleteItem>(); var failed = new List<CloudDeleteItem>();
    foreach (var row in deletes.BinRows("project").Where(r => r.Actor.Group == group))
    {
      try
      {
        deletes.Put(row.Item.Id, row.Value);
        if (BringBackAsync([row.Item], CloudBringBackDestination.Cloud).GetAwaiter().GetResult().Count != 1) throw new CloudFailure("unavailable");
        deletes.TakeBin(row.Item.Id);
        restored.Add(row.Item);
      }
      catch (Exception error) when (error is not OutOfMemoryException) { failed.Add(row.Item); }
    }
    return new(restored, failed);
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

  public string CloudContext() => fullAccess() switch { true => "access:full", false => "access:ask", null => "access:?" };
}
