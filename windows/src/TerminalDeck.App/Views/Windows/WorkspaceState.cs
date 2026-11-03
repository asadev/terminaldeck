using System.Text.Json;

namespace TerminalDeck.App.Shell;

public sealed record WorkspaceTab(string Id, string Owner, string Subject, string Kind, string Title, string Host = "main", bool CustomTitle = false, bool ExplicitPage = false);
public sealed record PaneTree(string? Tab = null, PaneTree? First = null, PaneTree? Second = null, bool Vertical = false, double Ratio = 0.5, string? EmptyId = null)
{
  public IEnumerable<string> EmptyIds => EmptyId is { } id ? [id] : (First?.EmptyIds ?? []).Concat(Second?.EmptyIds ?? []);
  public IEnumerable<string> Tabs => EmptyId is not null ? [] : Tab is not null ? [Tab] : (First?.Tabs ?? []).Concat(Second?.Tabs ?? []);
  public PaneTree? Remove(string id)
  {
    if (EmptyId is not null) return EmptyId == id ? null : this;
    if (Tab is not null) return Tab == id ? null : this;
    var a = First?.Remove(id); var b = Second?.Remove(id);
    return a is null ? b : b is null ? a : this with { First = a, Second = b };
  }
  public PaneTree Split(string target, string added, bool vertical) => Tab is not null
    ? Tab == target ? new(First: this, Second: new(added), Vertical: vertical) : this
    : EmptyId == target ? new(added) : this with { First = First?.Split(target, added, vertical), Second = Second?.Split(target, added, vertical) };
  public PaneTree Resize(string target, double ratio) => Tabs.Contains(target) && Tab is null
    ? this with { Ratio = Math.Clamp(ratio, 0.15, 0.85) } : this;
}
public sealed record WorkspaceLayout(string Owner, string Host, string? Active, PaneTree? Root, PaneTree? SavedSplit = null, string? ActiveEmpty = null, bool Solo = false);
public sealed record WorkspaceSaved(WorkspaceTab[] Tabs, WorkspaceLayout[] Layouts, string[]? ClosedTabs = null);

// One source for title-bar tabs, split panes and detached windows. Closing a
// view never stops a keeper process; Stop remains a separate, explicit action.
public sealed class WorkspaceState
{
  private readonly List<WorkspaceTab> tabs = [];
  private readonly List<WorkspaceLayout> layouts = [];
  private readonly Action<WorkspaceSaved>? save;
  private readonly HashSet<string> closed = [];
  private WorkspaceSaved committed = new([], []);
  private HashSet<string> swarmMembers = [];
  private HashSet<string> committedSwarmMembers = [];
  public const string HootPageTab = "page:Hoot";
  public bool IsClosed(string id) => closed.Contains(id);
  public void Reveal(string id) => closed.Remove(id);
  public IReadOnlyList<WorkspaceTab> Tabs => tabs;
  public IReadOnlyList<WorkspaceLayout> Layouts => layouts;
  public event Action? Changed;
  public WorkspaceState(WorkspaceSaved? saved = null, Action<WorkspaceSaved>? persist = null)
  {
    save = persist;
    if (saved is not null)
    {
      if (saved.Tabs is null || saved.Layouts is null || saved.Tabs.Any(t => t is null || string.IsNullOrWhiteSpace(t.Id) || string.IsNullOrWhiteSpace(t.Owner) || t.Kind is not ("page" or "terminal" or "chat" or "browser") || t.Title is null)) throw new ArgumentException("The saved layout is invalid.");
      bool ValidTree(PaneTree? node, int depth = 0)
      {
        if (node is null) return true;
        if (depth > 32 || !double.IsFinite(node.Ratio) || node.Ratio < 0.15 || node.Ratio > 0.85) return false;
        if (node.Tab is not null || node.EmptyId is not null) return node.First is null && node.Second is null && !(node.Tab is not null && node.EmptyId is not null);
        return node.First is not null && node.Second is not null && ValidTree(node.First, depth + 1) && ValidTree(node.Second, depth + 1);
      }
      if (saved.Layouts.Any(l => l is null || !ValidTree(l.Root) || !ValidTree(l.SavedSplit) || (l.Root?.Tabs.Count() ?? 0) != (l.Root?.Tabs.Distinct().Count() ?? 0))) throw new ArgumentException("The saved pane arrangement is invalid.");
      closed.UnionWith(saved.ClosedTabs ?? []);
      // App window handles do not survive a restart. Their views return home.
      // Hoot's page never comes back by itself, even moved to a tab or window: Hoot stays closed until
      // the person opens it (Asad, 3 Nov).
      tabs.AddRange(saved.Tabs.Where(t => (t.Kind != "page" || t.ExplicitPage) && t.Id != HootPageTab).DistinctBy(t => t.Id).Select(t => t with { Host = "main" }));
      foreach (var layout in saved.Layouts.Where(l => l.Host == "main"))
      {
        var root = layout.Root;
        foreach (var id in root?.Tabs.ToArray() ?? []) if (!tabs.Any(t => t.Id == id)) root = root?.Remove(id);
        var savedSplit = layout.SavedSplit;
        foreach (var id in savedSplit?.Tabs.ToArray() ?? []) if (!tabs.Any(t => t.Id == id)) savedSplit = savedSplit?.Remove(id);
        layouts.Add(layout with { Root = root, SavedSplit = savedSplit, Active = root?.Tabs.Contains(layout.Active ?? "") == true ? layout.Active : root?.Tabs.FirstOrDefault() });
      }
    }
    committed = Snapshot();
  }
  public WorkspaceTab Get(string id) => tabs.FirstOrDefault(t => t.Id == id) ?? throw new ArgumentException("Choose an open window tab.");
  public string OwnerOf(string session) => tabs.FirstOrDefault(t => t.Subject == session && t.Kind != "browser")?.Owner ?? session;
  public WorkspaceLayout Layout(string owner, string host = "main") => layouts.FirstOrDefault(l => l.Owner == owner && l.Host == host) ?? new(owner, host, null, null);
  public string CreationOwner(string owner, string host = "main")
  {
    var active = Layout(owner, host).Active;
    var tab = tabs.FirstOrDefault(t => t.Id == active);
    return tab is null || tab.Kind == "page" ? "" : tab.Owner;
  }
  public void Ensure(string id, string owner, string subject, string kind, string title, bool explicitPage = false)
  {
    if (closed.Contains(id)) return;
    var index = tabs.FindIndex(t => t.Id == id);
    if (index < 0) { tabs.Add(new(id, owner, subject, kind, title, ExplicitPage: explicitPage)); Publish(); }
    else
    {
      if (explicitPage && !tabs[index].ExplicitPage) { tabs[index] = tabs[index] with { ExplicitPage = true }; Publish(); }
      if (kind == "browser" && tabs[index].Owner != owner) { Adopt(id, owner); index = tabs.FindIndex(t => t.Id == id); }
      if (tabs[index].Title != title && !tabs[index].CustomTitle) { tabs[index] = tabs[index] with { Title = title }; Publish(); }
    }
  }
  private readonly HashSet<string> renamed = [];
  public void Adopt(string id, string owner)
  {
    var tab = Get(id);
    if (tab.Owner == owner) return;
    tabs[tabs.IndexOf(tab)] = tab with { Owner = owner };
    foreach (var layout in layouts.ToArray())
    {
      var root = layout.Root?.Remove(id);
      Put(layout with { Root = root, Active = layout.Active == id ? root?.Tabs.FirstOrDefault() : layout.Active });
    }
    Select(id);
  }
  private PaneTree? ExistingSplit(PaneTree? root)
  {
    foreach (var id in root?.Tabs.ToArray() ?? []) if (!tabs.Any(tab => tab.Id == id)) root = root?.Remove(id);
    return root;
  }
  public void Select(string id)
  {
    var tab = Get(id); var layout = Layout(tab.Owner, tab.Host); var saved = ExistingSplit(layout.SavedSplit);
    if (layout.Root?.Tabs.Contains(id) == true) Put(layout with { Active = id, ActiveEmpty = null });
    else if (!layout.Solo && saved?.Tabs.Contains(id) == true) Put(layout with { Active = id, Root = saved, SavedSplit = null, ActiveEmpty = null });
    else Put(layout with { Active = id, Root = new(id), SavedSplit = layout.Root?.Tab is null ? layout.Root ?? saved : saved, ActiveEmpty = null });
    Publish();
  }
  public void Focus(string id, string? owner = null, string? host = null)
  {
    var tab = Get(id); var layout = Layout(owner ?? tab.Owner, host ?? tab.Host);
    if (layout.Active == id && layout.ActiveEmpty is null) return;
    Put(layout with { Active = id, ActiveEmpty = null }); Publish();
  }
  public void Split(string current, string added, bool vertical = false, string? owner = null, string? host = null)
  {
    if (current == added) throw new ArgumentException("Choose another window for the split.");
    var tab = Get(current); var other = Get(added);
    if (tab.Kind == "page" || other.Kind == "page") throw new ArgumentException("Choose session or browser tabs for a split.");
    if (other.Host != tab.Host) throw new ArgumentException("Bring this window back before adding it to a split.");
    var layout = Layout(owner ?? tab.Owner, host ?? tab.Host);
    var root = layout.Root ?? new(current);
    if (!root.Tabs.Contains(current)) root = new(current);
    root = root.Remove(added) ?? new(current);
    Put(layout with { Active = added, Root = root.Split(current, added, vertical), ActiveEmpty = null, Solo = false }); Publish();
  }
  public void EmptySplit(string current, bool vertical = false, string? owner = null, string? host = null)
  {
    var tab = Get(current); if (tab.Kind == "page") throw new ArgumentException("Choose a session or browser tab for a split.");
    var layout = Layout(owner ?? tab.Owner, host ?? tab.Host);
    var emptyId = "empty:" + Guid.NewGuid().ToString("N");
    PaneTree? Add(PaneTree? node) => node is null ? null : node.Tab == current ? new(First: node, Second: new(EmptyId: emptyId), Vertical: vertical)
      : node with { First = Add(node.First), Second = Add(node.Second) };
    Put(layout with { Root = Add(layout.Root ?? new(current)), Active = current }); Publish();
  }
  public void FocusEmpty(string owner, string host, string emptyId)
  {
    var layout = Layout(owner, host);
    if (!(layout.Root?.EmptyIds.Contains(emptyId) ?? false)) throw new ArgumentException("Choose an empty pane in this window.");
    if (layout.ActiveEmpty == emptyId) return;
    Put(layout with { ActiveEmpty = emptyId }); Publish();
  }
  public void FillEmpty(string owner, string host, string emptyId, string id)
  {
    var tab = Get(id); if (tab.Host != host || tab.Kind == "page") throw new ArgumentException("Choose a session or browser in this window.");
    var layout = Layout(owner, host);
    if (!(layout.Root?.EmptyIds.Contains(emptyId) ?? false)) throw new ArgumentException("Choose an empty pane in this window.");
    var root = layout.Root?.Remove(id);
    PaneTree? Fill(PaneTree? node) => node is null ? null : node.EmptyId == emptyId ? new(id) : node with { First = Fill(node.First), Second = Fill(node.Second) };
    Put(layout with { Root = Fill(root), Active = id, ActiveEmpty = null }); Publish();
  }
  public void One(string id, string? owner = null, string? host = null)
  {
    var tab = Get(id); var layout = Layout(owner ?? tab.Owner, host ?? tab.Host);
    Put(layout with { Active = id, Root = new(id), ActiveEmpty = null, Solo = true, SavedSplit = layout.Root?.Tab is null ? layout.Root : layout.SavedSplit }); Publish();
  }
  public bool RestoreSplit(string owner, string host = "main")
  {
    var layout = Layout(owner, host); var root = ExistingSplit(layout.SavedSplit);
    if (root?.Tab is not null || root is null || root.EmptyId is not null) return false;
    Put(layout with { Root = root, Active = root.Tabs.Contains(layout.Active ?? "") ? layout.Active : root.Tabs.First(), SavedSplit = null, Solo = false }); Publish(); return true;
  }
  public void Swap(string owner, string host, string source, string target)
  {
    var layout = Layout(owner, host);
    if (!(layout.Root?.Tabs.Contains(source) ?? false) || !layout.Root.Tabs.Contains(target)) throw new ArgumentException("Choose two visible panes.");
    PaneTree? Replace(PaneTree? node) => node is null ? null : node.Tab is { } id ? node with { Tab = id == source ? target : id == target ? source : id } : node with { First = Replace(node.First), Second = Replace(node.Second) };
    Put(layout with { Root = Replace(layout.Root) }); Publish();
  }
  public void MovePane(string owner, string host, string source, string target, string edge)
  {
    if (source == target) return;
    if (edge == "swap") { Swap(owner, host, source, target); return; }
    if (edge is not ("left" or "right" or "above" or "below")) throw new ArgumentException("Choose a pane edge.");
    var layout = Layout(owner, host);
    if (!(layout.Root?.Tabs.Contains(source) ?? false) || !layout.Root.Tabs.Contains(target)) throw new ArgumentException("Choose two visible panes.");
    var root = layout.Root.Remove(source);
    PaneTree? Insert(PaneTree? node) => node is null ? null : node.Tab == target
      ? edge is "left" or "above" ? new(First: new(source), Second: node, Vertical: edge == "above") : new(First: node, Second: new(source), Vertical: edge == "below")
      : node with { First = Insert(node.First), Second = Insert(node.Second) };
    Put(layout with { Root = Insert(root), Active = source, ActiveEmpty = null }); Publish();
  }
  public void Swarm(string[] ids)
  {
    if (ids.Any(id => Get(id).Kind is not ("terminal" or "chat"))) throw new ArgumentException("Choose session tabs for Swarm View.");
    PaneTree? Arrange(string[] members, bool vertical) => members.Length == 0 ? null : members.Length == 1 ? new(members[0])
      : new(First: Arrange(members[..((members.Length + 1) / 2)], !vertical), Second: Arrange(members[((members.Length + 1) / 2)..], !vertical), Vertical: vertical);
    swarmMembers = ids.ToHashSet();
    Put(new("swarm", "main", ids.FirstOrDefault(), Arrange(ids.Distinct().ToArray(), false))); Publish();
  }
  public void RefreshSwarm(string[] ids)
  {
    if (swarmMembers.SetEquals(ids)) return;
    var active = Layout("swarm").Active; Swarm(ids);
    if (active is not null && ids.Contains(active)) Focus(active, "swarm", "main");
  }
  public void ClosePane(string owner, string host, string id)
  {
    var layout = Layout(owner, host); var root = layout.Root?.Remove(id);
    Put(layout with { Root = root, Active = layout.Active == id ? root?.Tabs.FirstOrDefault() : layout.Active, ActiveEmpty = layout.ActiveEmpty == id ? null : layout.ActiveEmpty }); Publish();
  }
  public void Resize(string owner, string host, PaneTree node, double ratio)
  {
    PaneTree? Replace(PaneTree? tree) => tree is null ? null : ReferenceEquals(tree, node) ? tree with { Ratio = Math.Clamp(ratio, 0.15, 0.85) }
      : tree with { First = Replace(tree.First), Second = Replace(tree.Second) };
    var layout = Layout(owner, host); Put(layout with { Root = Replace(layout.Root) }); Publish();
  }
  public void Rename(string id, string title)
  {
    if (string.IsNullOrWhiteSpace(title) || title.Length > 120 || title.Any(char.IsControl)) throw new ArgumentException("Use a name of 1–120 characters on one line.");
    var tab = Get(id); tabs[tabs.IndexOf(tab)] = tab with { Title = title.Trim(), CustomTitle = true }; renamed.Add(id); Publish();
  }
  public void Move(string id, int index)
  {
    var tab = Get(id); var peers = tabs.Where(t => t.Host == tab.Host).ToList();
    peers.Remove(tab); peers.Insert(Math.Clamp(index, 0, peers.Count), tab);
    var slots = tabs.Select((t, i) => (t, i)).Where(p => p.t.Host == tab.Host).Select(p => p.i).ToArray();
    for (var i = 0; i < slots.Length; i++) tabs[slots[i]] = peers[i]; Publish();
  }
  public void Transfer(string id, string host)
  {
    var tab = Get(id);
    if (tab.Host == host) return;
    foreach (var layout in layouts.ToArray())
    {
      // A split keeps a discoverable placeholder for its detached browser.
      // It never owns the WebView; the destination host owns that one visual.
      var placeholder = tab.Kind == "browser" && (layout.Host == tab.Host || layout.Host == host) && layout.Root?.Tab is null && (layout.Root?.Tabs.Contains(id) ?? false);
      var root = placeholder ? layout.Root : layout.Root?.Remove(id);
      Put(layout with { Root = root, Active = layout.Active == id ? root?.Tabs.FirstOrDefault(candidate => candidate != id && tabs.Any(t => t.Id == candidate && t.Host == layout.Host)) : layout.Active });
    }
    tabs[tabs.IndexOf(tab)] = tab with { Host = host }; Select(id);
  }
  public void TransferSession(string owner, string from, string to)
  {
    if (from == to) return;
    var members = tabs.Where(t => t.Owner == owner && t.Host == from).Select(t => t.Id).ToHashSet();
    if (members.Count == 0) return;
    var original = Layout(owner, from);
    var retained = original.Root;
    foreach (var id in retained?.Tabs.ToArray() ?? []) if (!members.Contains(id)) retained = retained?.Remove(id);
    foreach (var layout in layouts.ToArray())
    {
      var root = layout.Root;
      foreach (var id in members) root = root?.Remove(id);
      Put(layout with { Root = root, Active = members.Contains(layout.Active ?? "") ? root?.Tabs.FirstOrDefault() : layout.Active });
    }
    for (var i = 0; i < tabs.Count; i++) if (members.Contains(tabs[i].Id)) tabs[i] = tabs[i] with { Host = to };
    var active = members.Contains(original.Active ?? "") ? original.Active : members.First();
    Put(new(owner, to, active, retained ?? new(active))); Publish();
  }
  public void Close(string id)
  {
    var tab = Get(id); tabs.Remove(tab); renamed.Remove(id); closed.Add(id);
    foreach (var layout in layouts.ToArray())
    {
      var root = layout.Root?.Remove(id);
      var fallback = tabs.FirstOrDefault(t => t.Owner == layout.Owner && t.Host == layout.Host)?.Id;
      if (root is null && fallback is not null) root = new(fallback);
      Put(layout with { Root = root, Active = layout.Active == id ? root?.Tabs.FirstOrDefault() : layout.Active });
    }
    Publish();
  }
  public string? Step(string owner, string host, int delta, bool panes = false, bool allTabs = false)
  {
    var layout = Layout(owner, host);
    var ids = panes ? layout.Root?.Tabs.ToArray() ?? [] : tabs.Where(t => (allTabs || t.Owner == owner) && t.Host == host).Select(t => t.Id).ToArray();
    if (ids.Length == 0) return null;
    return ids[(Math.Max(0, Array.IndexOf(ids, layout.Active)) + delta + ids.Length) % ids.Length];
  }
  private void Put(WorkspaceLayout layout) { layouts.RemoveAll(l => l.Owner == layout.Owner && l.Host == layout.Host); layouts.Add(layout); }
  private WorkspaceSaved Snapshot() => new([.. tabs], [.. layouts], [.. closed]);
  private void Publish()
  {
    var next = Snapshot();
    try { save?.Invoke(next); }
    catch
    {
      tabs.Clear(); tabs.AddRange(committed.Tabs); layouts.Clear(); layouts.AddRange(committed.Layouts);
      closed.Clear(); closed.UnionWith(committed.ClosedTabs ?? []); swarmMembers = new(committedSwarmMembers); throw;
    }
    committed = next; committedSwarmMembers = new(swarmMembers); Changed?.Invoke();
  }
}
