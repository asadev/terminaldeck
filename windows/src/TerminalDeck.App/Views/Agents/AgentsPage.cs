using System.Collections.Immutable;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using System.Text.Json;
using Windows.ApplicationModel.DataTransfer;
using TerminalDeck.App.ViewModels.Agents;
using TerminalDeck.App.Views.Projects;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Agents;

// The Agents page in the Mac's layout (AGFRAMEAgentsPage + AGTProfileView): a directory
// of cards or a list, an org chart grouped by project with reporting lines, and a
// profile per agent. A lead with a big team filters by project, role and status here.
public sealed partial class AgentsPage : Grid
{
  public AgentsViewModel Model { get; }
  private readonly IProjectsAgentsNavigation navigation;
  private readonly Action changed;
  private string query = "";
  private string grouping = "All agents";
  private string layout = "Cards";
  private string? projectFilter;
  private string roleFilter = "";
  private string stateFilter = "";
  private bool archived;
  private bool orgSearchOpen = true;
  private float chartZoom = 1;
  private ScrollViewer? chartScroll;
  private FrameworkElement? chartContent;
  private sealed record AgentDrag(string Id, string Owner);
  private AutoSuggestBox? find;
  private string profileTab = "Dashboard";
  public AgentsPage(AgentsViewModel model, IProjectsAgentsNavigation navigation)
  {
    Model = model; this.navigation = navigation; Style = PageStyle(); var dispatcher = DispatcherQueue; changed = () => dispatcher.TryEnqueueHandled(Render);
    if (navigation is IAgentSessionsSource live) model.Sessions = live.AgentSessions;
    Loaded += (_, _) => { model.Changed += changed; if (navigation is IAgentRoutinesNavigation routines) routines.AgentRoutines.Changed += changed; Render(); }; Unloaded += (_, _) => { model.Changed -= changed; if (navigation is IAgentRoutinesNavigation routines) routines.AgentRoutines.Changed -= changed; }; Render();
    void Shortcut(VirtualKey key, Action action, VirtualKeyModifiers modifiers = VirtualKeyModifiers.Control)
    {
      var shortcut = new KeyboardAccelerator { Key = key, Modifiers = modifiers, ScopeOwner = this };
      shortcut.Invoked += (_, e) => { if (!IsLoaded) return; action(); e.Handled = true; }; KeyboardAccelerators.Add(shortcut);
    }
    Shortcut(VirtualKey.F, () => { if (Model.SelectedId is not null) { Model.SelectedId = null; grouping = "All agents"; } orgSearchOpen = true; Render(); find?.Focus(FocusState.Keyboard); });
    Shortcut(VirtualKey.N, () => _ = AgentEditors.HireAsync(XamlRoot, Model.Agents, Model.Projects, navigation, Model, Model.Selected?.ProjectId ?? projectFilter));
    Shortcut(VirtualKey.Number1, () => { Model.SelectedId = null; grouping = "All agents"; Render(); });
    Shortcut(VirtualKey.Number2, () => { Model.SelectedId = null; grouping = "Org chart"; Render(); });
    Shortcut((VirtualKey)219, () => { Model.SelectedId = null; Render(); });
    // Org chart zoom: Ctrl+minus, Ctrl+plus, Ctrl+0 fits (Mac: Cmd-minus, Cmd-plus, Cmd-0).
    foreach (var key in new[] { (VirtualKey)189, VirtualKey.Subtract }) Shortcut(key, () => Zoom(chartZoom / 1.25f));
    foreach (var key in new[] { (VirtualKey)187, VirtualKey.Add }) Shortcut(key, () => Zoom(chartZoom * 1.25f));
    Shortcut(VirtualKey.Number0, FitChart);
    ProjectsAgentsParityProof.Start(navigation);
  }
  private Task OpenTemplatesAsync() => navigation is ISettingsPageNavigation settings ? settings.OpenSettingsAsync("agent-defaults") : AgentEditors.TemplatesAsync(XamlRoot, Model.Agents, Model);
  public void OpenAgent(string id) { profileTab = "Dashboard"; Model.SelectedId = id; Render(); }
  private void Render()
  {
    Children.Clear(); chartScroll = null; chartContent = null;
    var body = Stack(28); body.Margin = new Thickness(24, 20, 24, 32); body.MaxWidth = grouping == "Org chart" && Model.SelectedId is null ? 1600 : 1120;
    if (Model.SelectedId == AgentSeats.HootId) Hoot(body);
    else if (Model.Selected is { } agent) Profile(body, agent);
    else if (Model.SelectedId is not null)
    {
      body.Children.Add(Heading("Agent not found", 22)); body.Children.Add(Words("This agent may have been removed. Its saved role memory is kept.", muted: true));
      body.Children.Add(Button("Back to Agents", () => Model.SelectedId = null));
    }
    else Directory(body);
    if (Model.IsBusy) body.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 3 });
    if (Model.Message.Length > 0) body.Children.Add(new TerminalDeck.App.Views.Notices.CompactNotice { IsOpen = true, IsClosable = false, Severity = Model.IsError ? InfoBarSeverity.Error : InfoBarSeverity.Informational, Message = Model.Message });
    Children.Add(PageFrame(body));
  }

  // ---------- Directory ----------
  private static Brush Resource(string key) => (Brush)Application.Current.Resources[key];
  private static Brush StateBrush(AgentActivityState state) => Resource(state switch
  {
    AgentActivityState.Working => "SystemFillColorSuccessBrush",
    AgentActivityState.Idle => "SystemFillColorCautionBrush",
    AgentActivityState.Open => "SystemFillColorAttentionBrush",
    AgentActivityState.Paused => "SystemFillColorCriticalBrush",
    _ => "TextFillColorTertiaryBrush"
  });
  private UIElement StatusLine(SavedAgent agent, double size = 12)
  {
    var activity = Model.Activity(agent);
    var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
    row.Children.Add(new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(4), Background = StateBrush(activity.State), VerticalAlignment = VerticalAlignment.Center });
    row.Children.Add(Words(activity.Label, size, true));
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, "Status: " + activity.Label); return row;
  }
  private ComboBox Filter(string label, IEnumerable<(string Id, string Name)> options, string selected, Action<string> chosen)
  {
    var box = Choice(label, options, selected); box.Header = null; box.MinHeight = 28; box.FontSize = 12; box.MinWidth = 140; box.MaxWidth = 220;
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, label);
    box.SelectionChanged += (_, _) => chosen(Picked(box)); return box;
  }
  private IReadOnlyList<SavedAgent> Rows() => Model.Filter(query, projectFilter, archived, roleFilter, stateFilter);
  private void Directory(StackPanel body)
  {
    var switcher = ViewSwitch(grouping, new[] { "All agents", "Org chart", "Routines" }, name => { grouping = name; Render(); });
    var all = Model.Agents.List().Where(a => a.Status != SavedAgentStatus.Archived).ToArray();
    var working = all.Count(a => Model.Activity(a).State == AgentActivityState.Working);
    body.Children.Add(PageHeader("Agents", $"{all.Length} {(all.Length == 1 ? "agent" : "agents")} · {working} working now", null, switcher,
      AsyncButton("Templates", OpenTemplatesAsync),
      AsyncButton("New agent", () => AgentEditors.HireAsync(XamlRoot, Model.Agents, Model.Projects, navigation, Model, projectFilter), true)));
    if (grouping == "Routines") { RoutinesTab(body, null); return; }
    var filters = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    filters.Children.Add(Filter("Project", new[] { ("", "All projects") }.Concat(Model.Projects.List().Select(p => (p.Id, p.Name))), projectFilter ?? "", id => { projectFilter = id.Length > 0 ? id : null; roleFilter = ""; Render(); }));
    filters.Children.Add(Filter("Role", new[] { ("", "All roles"), ("lead", "Project leads") }.Concat(Model.Roles(projectFilter).Select(r => ("role:" + r, r.Replace('-', ' ')))), roleFilter, id => { roleFilter = id; Render(); }));
    filters.Children.Add(Filter("Status", new[] { ("", "Any status"), ("Working", "Working"), ("Idle", "Idle"), ("Open", "Session open"), ("Ready", "Ready"), ("Paused", "Paused") }, stateFilter, id => { stateFilter = id; Render(); }));
    var archivedToggle = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = "Archived", IsChecked = archived, MinHeight = 28 };
    archivedToggle.Click += (_, _) => { archived = archivedToggle.IsChecked == true; Render(); }; filters.Children.Add(archivedToggle);
    if (grouping == "All agents") filters.Children.Add(ViewSwitch(layout, new[] { "Cards", "List" }, name => { layout = name; Render(); }));
    var search = new AutoSuggestBox { PlaceholderText = "Find an agent, role or model", Text = query, MinWidth = 240, MaxWidth = 320, HorizontalAlignment = HorizontalAlignment.Left };
    find = search;
    var tools = new Grid { ColumnSpacing = 12, RowSpacing = 8 };
    tools.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); tools.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    tools.RowDefinitions.Add(new() { Height = GridLength.Auto }); tools.RowDefinitions.Add(new() { Height = GridLength.Auto });
    var filterScroll = new ScrollViewer { Content = filters, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollMode = ScrollMode.Disabled };
    tools.Children.Add(search); Grid.SetColumn(filterScroll, 1); tools.Children.Add(filterScroll);
    tools.SizeChanged += (_, _) => { var narrow = tools.ActualWidth < 900; Grid.SetRow(filterScroll, narrow ? 1 : 0); Grid.SetColumn(filterScroll, narrow ? 0 : 1); Grid.SetColumnSpan(filterScroll, narrow ? 2 : 1); };
    body.Children.Add(tools);
    var list = Stack(12);
    if (grouping == "All agents")
    {
      void Fill()
      {
        list.Children.Clear();
        var rows = Rows();
        foreach (var group in rows.GroupBy(a => a.ProjectId).OrderBy(g => g.Key == ProjectIdentity.IndependentId).ThenBy(g => Model.ProjectName(g.Key), StringComparer.CurrentCultureIgnoreCase))
        {
          list.Children.Add(ProjectHeading(group.Key, group.Count()));
          var ordered = group.OrderByDescending(Model.IsLead).ThenBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
          if (layout == "Cards")
          {
            var cards = ordered.Select(a => (UIElement)AgentCard(a, true)).ToList();
            if (query.Length == 0 && roleFilter.Length == 0 && stateFilter.Length == 0 && !archived) cards.AddRange(Model.VacantSeats(group.Key).Select(VacantCard));
            list.Children.Add(AdaptiveColumns(cards, 250));
          }
          else
          {
            var table = Stack(0); table.Children.Add(AgentTableRow(null));
            foreach (var row in ordered) table.Children.Add(AgentListRow(row));
            // A narrow window scrolls the table alone, never the whole page.
            table.MinWidth = 900;
            list.Children.Add(new ScrollViewer { Content = table, HorizontalScrollMode = ScrollMode.Enabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Disabled, HorizontalContentAlignment = HorizontalAlignment.Stretch });
          }
        }
        if (rows.Count == 0) list.Children.Add(Words(query.Length == 0 && roleFilter.Length == 0 && stateFilter.Length == 0 ? "No saved agents yet. Add a role when there is work for it." : "No agents match that search or filter.", muted: true));
      }
      search.TextChanged += (_, _) => { query = search.Text; Fill(); }; Fill();
    }
    else OrgChart(body, list, search);
    body.Children.Add(list);
  }
  private FrameworkElement ProjectHeading(string projectId, int count)
  {
    var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Margin = new Thickness(0, 8, 0, 0) };
    var project = Model.Projects.List().FirstOrDefault(p => p.Id == projectId);
    if (project is not null) row.Children.Add(ProjectPicture(Model.Projects, project, 22));
    var title = Heading(Model.ProjectName(projectId) + " · " + count + (count == 1 ? " agent" : " agents"), 15); title.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(title);
    if (project?.LeadName is { Length: > 0 } lead) { var led = Words("Lead: " + lead, 12, true); led.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(led); }
    return row;
  }
  private Button AgentListRow(SavedAgent agent)
  {
    var row = Destination(AgentTableRow(agent), "Open " + agent.Name, () => OpenAgent(agent.Id)); row.ContextFlyout = AgentMenu(agent); MatchFlyoutTheme(row, row.ContextFlyout); return row;
  }
  private Grid AgentTableRow(SavedAgent? agent)
  {
    var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(12, 8, 12, 8) };
    foreach (var width in new[] { new GridLength(1, GridUnitType.Star), new GridLength(120), new GridLength(120), new GridLength(130), new GridLength(160), new GridLength(120) }) row.ColumnDefinitions.Add(new() { Width = width });
    void Cell(FrameworkElement element, int column) { Grid.SetColumn(element, column); row.Children.Add(element); }
    if (agent is null)
    {
      var labels = new[] { "Name", "Project", "Role", "Status", "Doing now", "Model" };
      for (var i = 0; i < labels.Length; i++) Cell(Words(labels[i], 11, true), i);
      return row;
    }
    var identity = new Grid { ColumnSpacing = 8 };
    identity.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); identity.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    identity.Children.Add(AgentPicture(agent, 22)); var name = Heading(agent.Name, 13); name.MaxLines = 1; name.TextTrimming = TextTrimming.CharacterEllipsis; Grid.SetColumn(name, 1); identity.Children.Add(name); Cell(identity, 0);
    Cell(Words(Model.ProjectName(agent.ProjectId), 12, true), 1);
    var role = Words(Model.RoleName(agent), 12, true); role.MaxLines = 1; role.TextTrimming = TextTrimming.CharacterEllipsis; Cell(role, 2);
    Cell((FrameworkElement)StatusLine(agent), 3);
    var hands = Model.Hands(agent.Id);
    var job = Words(hands.FirstOrDefault()?.Job is { Length: > 0 } title ? title : hands.Count > 0 ? "Hand " + hands[0].HandNumber : "—", 12, true); job.MaxLines = 1; job.TextTrimming = TextTrimming.CharacterEllipsis; Cell(job, 4);
    Cell(Words(AppWideModel(agent), 12, true), 5);
    return row;
  }
  private Border AgentCard(SavedAgent agent, bool compact = false)
  {
    var content = Stack(8);
    var identity = new Grid { ColumnSpacing = 10 };
    identity.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); identity.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    identity.Children.Add(AgentPicture(agent, 34));
    var title = Stack(2); var name = Heading(agent.Name, 13); name.MaxLines = 1; name.TextTrimming = TextTrimming.CharacterEllipsis; title.Children.Add(name);
    var role = Words(Model.IsLead(agent) ? "Lead · " + Model.ProjectName(agent.ProjectId) : AgentsViewModel.RoleWords(agent.Seat), 12, true); role.MaxLines = 1; role.TextTrimming = TextTrimming.CharacterEllipsis; title.Children.Add(role);
    Grid.SetColumn(title, 1); identity.Children.Add(title); content.Children.Add(identity);
    content.Children.Add(StatusLine(agent));
    var hands = Model.Hands(agent.Id);
    if (hands.FirstOrDefault()?.Job is { Length: > 0 } job) { var doing = Words("Doing: " + job, 11, true); doing.MaxLines = 1; doing.TextTrimming = TextTrimming.CharacterEllipsis; content.Children.Add(doing); }
    var detail = Words((compact && grouping == "Org chart" ? "" : Model.ProjectName(agent.ProjectId) + " · ") + AppWideModel(agent, effort: false), 11, true);
    detail.MaxLines = 1; detail.TextTrimming = TextTrimming.CharacterEllipsis; content.Children.Add(detail);
    var card = Card(Destination(content, "Open " + agent.Name, () => OpenAgent(agent.Id))); card.ContextFlyout = AgentMenu(agent); MatchFlyoutTheme(card, card.ContextFlyout);
    if (grouping == "Org chart")
    {
      card.CanDrag = true; card.DragStarting += (_, e) => { e.Data.SetData("TerminalDeck.Agent", JsonSerializer.Serialize(new AgentDrag(agent.Id, Model.DragScope))); e.Data.RequestedOperation = DataPackageOperation.Move; };
      ManagerDropTarget(card, agent.Id);
    }
    return card;
  }
  private UIElement VacantCard(AgentSeat seat)
  {
    var content = Stack(6);
    content.Children.Add(Heading("Vacant · " + seat.Role!.Replace('-', ' '), 13));
    content.Children.Add(Words("Its memory is kept for the next hire.", 11, true));
    content.Children.Add(AsyncButton("Hire into this role", () => AgentEditors.HireAsync(XamlRoot, Model.Agents, Model.Projects, navigation, Model, seat.ProjectId ?? ProjectIdentity.IndependentId, seat.Key)));
    var card = Card(content); card.Opacity = 0.85; return card;
  }

  // ---------- Org chart ----------
  private static Border Line(double width, double height, bool visible = true) => new()
  { Width = width, Height = height, Background = visible ? Resource("TextFillColorTertiaryBrush") : null, HorizontalAlignment = width is double.NaN ? HorizontalAlignment.Stretch : HorizontalAlignment.Center };
  // One card and its reports below it, joined by a stem and a bar that runs between the
  // first and last report's centres (the bar is built from two halves per column so it
  // meets each child exactly, with no measuring).
  private FrameworkElement Tree(AgentTreeNode node, HashSet<string> shown)
  {
    var column = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
    var card = AgentCard(node.Agent, true); card.Width = 230; card.HorizontalAlignment = HorizontalAlignment.Center; column.Children.Add(card);
    foreach (var hand in Model.Hands(node.Agent.Id).Take(3))
    {
      var link = new HyperlinkButton { Content = "Hand " + hand.HandNumber + (hand.Job.Length > 0 ? " · " + hand.Job : ""), FontSize = 11, Padding = new Thickness(4, 0, 4, 0), HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 230 };
      link.Click += (_, _) => navigation.OpenSession(hand.SessionId); Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(link, "Open hand session " + hand.HandNumber + " of " + node.Agent.Name); column.Children.Add(link);
    }
    var reports = node.Reports.Where(r => shown.Contains(r.Agent.Id) || Includes(r, shown)).ToArray();
    if (reports.Length == 0) return column;
    column.Children.Add(Line(1, 16));
    var row = new Grid { ColumnSpacing = 0, HorizontalAlignment = HorizontalAlignment.Center };
    for (var i = 0; i < reports.Length; i++)
    {
      row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      var cell = new StackPanel { Padding = new Thickness(8, 0, 8, 0) };
      var bar = new Grid { Height = 1 }; bar.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); bar.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
      var left = Line(double.NaN, 1, i > 0); var right = Line(double.NaN, 1, i < reports.Length - 1); Grid.SetColumn(right, 1); bar.Children.Add(left); bar.Children.Add(right);
      bar.Margin = new Thickness(i > 0 ? -8 : 0, 0, i < reports.Length - 1 ? -8 : 0, 0);
      cell.Children.Add(bar); cell.Children.Add(Line(1, 14)); cell.Children.Add(Tree(reports[i], shown));
      Grid.SetColumn(cell, i); row.Children.Add(cell);
    }
    column.Children.Add(row); return column;
  }
  private static bool Includes(AgentTreeNode node, HashSet<string> shown) => shown.Contains(node.Agent.Id) || node.Reports.Any(r => Includes(r, shown));
  private void OrgChart(StackPanel body, StackPanel list, AutoSuggestBox search)
  {
    search.Visibility = orgSearchOpen ? Visibility.Visible : Visibility.Collapsed;
    var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    var clear = Button("Clear search", () => search.Text = ""); clear.Visibility = orgSearchOpen && query.Length > 0 ? Visibility.Visible : Visibility.Collapsed; bar.Children.Add(clear);
    if (orgSearchOpen) bar.Children.Add(Button("Done search", () => { query = ""; orgSearchOpen = false; Render(); }));
    else bar.Children.Add(Button("Find", () => { orgSearchOpen = true; Render(); find?.Focus(FocusState.Keyboard); }));
    bar.Children.Add(IconButton("", "Zoom out (Ctrl+minus)", () => Zoom(chartZoom / 1.25f)));
    bar.Children.Add(Button("Actual size", () => Zoom(1)));
    bar.Children.Add(IconButton("", "Zoom in (Ctrl+plus)", () => Zoom(chartZoom * 1.25f)));
    bar.Children.Add(Button("Fit", FitChart));
    body.Children.Add(bar);
    void FillChart()
    {
      list.Children.Clear();
      var shown = Rows().Select(a => a.Id).ToHashSet(StringComparer.Ordinal);
      var all = Model.Agents.List().Where(a => (a.Status == SavedAgentStatus.Archived) == archived).ToDictionary(a => a.Id);
      AgentTreeNode Node(SavedAgent a, HashSet<string> seen) => new(a, all.Values.Where(r => r.ReportsTo == a.Id && seen.Add(r.Id)).OrderByDescending(Model.IsLead).ThenBy(r => r.Name).Select(r => Node(r, seen)).ToImmutableArray());
      var chart = new StackPanel { Spacing = 0, HorizontalAlignment = HorizontalAlignment.Center, Padding = new Thickness(16) };
      var hootContent = Stack(4); hootContent.Children.Add(Heading("Hoot", 14)); hootContent.Children.Add(Words("Gives leads their goals and assigns agents where a project has no lead.", 11, true));
      var hoot = Card(Destination(hootContent, "Open Hoot", () => OpenAgent(AgentSeats.HootId))); hoot.Width = 280; hoot.HorizontalAlignment = HorizontalAlignment.Center;
      ManagerDropTarget(hoot, AgentSeats.HootId); chart.Children.Add(hoot);
      // One region per project: its lead and team under it. An agent whose manager is in
      // another project (or Hoot, or no one) starts a branch in its own project's region.
      var projectsShown = Model.Projects.List().Where(p => projectFilter is null || p.Id == projectFilter)
        .Where(p => all.Values.Any(a => a.ProjectId == p.Id) || p.Lead is not null).OrderBy(p => p.Id == ProjectIdentity.IndependentId).ThenBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
      var regions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 24, HorizontalAlignment = HorizontalAlignment.Center };
      foreach (var project in projectsShown)
      {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var roots = all.Values.Where(a => a.ProjectId == project.Id && (a.ReportsTo is null || a.ReportsTo == AgentSeats.HootId || !all.TryGetValue(a.ReportsTo, out var boss) || boss.ProjectId != project.Id))
          .OrderByDescending(Model.IsLead).ThenBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
        foreach (var r in roots) seen.Add(r.Id);
        var trees = roots.Select(r => Node(r, seen)).Where(n => Includes(n, shown)).ToArray();
        var vacant = query.Length == 0 && roleFilter.Length == 0 && stateFilter.Length == 0 && !archived ? Model.VacantSeats(project.Id) : [];
        if (trees.Length == 0 && vacant.Count == 0 && (query.Length > 0 || roleFilter.Length > 0 || stateFilter.Length > 0)) continue;
        var region = Stack(12);
        var head = new Grid { ColumnSpacing = 10 };
        head.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); head.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); head.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        head.Children.Add(ProjectPicture(Model.Projects, project, 26));
        var words = Stack(2); words.Children.Add(Heading(project.Name, 15));
        words.Children.Add(Words(project.Id == ProjectIdentity.IndependentId ? "Work outside a project" : project.LeadName.Length > 0 ? "Lead: " + project.LeadName : "No lead · Hoot assigns directly", 11, true));
        Grid.SetColumn(words, 1); head.Children.Add(words);
        if (project.Id != ProjectIdentity.IndependentId) { var choose = LeadChooser(project); Grid.SetColumn(choose, 2); head.Children.Add(choose); }
        region.Children.Add(head);
        var forest = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var tree in trees) forest.Children.Add(Tree(tree, shown));
        if (trees.Length > 0) region.Children.Add(forest);
        if (vacant.Count > 0)
        {
          var seats = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
          foreach (var seat in vacant) seats.Children.Add(AsyncButton("Vacant · " + seat.Role!.Replace('-', ' ') + " · Hire", () => AgentEditors.HireAsync(XamlRoot, Model.Agents, Model.Projects, navigation, Model, project.Id, seat.Key)));
          region.Children.Add(seats);
        }
        if (trees.Length == 0 && vacant.Count == 0) region.Children.Add(Words("No agents yet.", 12, true));
        var box = Card(region); box.VerticalAlignment = VerticalAlignment.Top;
        var stem = new StackPanel(); stem.Children.Add(Line(1, 18)); stem.Children.Add(box);
        regions.Children.Add(stem);
      }
      if (regions.Children.Count > 0) { chart.Children.Add(Line(1, 14)); chart.Children.Add(regions); }
      else chart.Children.Add(Words("No agents match that search.", 13, true));
      chartContent = chart;
      chartScroll = new ScrollViewer
      {
        Content = chart, ZoomMode = ZoomMode.Enabled, MinZoomFactor = 0.2f, MaxZoomFactor = 3f, HorizontalScrollMode = ScrollMode.Enabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        VerticalScrollMode = ScrollMode.Enabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Height = 680
      };
      var scroll = chartScroll; scroll.Loaded += (_, _) => scroll.ChangeView(null, null, chartZoom, true);
      scroll.ViewChanged += (_, e) => { if (!e.IsIntermediate) chartZoom = scroll.ZoomFactor; };
      list.Children.Add(Card(scroll));
      list.Children.Add(Words("Open a card for its profile. Drag a card onto another agent or Hoot to change who it reports to. Ctrl+minus, Ctrl+plus and Ctrl+0 zoom the chart.", 12, true));
    }
    search.TextChanged += (_, _) => { query = search.Text; clear.Visibility = query.Length > 0 ? Visibility.Visible : Visibility.Collapsed; FillChart(); }; FillChart();
  }
  private void Zoom(float factor)
  {
    if (chartScroll is null) return;
    chartZoom = Math.Clamp(factor, 0.2f, 3f); chartScroll.ChangeView(null, null, chartZoom);
  }
  private void FitChart()
  {
    if (chartScroll is null || chartContent is null || chartContent.ActualWidth <= 0) return;
    Zoom((float)Math.Min(1, Math.Min(chartScroll.ViewportWidth / chartContent.ActualWidth, chartScroll.ViewportHeight / Math.Max(1, chartContent.ActualHeight))));
  }
  private Button LeadChooser(Project project)
  {
    var menu = new MenuFlyout();
    var none = new ToggleMenuFlyoutItem { Text = "No lead (Hoot assigns directly)", IsChecked = project.Lead is null };
    none.Click += async (_, _) => await Model.RunAsync(() => Model.Agents.SetProjectLead(project.Id, null), "Project lead saved.");
    menu.Items.Add(none); menu.Items.Add(new MenuFlyoutSeparator());
    foreach (var agent in Model.Agents.List().Where(a => a.ProjectId == project.Id && a.Status != SavedAgentStatus.Archived).OrderBy(a => a.Name))
    {
      var item = new ToggleMenuFlyoutItem { Text = agent.Name + " · " + AgentsViewModel.RoleWords(agent.Seat), IsChecked = project.Lead == "agent:" + agent.Id };
      item.Click += async (_, _) =>
      {
        if (project.Lead == "agent:" + agent.Id) return;
        if (!await ConfirmAsync(XamlRoot, "Make " + agent.Name + " the lead?", (project.LeadName.Length > 0 ? project.LeadName + " currently leads " + project.Name + ". " : "") + agent.Name + " will use this project's lead seat and its kept memory.", "Make lead")) return;
        await Model.RunAsync(() => Model.Agents.SetProjectLead(project.Id, agent.Id), "Project lead saved.");
      };
      menu.Items.Add(item);
    }
    var button = new Button { Content = "Choose lead", Flyout = menu, MinHeight = 30, VerticalAlignment = VerticalAlignment.Center };
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, "Choose lead of " + project.Name); return button;
  }

  // ---------- Profile ----------
  private UIElement SessionRunRow(AgentRun run)
  {
    var identity = SessionIdentity(Model.Projects, Model.Agents, run.SessionId, run.Job.Length > 0 ? run.Job : "Hand " + run.HandNumber, run.Provider, run.Mode, run.ProjectId);
    var row = Destination(SessionIdentityRow(identity, run.State == AgentRunState.Ended ? "Ended · started " + run.StartedAt.LocalDateTime.ToString("g") : "Started " + run.StartedAt.LocalDateTime.ToString("g")),
      "Open " + identity.Title + " · " + identity.DisplaySubtitle, () => navigation.OpenSession(run.SessionId));
    var menu = new MenuFlyout();
    var open = new MenuFlyoutItem { Text = "Open run" }; open.Click += (_, _) => navigation.OpenSession(run.SessionId); menu.Items.Add(open);
    var copy = new MenuFlyoutItem { Text = "Copy run ID" }; copy.Click += async (_, _) => await Model.RunAsync(() => { var data = new DataPackage(); data.SetText(run.SessionId); Clipboard.SetContent(data); }, "Run ID copied."); menu.Items.Add(copy);
    row.ContextFlyout = menu; MatchFlyoutTheme(row, menu); return row;
  }
  private Task StartSessionAsync(SavedAgent agent, bool hand = false) => NewSessionPicker.ShowAsync(XamlRoot, Model.Agents, Model.Projects, Model.Accounts, navigation, agent.ProjectId, agent.Id, requireJob: hand);
  private void Profile(StackPanel body, SavedAgent agent)
  {
    body.Children.Add(Button("‹  Agents", () => Model.SelectedId = null));
    void EditField(string? field = null) => _ = AgentEditors.EditAsync(XamlRoot, agent, Model.Agents, Model.Projects, Model, field);
    var activity = Model.Activity(agent);
    var actions = new List<UIElement> { IconButton("", "Agent settings", () => EditField()), new Button { Content = "Actions", Flyout = AgentMenu(agent) } };
    if (agent.Status == SavedAgentStatus.Active)
      actions.Add(AsyncButton("Start session", () => StartSessionAsync(agent), navigation is not IAgentTasksNavigation));
    if (navigation is IAgentTasksNavigation tasks) actions.Add(AsyncButton("Assign task", () => tasks.AssignTaskAsync(agent.ProjectId, agent.Id), true));
    body.Children.Add(PageHeader(agent.Name, Model.ProjectName(agent.ProjectId) + " · " + Model.RoleName(agent) + " · " + activity.Label, AgentPicture(agent, 38),
      ViewSwitch(profileTab, new[] { "Dashboard", "Memory", "Instructions", "Skills", "Runs", "Routines" }, tab => { profileTab = tab; Render(); }), actions.ToArray()));
    switch (profileTab)
    {
      case "Routines": RoutinesTab(body, agent.Id); return;
      case "Memory": MemoryTab(body, agent); return;
      case "Instructions": InstructionsTab(body, agent); return;
      case "Skills": SkillsTab(body, agent); return;
      case "Runs":
      {
        var runs = Model.Agents.Runs().Where(r => r.AgentId == agent.Id).OrderByDescending(r => r.StartedAt).ToArray();
        body.Children.Add(Header("Runs", runs.Length == 0 ? "No sessions yet." : $"{runs.Length} sessions as this agent. Right-click a run to copy its ID."));
        if (runs.Length == 0) body.Children.Add(Card(Words("No sessions yet. Start a session to work as this agent.", muted: true)));
        foreach (var run in runs) body.Children.Add(SessionRunRow(run));
        return;
      }
    }
    var about = Stack(12); about.Children.Add(Heading("About", 18)); about.Children.Add(Description(agent.Description));
    var facts = Stack(2);
    var o = agent.Settings;
    facts.Children.Add(Fact("Description", agent.Description.Length > 0 ? "Edit description" : "Add description", "Edit description", () => EditField("description")));
    facts.Children.Add(Fact("Coding AI", AgentSeats.ProviderName(agent.Provider), "Change coding AI", () => EditField("ai")));
    facts.Children.Add(Fact("Account", Model.AccountLine(agent), "Change account", () => EditField("account")));
    facts.Children.Add(Fact("Model", AppWideModel(agent, effort: false), "Change model", () => EditField("model")));
    facts.Children.Add(Fact("Effort", TerminalDeck.Core.Accounts.ModelCatalog.EffortName(agent.Effort is "auto" or "" ? NewSessionPicker.Services?.Launch(agent.Provider).Effort ?? TerminalDeck.Core.Accounts.ModelCatalog.TopEffort(agent.Provider) : agent.Effort) is { Length: > 0 } level ? level : "Automatic", "Change effort", () => EditField("effort")));
    // No own choice: name the mode it really starts in (the app's default for new chats), never just "App default".
    var permissionWords = o.PermissionMode is { Length: > 0 } ? AgentOptions.PermissionLabel(o.PermissionMode)
      : NewSessionPicker.Services?.Permission(agent.Provider) is { } appMode ? TerminalDeck.Core.Chats.ChatPermissionModes.Label(appMode) + " · app default" : "App default";
    facts.Children.Add(Fact("Before it changes files", permissionWords, "Change permission", () => EditField("permission")));
    facts.Children.Add(Fact("Project", Model.ProjectName(agent.ProjectId), "Open project", () => navigation.OpenProject(agent.ProjectId)));
    facts.Children.Add(Fact("Role", Model.IsLead(agent) ? "Lead (" + AgentsViewModel.RoleWords(agent.Seat) + ")" : AgentsViewModel.RoleWords(agent.Seat), "Change role", () => EditField("role")));
    facts.Children.Add(Fact("Reports to", Model.ManagerName(agent), "Choose manager", () => EditField("manager")));
    facts.Children.Add(Fact("Working folder", o.WorkingFolder ?? "Project home folder", "Change working folder", () => EditField("folder")));
    facts.Children.Add(Fact("Tasks at once", agent.MaxConcurrentTasks?.ToString() ?? "No limit", "Change limit", () => EditField("limits")));
    facts.Children.Add(Fact("Instructions", agent.InstructionsFile is null ? "Add instructions" : Path.GetFileName(agent.InstructionsFile), "Edit instructions", () => { profileTab = "Instructions"; Render(); }));
    facts.Children.Add(Fact("Skills", o.SkillsOff ? "Turned off" : agent.Skills.IsDefaultOrEmpty ? "None" : string.Join(", ", agent.Skills), "Show skills", () => { profileTab = "Skills"; Render(); }));
    facts.Children.Add(Fact("Role memory", Model.RoleName(agent) + " · card and notes", "Read or edit this role's card and notes", () => { profileTab = "Memory"; Render(); }));
    about.Children.Add(facts);
    var activityPanel = Stack(12);
    var hands = Model.Hands(agent.Id);
    var status = Stack(8); status.Children.Add(Heading("Status", 18)); status.Children.Add(StatusLine(agent, 14));
    var statusActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    if (agent.Status != SavedAgentStatus.Archived) statusActions.Children.Add(AsyncButton(agent.Status == SavedAgentStatus.Paused ? "Resume" : "Pause", () => TogglePause(agent)));
    if (agent.Status == SavedAgentStatus.Active) statusActions.Children.Add(AsyncButton("Add a hand", () => StartSessionAsync(agent, hand: true)));
    if (hands.Count > 0) statusActions.Children.Add(AsyncButton("Stop everything", () => StopEverythingAsync(agent)));
    status.Children.Add(statusActions); activityPanel.Children.Add(Card(status));
    activityPanel.Children.Add(Heading($"Sessions · {hands.Count}", 18));
    if (hands.Count == 0) activityPanel.Children.Add(Card(Words("No hands at work. A new session or chat starts as this agent, with its role's memory and instructions.", muted: true)));
    foreach (var hand in hands) activityPanel.Children.Add(SessionRunRow(hand));
    var reports = Model.Agents.List().Where(a => a.ReportsTo == agent.Id && a.Status != SavedAgentStatus.Archived).ToArray();
    if (reports.Length > 0)
    {
      activityPanel.Children.Add(Heading($"Direct reports · {reports.Length}", 18));
      foreach (var report in reports) activityPanel.Children.Add(Fact(report.Name, AgentsViewModel.RoleWords(report.Seat) + " · " + Model.Activity(report).Label, "Open agent", () => OpenAgent(report.Id)));
    }
    var dashboard = new Grid { ColumnSpacing = 12, RowSpacing = 12 };
    dashboard.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); dashboard.ColumnDefinitions.Add(new() { Width = new GridLength(420) });
    dashboard.RowDefinitions.Add(new() { Height = GridLength.Auto }); dashboard.RowDefinitions.Add(new() { Height = GridLength.Auto });
    dashboard.Children.Add(activityPanel); var aboutCard = Card(about); aboutCard.VerticalAlignment = VerticalAlignment.Top; Grid.SetColumn(aboutCard, 1); dashboard.Children.Add(aboutCard);
    dashboard.SizeChanged += (_, _) =>
    {
      var narrow = dashboard.ActualWidth < 800;
      dashboard.ColumnDefinitions[1].Width = narrow ? new GridLength(0) : new GridLength(420);
      Grid.SetColumn(aboutCard, narrow ? 0 : 1); Grid.SetRow(aboutCard, narrow ? 1 : 0);
    };
    body.Children.Add(dashboard);
    if (agent.Status == SavedAgentStatus.Archived) body.Children.Add(AsyncButton("Delete permanently…", () => DeleteAsync(agent)));
  }
  private Task TogglePause(SavedAgent agent) => Model.RunAsync(() => Model.Agents.Save(agent with
    { Status = agent.Status == SavedAgentStatus.Paused ? SavedAgentStatus.Active : SavedAgentStatus.Paused }, agent), agent.Status == SavedAgentStatus.Paused ? "Resumed. It takes new work again." : "Paused. It takes no new work; current sessions continue.");
  private async Task StopEverythingAsync(SavedAgent agent)
  {
    var count = Model.Hands(agent.Id).Count;
    if (count == 0) { Model.Notice(agent.Name + " has nothing running."); return; }
    if (!await ConfirmAsync(XamlRoot, "Stop everything " + agent.Name + " is running?", $"{count} session{(count == 1 ? "" : "s")} will close. Unsent work in them is lost. Its memory and runs are kept.", "Stop everything")) return;
    await Model.RunAsync(async () => { var stopped = await Model.Agents.StopHandsAsync(agent.Id); if (stopped == 0) throw new InvalidOperationException("No session could be stopped. Close them from their tabs."); }, "Stopped.");
  }
  private async Task DeleteAsync(SavedAgent agent)
  {
    if (!await ConfirmAsync(XamlRoot, "Delete " + agent.Name + " permanently?", "Its role memory and run history stay for the next hire. Current sessions must be ended first.", "Delete permanently")) return;
    if (await Model.RunAsync(() => Model.Agents.Remove(agent.Id), "Agent deleted. Its role memory was kept.")) Model.SelectedId = null;
  }
  private void MemoryTab(StackPanel body, SavedAgent agent)
  {
    var seat = Model.Agents.SeatOf(agent.Id);
    var saved = Model.Agents.Seats().FirstOrDefault(s => s.SeatKey == seat.Key) ?? new AgentSeatMemory(seat.Key);
    var template = Model.Agents.Templates().Single(t => t.Category == seat.Category);
    body.Children.Add(Header("Role memory", "Kept with the " + (seat.Category == AgentCategory.Lead ? "project's lead seat" : "role \"" + seat.Role + "\"") + ". A new hire into this seat inherits it.",
      AsyncButton("Edit " + seat.Category.ToString().ToLowerInvariant() + " template", () => AgentEditors.TemplatesAsync(XamlRoot, Model.Agents, Model, seat.Category))));
    var card = Field("Card · what this role always needs to know", saved.Card, true, 64000); card.MinHeight = 180;
    var notes = Field("Notes · what it learned while working", saved.Notes, true, 128000); notes.MinHeight = 220;
    var warning = new TerminalDeck.App.Views.Notices.CompactNotice { Severity = InfoBarSeverity.Warning, IsClosable = false, Message = $"The card is longer than the {template.CardLimit:N0}-character warning limit in its template. You can still save it." };
    void Warn() => warning.IsOpen = card.Text.Length > template.CardLimit; card.TextChanged += (_, _) => Warn(); Warn();
    var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    buttons.Children.Add(AsyncButton("Save memory", () => Model.RunAsync(() => Model.Agents.SaveSeatMemory(seat.Key, card.Text, notes.Text, saved), "Role memory saved."), true));
    buttons.Children.Add(Button("Revert", () => { card.Text = saved.Card; notes.Text = saved.Notes; }));
    var editor = Stack(12); editor.Children.Add(card); editor.Children.Add(warning); editor.Children.Add(notes); editor.Children.Add(buttons);
    body.Children.Add(Card(editor));
    var shared = Stack(8); shared.Children.Add(Heading("Shared " + seat.Category.ToString().ToLowerInvariant() + " template", 15));
    shared.Children.Add(Words(template.Instructions.Length > 0 ? template.Instructions : "No shared template text.", 13, true));
    shared.Children.Add(Words("Every session in this seat starts with the template, then this card and notes.", 12, true));
    body.Children.Add(Card(shared));
  }
  private void InstructionsTab(StackPanel body, SavedAgent agent)
  {
    var actions = new List<UIElement> { AsyncButton("Edit instructions", () => AgentEditors.InstructionsAsync(XamlRoot, agent, Model.Agents, Model), true) };
    if (agent.InstructionsFile is not null) actions.Insert(0, AsyncButton("Show its file", () => ShowFileAsync(agent)));
    body.Children.Add(Header("Instructions", "Used when a session starts as this agent, after the template and the role's memory.", actions.ToArray()));
    try { var instructions = Model.Agents.ReadInstructions(agent.Id); body.Children.Add(Card(Words(instructions.Length > 0 ? instructions : "No instructions yet."))); }
    catch (IOException) { body.Children.Add(Words("The instructions file could not be read. Open the editor to write new instructions.", muted: true)); }
  }
  private void SkillsTab(StackPanel body, SavedAgent agent)
  {
    var o = agent.Settings;
    body.Children.Add(Header("Skills", "Assigned skills are suggested in its brief when the session starts.", AsyncButton("Give more", () => AgentEditors.SkillsAsync(XamlRoot, agent, Model.Agents, Model.Projects, Model), true)));
    var off = new ToggleSwitch { Header = "Turn all skills off", IsOn = o.SkillsOff, OnContent = "It starts with no skills at all", OffContent = "Assigned skills are suggested" };
    off.Toggled += async (_, _) => { if (off.IsOn == o.SkillsOff) return; await Model.RunAsync(() => Model.Agents.Save(agent with { Options = o with { SkillsOff = off.IsOn } }, agent), off.IsOn ? "Skills turned off." : "Skills turned on."); };
    body.Children.Add(Card(off));
    if (agent.Skills.IsDefaultOrEmpty) { body.Children.Add(Words("No skills assigned yet. Choose Give more to pick from the skills installed for this project and for you.", muted: true)); return; }
    var project = Model.Projects.List().FirstOrDefault(p => p.Id == agent.ProjectId);
    var installed = AgentSkills.Find(AgentSkills.Roots(project?.Folders ?? [])).ToDictionary(s => s.Name, StringComparer.OrdinalIgnoreCase);
    foreach (var skill in agent.Skills)
    {
      var row = new Grid { ColumnSpacing = 12 };
      row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      var words = Stack(2); words.Children.Add(Words(skill));
      words.Children.Add(Words(installed.TryGetValue(skill, out var found) ? (found.Description.Length > 0 ? found.Description + " · " : "") + found.Where : "Not installed for this project or for you. It stays listed.", 12, true));
      row.Children.Add(words);
      var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
      if (found is not null) buttons.Children.Add(AsyncButton("Show skill", () => Model.RunAsync(() => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe") { Arguments = "\"" + found.Folder.Replace("\"", "") + "\"", UseShellExecute = true }), "Skill folder shown.")));
      buttons.Children.Add(AsyncButton("Remove", () => Model.RunAsync(() => Model.Agents.Save(agent with { Skills = agent.Skills.Remove(skill) }, agent), "Skill removed.")));
      Grid.SetColumn(buttons, 1); row.Children.Add(buttons);
      body.Children.Add(Card(row));
    }
  }
  private Task ShowFileAsync(SavedAgent agent) => Model.RunAsync(() =>
  {
    var path = agent.InstructionsFile ?? throw new InvalidOperationException("This agent has no file yet. Save its instructions to create one.");
    if (!File.Exists(path)) throw new InvalidOperationException("Its file is missing. Save its instructions again to recreate it.");
    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe") { Arguments = "/select,\"" + path.Replace("\"", "") + "\"", UseShellExecute = true });
  }, "Its file is shown in Explorer.");
  private void ManagerDropTarget(FrameworkElement target, string managerId)
  {
    target.AllowDrop = true;
    target.DragOver += (_, e) => { if (e.DataView.Contains("TerminalDeck.Agent")) { e.AcceptedOperation = DataPackageOperation.Move; e.Handled = true; } };
    target.Drop += async (_, e) =>
    {
      var deferral = e.GetDeferral(); e.Handled = true;
      try
      {
        await Model.RunAsync(async () =>
        {
          if (!e.DataView.Contains("TerminalDeck.Agent") || await e.DataView.GetDataAsync("TerminalDeck.Agent") is not string raw || raw.Length > 1024) throw new ArgumentException("Drag a saved agent onto its new manager.");
          AgentDrag? transfer;
          try { transfer = JsonSerializer.Deserialize<AgentDrag>(raw); } catch (JsonException) { throw new ArgumentException("Drag an agent from this app workspace."); }
          if (transfer is null || transfer.Owner != Model.DragScope) throw new ArgumentException("This agent belongs to another app workspace.");
          var id = transfer.Id;
          if (id == managerId) throw new ArgumentException("An agent cannot report to itself.");
          var agent = Model.Agents.Get(id); var name = managerId == AgentSeats.HootId ? "Hoot" : Model.Agents.Get(managerId).Name;
          if (!await ConfirmAsync(XamlRoot, "Change Reports to?", agent.Name + " will report to " + name + ". Its project, role memory and current sessions stay with it.", "Change manager")) return;
          Model.Agents.Save(agent with { ReportsTo = managerId }, agent);
        }, "Reports to saved.");
      }
      finally { deferral.Complete(); }
    };
  }
  private MenuFlyout AgentMenu(SavedAgent agent)
  {
    var menu = new MenuFlyout();
    void Item(string title, Func<Task> action)
    {
      var item = new MenuFlyoutItem { Text = title }; item.Click += async (_, _) => await action(); menu.Items.Add(item);
    }
    if (navigation is IAgentTasksNavigation taskNavigation && agent.Status != SavedAgentStatus.Archived) Item("Assign task", () => taskNavigation.AssignTaskAsync(agent.ProjectId, agent.Id));
    if (agent.Status == SavedAgentStatus.Active)
    {
      Item("Start session", () => StartSessionAsync(agent));
      Item("Add a hand", () => StartSessionAsync(agent, hand: true));
    }
    if (Model.Hands(agent.Id).Count > 0) Item("Watch", () => { navigation.OpenSession(Model.Hands(agent.Id)[0].SessionId); return Task.CompletedTask; });
    menu.Items.Add(new MenuFlyoutSeparator());
    if (agent.ProjectId != ProjectIdentity.IndependentId)
    {
      var project = Model.Projects.Get(agent.ProjectId); var leading = project.Lead == "agent:" + agent.Id;
      if (leading || agent.Status != SavedAgentStatus.Archived) Item(leading ? "Stop leading project" : "Make lead", async () =>
      {
        var message = leading ? "Its role memory is kept. This project will have no named lead; Hoot assigns its agents directly." : (project.LeadName.Length > 0 ? project.LeadName + " currently leads this project. " : "") + agent.Name + " will use this project's lead seat and its kept memory.";
        if (!await ConfirmAsync(XamlRoot, leading ? "Stop leading " + project.Name + "?" : "Make " + agent.Name + " the lead?", message, leading ? "Stop leading" : "Make lead")) return;
        await Model.RunAsync(() => Model.Agents.SetProjectLead(project.Id, leading ? null : agent.Id), "Project lead saved.");
      });
    }
    var reports = new MenuFlyoutSubItem { Text = "Reports to" };
    void Boss(string? id, string name)
    {
      var item = new ToggleMenuFlyoutItem { Text = name, IsChecked = agent.ReportsTo == id };
      item.Click += async (_, _) => { if (agent.ReportsTo == id) return; await Model.RunAsync(() => Model.Agents.Save(agent with { ReportsTo = id }, agent), "Reports to saved."); };
      reports.Items.Add(item);
    }
    Boss(null, "No one · independent"); Boss(AgentSeats.HootId, "Hoot");
    foreach (var boss in Model.Agents.List().Where(a => a.Id != agent.Id && a.Status == SavedAgentStatus.Active).OrderByDescending(a => a.ProjectId == agent.ProjectId).ThenBy(a => a.Name).Take(40))
      Boss(boss.Id, boss.Name + " · " + Model.ProjectName(boss.ProjectId));
    menu.Items.Add(reports);
    if (agent.Status != SavedAgentStatus.Archived) Item(agent.Status == SavedAgentStatus.Paused ? "Resume" : "Pause", () => TogglePause(agent));
    menu.Items.Add(new MenuFlyoutSeparator());
    Item("Open profile", () => { OpenAgent(agent.Id); return Task.CompletedTask; });
    Item("Settings…", () => AgentEditors.EditAsync(XamlRoot, agent, Model.Agents, Model.Projects, Model));
    Item("Duplicate…", async () =>
    {
      var name = Field("Name", agent.Name[..Math.Min(55, agent.Name.Length)] + " copy", max: 60);
      var body = Stack(); body.Children.Add(name); body.Children.Add(Words("A new role gets a copy of this agent's settings, instructions and role memory. Its runs begin empty.", 12, true));
      var error = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error }; body.Children.Add(error);
      var dialog = Dialog(XamlRoot, "Duplicate agent", body, "Duplicate");
      dialog.PrimaryButtonClick += async (_, e) =>
      {
        var deferral = e.GetDeferral();
        try
        {
          SavedAgent? copy = null; e.Cancel = !await Model.RunAsync(() => copy = Model.Agents.Duplicate(agent.Id, name.Text), "Agent duplicated.");
          if (!e.Cancel && copy is not null) OpenAgent(copy.Id); error.Message = Model.Message; error.IsOpen = e.Cancel;
        }
        finally { deferral.Complete(); }
      }; await dialog.ShowAsync();
    });
    Item("Copy agent ID", () => Model.RunAsync(() => { var data = new DataPackage(); data.SetText(agent.Id); Clipboard.SetContent(data); }, "Agent ID copied."));
    Item("Show its file", () => ShowFileAsync(agent));
    if (Model.Hands(agent.Id).Count > 0) Item("Stop everything it is running…", () => StopEverythingAsync(agent));
    menu.Items.Add(new MenuFlyoutSeparator());
    Item(agent.Status == SavedAgentStatus.Archived ? "Restore" : "Archive", () => Model.RunAsync(() => Model.Agents.Save(agent with
      { Status = agent.Status == SavedAgentStatus.Archived ? SavedAgentStatus.Active : SavedAgentStatus.Archived }, agent), agent.Status == SavedAgentStatus.Archived ? "Agent restored." : "Agent archived. Its role memory stays."));
    if (agent.Status == SavedAgentStatus.Archived) Item("Delete permanently…", () => DeleteAsync(agent));
    return menu;
  }
  private void Hoot(StackPanel body)
  {
    body.Children.Add(Button("‹  Agents", () => Model.SelectedId = null));
    body.Children.Add(Header("Hoot", "The built-in assistant. It gives project leads their goals and assigns agents directly where a project has no lead.",
      AsyncButton("Orchestrator template", OpenTemplatesAsync)));
    body.Children.Add(AsyncButton("Hoot routines", () => { grouping = "Routines"; Model.SelectedId = null; Render(); return Task.CompletedTask; }));
    var leads = Model.Projects.List().Where(p => p.Id != ProjectIdentity.IndependentId).ToArray();
    if (leads.Length > 0)
    {
      body.Children.Add(Heading("Projects", 20));
      foreach (var project in leads) body.Children.Add(Fact(project.Name, project.LeadName.Length > 0 ? "Lead: " + project.LeadName : "No lead · Hoot assigns directly", "Open project", () => navigation.OpenProject(project.Id)));
    }
    var direct = Model.Agents.List().Where(a => a.ReportsTo == AgentSeats.HootId && a.Status != SavedAgentStatus.Archived).ToArray();
    body.Children.Add(Heading($"Direct reports · {direct.Length}", 20));
    if (direct.Length == 0) body.Children.Add(Words("No agent reports to Hoot directly.", muted: true));
    else body.Children.Add(AdaptiveColumns(direct.Select(r => (UIElement)AgentCard(r)), 250));
  }
  // An agent without its own model runs the app-wide one: show that real name, never "Choose model".
  internal static string AppWideModel(SavedAgent agent, bool effort = true)
  {
    var launch = NewSessionPicker.Services?.Launch(agent.Provider) ?? TerminalDeck.Core.Settings.LaunchDefaults.For(agent.Provider, (TerminalDeck.Core.Settings.GeneralPreferences?)null);
    var model = agent.Model.Length > 0 ? agent.Model : launch.Model;
    var level = agent.Effort is "auto" or "" ? launch.Effort : agent.Effort;
    return TerminalDeck.Core.Accounts.ModelCatalog.Label(agent.Provider, model, effort ? level : null);
  }
}
