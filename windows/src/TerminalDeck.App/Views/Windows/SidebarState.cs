namespace TerminalDeck.App.Shell;

public sealed record SidebarPage(string Id, string Title, string Glyph);
public sealed record SidebarSaved(string[] Pages, string[] SessionPins, string[] SessionOrder, string[] HiddenSessions, double Width = 264, bool Visible = true, bool ConfirmDelete = true, string[]? ArchivedChats = null);

public sealed class SidebarState
{
  public static readonly SidebarPage[] Catalogue = [
    new("Agents", "Agents", "\uE902"), new("Tasks", "Tasks", "\uE8FD"),
    new("Artifacts", "Artifacts", "rich-document"), new("Projects", "Projects", "\uE8B7"),
    new("Servers", "Servers", "\uE968"), new("Devices", "Devices", "\uE975"),
    new("Receiver", "Receiver", "\uE704"), new("Mcp", "MCP servers", "\uEA86"),
    new("Files", "Files", "folder"), new("SourceControl", "Source control", "branch"),
    new("GitHub", "GitHub", "repository")
  ];
  private readonly Action<SidebarSaved>? persist;
  public SidebarSaved Read { get; private set; }
  public event Action? Changed;
  public SidebarState(SidebarSaved? saved, bool upgrading, Action<SidebarSaved>? persist = null)
  {
    this.persist = persist;
    if (saved is not null && (saved.Pages is null || saved.SessionPins is null || saved.SessionOrder is null || saved.HiddenSessions is null)) throw new ArgumentException("The saved sidebar is invalid.");
    // W11 displayed projects without writing sidebar.json. New default pins must
    // retain that section on upgrade; an explicit saved unpin still wins.
    var pages = saved?.Pages ?? ["Agents", "Tasks", "Projects"];
    Read = new(pages.Where(id => Catalogue.Any(p => p.Id == id)).Distinct().ToArray(),
      saved?.SessionPins.Distinct().ToArray() ?? [], saved?.SessionOrder.Distinct().ToArray() ?? [], saved?.HiddenSessions.Distinct().ToArray() ?? [],
      double.IsFinite(saved?.Width ?? 264) ? Math.Clamp(saved?.Width ?? 264, 240, 340) : 264, saved?.Visible ?? true, saved?.ConfirmDelete ?? true, saved?.ArchivedChats?.Distinct().ToArray() ?? []);
  }
  public bool IsArchived(string id) => Read.ArchivedChats?.Contains(id) == true;
  public void ArchiveChat(string id, bool archived)
  {
    if (IsArchived(id) == archived) return;
    var ids = (Read.ArchivedChats ?? []).Where(p => p != id).ToList();
    if (archived) ids.Add(id);
    Save(Read with { ArchivedChats = [.. ids] });
  }
  public bool Pinned(string id) => Read.Pages.Contains(id);
  public void Pin(string id, bool pinned)
  {
    if (!Catalogue.Any(p => p.Id == id)) throw new ArgumentException("Choose a page from More.");
    if (Pinned(id) == pinned) return;
    var pages = Read.Pages.Where(p => p != id).ToList();
    if (pinned) pages.Insert(Pinned(id) ? Array.IndexOf(Read.Pages, id) : pages.Count, id);
    Save(Read with { Pages = [.. pages] });
  }
  public void OrderPages(string[] ids)
  {
    if (ids.Length != Read.Pages.Length || ids.Distinct().Count() != ids.Length || !ids.ToHashSet().SetEquals(Read.Pages)) throw new ArgumentException("Keep each pinned page exactly once.");
    Save(Read with { Pages = [.. ids] });
  }
  public void MovePage(string source, string target)
  {
    if (!Pinned(source) || !Pinned(target) || source == target) return;
    var ids = Read.Pages.ToList(); var index = ids.IndexOf(target); ids.Remove(source); ids.Insert(index, source); OrderPages([.. ids]);
  }
  public void PinSession(string id, bool pinned)
  {
    if (Read.SessionPins.Contains(id) == pinned) return;
    var ids = Read.SessionPins.Where(p => p != id).ToList(); if (pinned) ids.Add(id); Save(Read with { SessionPins = [.. ids] });
  }
  public void MoveSession(string id, string target)
  {
    var ids = Read.SessionOrder.ToList(); if (!ids.Contains(target)) ids.Add(target);
    var index = ids.IndexOf(target); ids.Remove(id); ids.Insert(Math.Min(index, ids.Count), id); Save(Read with { SessionOrder = [.. ids] });
  }
  public void OrderSessions(string[] ids)
  {
    if (ids.Distinct().Count() != ids.Length) throw new ArgumentException("Keep each session once.");
    Save(Read with { SessionOrder = ids.Where(id => !Read.SessionPins.Contains(id)).ToArray(), SessionPins = ids.Where(id => Read.SessionPins.Contains(id)).Concat(Read.SessionPins.Where(id => !ids.Contains(id))).ToArray() });
  }
  public void HideSession(string id, bool hidden)
  {
    if (Read.HiddenSessions.Contains(id) == hidden) return;
    var ids = Read.HiddenSessions.Where(p => p != id).ToList(); if (hidden) ids.Add(id); Save(Read with { HiddenSessions = [.. ids] });
  }
  public IEnumerable<T> Sort<T>(IEnumerable<T> rows, Func<T, string> id) => rows.OrderBy(row => Read.SessionPins.Contains(id(row)) ? 0 : 1)
    .ThenBy(row => { var order = Read.SessionPins.Contains(id(row)) ? Read.SessionPins : Read.SessionOrder; var at = Array.IndexOf(order, id(row)); return at < 0 ? int.MaxValue : at; });
  public void Geometry(double width, bool visible)
  {
    if (!double.IsFinite(width)) throw new ArgumentException("Use a finite sidebar width.");
    var fitted = Math.Clamp(width, 240, 340);
    if (Read.Width == fitted && Read.Visible == visible) return;
    Save(Read with { Width = fitted, Visible = visible });
  }
  public void AskBeforeDelete(bool ask) => Save(Read with { ConfirmDelete = ask });
  private void Save(SidebarSaved next) { persist?.Invoke(next); Read = next; Changed?.Invoke(); }
}
