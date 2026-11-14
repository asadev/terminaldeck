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
// is never sent or changed by the Cloud; removals do not travel, so a project removed on this PC is not brought back
// by a later change on another device (it is listed as waiting), and a project removed elsewhere stays here.
public sealed class CloudProjectsOwner : ICloudRecordOwner
{
  public const string DomainName = "projects", InventoryRowName = "I11", SourceIdName = "project-registry";
  public static readonly CloudRecordKind Kind = new("project:", CloudMergeTables.Project, ListedValues: new HashSet<string>(StringComparer.Ordinal) { "name" });
  public static readonly IReadOnlyList<string> Exclusions =
  [
    "Project folders are chosen on each device and are never sent.",
    "Project logo pictures, dashboards and a lead that is a live session stay on this PC in this version.",
  ];
  public const string RemovedHere = "Removed on this PC; changed on another device. It stays removed here until you add it on this PC again.";
  public const int MaximumNameLength = 80;

  private readonly IProjects projects;
  private readonly CloudProjectFolders? folders;
  private readonly Func<bool?> fullAccess;
  private readonly Action projectsAdded;
  private readonly string? seenFile;
  private readonly HashSet<string> seen;
  private HashSet<string> known = new(StringComparer.Ordinal);

  /// `fullAccess`: true while "How this PC trusts your other devices" is "Automatically, with my account" (the default);
  /// then a project lead chosen on the account's own device is applied with no click. `projectsAdded`: a project became
  /// known on this PC (arrived or made here): project memory that waited for it is placed. `seenFile`: this PC's list of
  /// every project id it has held (never sent).
  public CloudProjectsOwner(IProjects projects, CloudProjectFolders? folders, Func<bool?>? fullAccess = null, Action? projectsAdded = null, string? seenFile = null)
  {
    this.projects = projects; this.folders = folders; this.fullAccess = fullAccess ?? (() => false); this.projectsAdded = projectsAdded ?? (() => { });
    this.seenFile = seenFile;
    seen = new(StringComparer.Ordinal);
    if (seenFile is not null && File.Exists(seenFile))
      try { seen.UnionWith(JsonSerializer.Deserialize<List<string>>(File.ReadAllBytes(seenFile)) ?? []); } catch (JsonException) { }
  }

  public CloudRecordAdapter Adapter(CloudRecordStore store, string account, string deviceId, CloudRecordOrigins origins) =>
    new(DomainName, InventoryRowName, SourceIdName, [Kind], store, account, deviceId, this, origins, Exclusions);

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
  private static CloudJson.Object Travelling(Project project) => CloudRecordAdapter.Travelling(Record(project), CloudMergeTables.Project);
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
    return list.Where(p => p.Id != ProjectIdentity.IndependentId).ToDictionary(p => Kind.Entity(p.Id), Record, StringComparer.Ordinal);
  }

  public CloudRecordPlan CloudPlan(string entity, CloudJson.Object? cloud)
  {
    var id = Kind.IdOf(entity) ?? throw new CloudRecordRefusal("This is not a project record.");
    // Independent is each device's own.
    if (id == ProjectIdentity.IndependentId) return new(null);
    var list = projects.List();
    var current = list.FirstOrDefault(p => p.Id == id);
    var kept = Kept(current);
    // Removed on another device: nothing is deleted here. The project stays exactly as this PC has it.
    if (cloud is null) return new(kept);
    if (!ProjectIdentity.ValidId(id)) return new(kept, Waiting: "This project's id is not one this PC can use.");
    if (current is null && seen.Contains(id)) return new(null, Waiting: RemovedHere);
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
    if (!CloudRecordAdapter.Equal(Kept(current), expecting))
      throw new CloudRecordRefusal("This project changed on this PC while a change from another device was being applied; it is applied on the next try.");
    var icon = CloudRecordJson.Text(CloudRecordJson.Get(value, "icon")) ?? current?.Icon ?? "folder";
    var colour = CloudRecordJson.Text(CloudRecordJson.Get(value, "colour")) ?? current?.Colour;
    try
    {
      if (current is null)
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
    Refresh(projects.List());
  }

  public void CloudImported(IReadOnlyList<string> entities) { }

  public string CloudContext() => fullAccess() switch { true => "access:full", false => "access:ask", null => "access:?" };
}
