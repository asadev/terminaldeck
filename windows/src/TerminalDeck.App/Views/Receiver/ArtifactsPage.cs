using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.Core.Receiver;
using static TerminalDeck.App.Views.Receiver.ReceiverUi;

namespace TerminalDeck.App.Views.Receiver;

public sealed record ArtifactFolder(string Path, string Name, string ProjectId);
public sealed class ArtifactsPage : Grid
{
  private readonly IReceiverArtifacts artifacts;
  private readonly IReceiver receiver;
  private readonly Action<string>? openSession;
  private readonly IReadOnlyList<ArtifactFolder> folders;
  private IReadOnlyList<ArtifactFolder> CatalogFolders() => folders.Concat(artifacts.Roots().Where(r => !folders.Any(f => string.Equals(f.Path, r.Path, StringComparison.OrdinalIgnoreCase)))
    .Select(r => new ArtifactFolder(r.Path, r.ProjectId == "independent" ? "Independent" : folders.FirstOrDefault(f => f.ProjectId == r.ProjectId)?.Name ?? "Earlier project", r.ProjectId))).ToArray();
  private string? selectedProject;
  private string query = "";
  private string kind = "All";
  private string message = "";
  private bool failed;
  private bool busy;
  private readonly Action changed;
  public ArtifactsPage(IReceiverArtifacts artifacts, IReceiver receiver, IReadOnlyList<ArtifactFolder> folders, Action<string>? openSession = null)
  {
    this.openSession = openSession;
    this.artifacts = artifacts; this.receiver = receiver; this.folders = folders; Style = PageStyle();
    var dispatcher = DispatcherQueue; changed = () => dispatcher.TryEnqueueHandled(Render);
    Loaded += (_, _) => { artifacts.Changed += changed; Render(); }; Unloaded += (_, _) => artifacts.Changed -= changed; Render();
  }
  private async Task Run(Func<Task> action, string success)
  {
    if (busy) return; busy = true; message = "Working…"; failed = false; Render();
    try { await action(); message = success; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { message = ex is ArgumentException or IOException ? ex.Message : "The file could not be opened."; failed = true; }
    finally { busy = false; Render(); }
  }
  private void Render()
  {
    Children.Clear(); var body = Stack(28); body.Margin = new Thickness(24, 20, 24, 32);
    var search = Field("", query, limit: 200); search.PlaceholderText = "Search artifacts"; search.Width = 200; AutomationProperties.SetName(search, "Search artifacts");
    var project = Choice("", new[] { ("", "All projects") }.Concat(CatalogFolders().Select(f => (f.ProjectId, f.Name)).DistinctBy(p => p.ProjectId)), selectedProject ?? "");
    project.MinWidth = 120; project.MaxWidth = 200; AutomationProperties.SetName(project, "Artifact project");
    body.Children.Add(TerminalDeck.App.Views.Projects.ProjectAgentUi.PageHeader("Artifacts", "Pages, pictures and recordings your sessions and agents made", null, null, search, project));
    var controlBar = new Grid(); controlBar.ColumnDefinitions.Add(new()); controlBar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var types = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
    foreach (var name in new[] { "All", "Documents", "Pictures", "Videos" })
    {
      var segment = new ToggleButton { Content = name, IsChecked = name == kind, MinHeight = 32 };
      segment.Click += (_, _) => { kind = name; Render(); }; types.Children.Add(segment);
    }
    controlBar.Children.Add(types); var order = Words("Newest first", 12); order.Opacity = .65; order.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(order, 1); controlBar.Children.Add(order); body.Children.Add(controlBar);
    controlBar.RowDefinitions.Add(new() { Height = GridLength.Auto }); controlBar.RowDefinitions.Add(new() { Height = GridLength.Auto });
    controlBar.SizeChanged += (_, _) =>
    {
      var narrow = controlBar.ActualWidth < 460;
      Grid.SetRow(order, narrow ? 1 : 0); Grid.SetColumn(order, narrow ? 0 : 1);
      types.Orientation = controlBar.ActualWidth < 330 ? Orientation.Vertical : Orientation.Horizontal;
    };
    if (busy) body.Children.Add(new ProgressBar { IsIndeterminate = true });
    if (message.Length > 0) body.Children.Add(new TerminalDeck.App.Views.Notices.CompactNotice { IsOpen = true, IsClosable = false, Message = message, Severity = failed ? InfoBarSeverity.Error : InfoBarSeverity.Informational });
    var catalog = Stack(22); body.Children.Add(catalog);
    void Fill()
    {
      catalog.Children.Clear(); var rows = new List<(ArtifactFolder Folder, ReceiverArtifact Artifact)>();
      foreach (var folder in CatalogFolders().Where(f => selectedProject is null || f.ProjectId == selectedProject))
      {
        try { rows.AddRange(artifacts.List(folder.Path).Where(a => ArtifactCatalogPolicy.Includes(a.RelPath)).Select(a => (folder, a))); }
        catch (Exception ex) when (ex is ArgumentException or IOException) { var failure = Stack(8); failure.Children.Add(Words($"Couldn't read {folder.Name}'s history. {ex.Message}"));
          failure.Children.Add(Button("Try Again", () => { Fill(); return Task.CompletedTask; })); catalog.Children.Add(Card(failure)); }
      }
      var visible = rows.Where(r => (kind == "All" || Kind(r.Artifact.RelPath) == kind) && (query.Length == 0 || r.Artifact.RelPath.Contains(query, StringComparison.OrdinalIgnoreCase) || r.Folder.Name.Contains(query, StringComparison.OrdinalIgnoreCase))).OrderByDescending(r => r.Artifact.ProducedAt).ToArray();
      if (visible.Length == 0)
      {
        var empty = Stack(8); empty.Margin = new Thickness(0, 80, 0, 0); empty.Children.Add(Words(query.Length > 0 || kind != "All" || selectedProject is not null ? "No matching artifacts" : "No artifacts yet", 22));
        empty.Children.Add(Words(query.Length > 0 || kind != "All" || selectedProject is not null ? "Try another search or artifact type." : "Pages, pictures and recordings your sessions make show up here.")); catalog.Children.Add(empty);
      }
      foreach (var day in visible.GroupBy(r => r.Artifact.ProducedAt.LocalDateTime.Date))
      {
        var heading = new Grid(); heading.ColumnDefinitions.Add(new()); heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var today = DateTime.Today; heading.Children.Add(Words(day.Key == today ? "Today" : day.Key == today.AddDays(-1) ? "Yesterday" : day.Key.ToString("MMMM d, yyyy"), 15));
        var count = Words(day.Count().ToString(), 12); count.Opacity = .65; Grid.SetColumn(count, 1); heading.Children.Add(count); catalog.Children.Add(heading);
        var grid = new Grid { ColumnSpacing = 12, RowSpacing = 12 }; var cards = day.Select(r => ArtifactCard(r.Folder, r.Artifact)).ToArray();
        foreach (var card in cards) grid.Children.Add(card);
        void Arrange(double width)
        {
          var columns = Math.Clamp((int)((width + 12) / 192), 1, 5); grid.ColumnDefinitions.Clear(); grid.RowDefinitions.Clear();
          for (var i = 0; i < columns; i++) grid.ColumnDefinitions.Add(new());
          for (var i = 0; i < (cards.Length + columns - 1) / columns; i++) grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
          for (var i = 0; i < cards.Length; i++) { Grid.SetColumn(cards[i], i % columns); Grid.SetRow(cards[i], i / columns); }
        }
        grid.SizeChanged += (_, _) => Arrange(grid.ActualWidth); Arrange(Math.Max(192, ActualWidth - 48)); catalog.Children.Add(grid);
      }
    }
    search.TextChanged += (_, _) => { query = search.Text; Fill(); };
    project.SelectionChanged += (_, _) => { selectedProject = Picked(project) is { Length: > 0 } id ? id : null; Fill(); };
    Fill(); Children.Add(TerminalDeck.App.Views.Projects.ProjectAgentUi.PageFrame(body));
  }
  private Button ArtifactCard(ArtifactFolder folder, ReceiverArtifact artifact)
  {
    var content = Stack(0); var preview = new Grid { Height = 132 };
    var icon = new DeckIcon { Glyph = Kind(artifact.RelPath) switch { "Pictures" => "\uEB9F", "Videos" => "\uE714", _ => "\uE8A5" }, FontSize = 30, Opacity = .55 };
    preview.Children.Add(icon); content.Children.Add(preview);
    // Preview access stays on the guarded artifact channel; never build disk paths from metadata.
    if (Kind(artifact.RelPath) == "Pictures")
    {
      try
      {
        if (artifacts.Preview(folder.Path, artifact.RelPath).ImagePath is { } path)
          preview.Children.Add(new Image { Source = new BitmapImage(new Uri(path)), Stretch = Stretch.Uniform });
      }
      catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException) { ToolTipService.SetToolTip(preview, "Preview unavailable. Open the card for details."); }
    }
    var caption = Stack(4); caption.Margin = new Thickness(12, 10, 12, 10);
    var name = Words(Path.GetFileName(artifact.RelPath), 13); name.TextWrapping = TextWrapping.NoWrap; name.TextTrimming = TextTrimming.CharacterEllipsis; caption.Children.Add(name);
    var info = Words($"{folder.Name} · {artifact.ProducedAt.LocalDateTime:t}", 11); info.Opacity = .65; info.TextWrapping = TextWrapping.NoWrap; info.TextTrimming = TextTrimming.CharacterEllipsis; caption.Children.Add(info); content.Children.Add(caption);
    var card = Button("", () => Preview(folder, artifact)); card.Content = content; card.Padding = new Thickness(0); card.HorizontalContentAlignment = HorizontalAlignment.Stretch; card.HorizontalAlignment = HorizontalAlignment.Stretch; card.CornerRadius = new CornerRadius(12); card.IsEnabled = !busy;
    AutomationProperties.SetName(card, "Preview " + artifact.RelPath); ToolTipService.SetToolTip(card, artifact.RelPath);
    var menu = new MenuFlyout();
    void Action(string label, Func<Task> action) { var item = new MenuFlyoutItem { Text = label }; item.Click += async (_, _) => await action(); menu.Items.Add(item); }
    if (openSession is not null) Action("Open in chat", () => { openSession(artifact.SessionId); return Task.CompletedTask; });
    Action("Open in its app", () => Run(async () => await artifacts.OpenAsync(folder.Path, artifact.RelPath), "Opened file."));
    Action("Send to…", () => Send(folder, artifact));
    Action("Delete from list", () => Run(async () =>
    {
      var dialog = Dialog(this, "Delete from list?", Words("The file and its chat stay where they are."), "Delete from list");
      if (await dialog.ShowAsync() == ContentDialogResult.Primary) artifacts.Remove(folder.Path, artifact.RelPath);
    }, "Removal request finished. The file stays on disk."));
    card.ContextFlyout = menu; return card;
  }
  private Task Preview(ArtifactFolder folder, ReceiverArtifact artifact) => Run(async () =>
  {
    var preview = artifacts.Preview(folder.Path, artifact.RelPath); var content = Stack(12);
    content.Children.Add(Words($"{folder.Name} · Session {artifact.SessionId} · {artifact.ProducedAt.LocalDateTime:g}", 12));
    using var surface = new ArtifactPreviewSurface(preview); content.Children.Add(surface);
    var outcome = new TerminalDeck.App.Views.Notices.CompactNotice { IsOpen = false, IsClosable = false };
    var open = new Button { Content = "Open in its app", MinHeight = 40 };
    open.Click += async (_, _) =>
    {
      if (!open.IsEnabled) return;
      open.IsEnabled = false; outcome.IsOpen = true; outcome.Severity = InfoBarSeverity.Informational; outcome.Message = "Opening…";
      try { await artifacts.OpenAsync(folder.Path, artifact.RelPath); outcome.Message = "Opened file."; }
      catch (Exception ex) when (ex is not OutOfMemoryException)
      {
        outcome.Severity = InfoBarSeverity.Error;
        outcome.Message = ex is ArgumentException or IOException ? ex.Message : "The file could not be opened.";
      }
      finally { open.IsEnabled = true; }
    };
    content.Children.Add(open); content.Children.Add(outcome);
    var dialog = Dialog(this, Path.GetFileName(artifact.RelPath), content, "Done"); dialog.CloseButtonText = ""; await dialog.ShowAsync();
  }, "Preview closed.");
  private Task Send(ArtifactFolder folder, ReceiverArtifact artifact) => Run(async () =>
  {
    var targets = receiver.Destinations(folder.ProjectId).Where(d => d.Target.Kind is RouteKind.Session or RouteKind.Hoot).ToArray();
    if (targets.Length == 0) throw new ArgumentException("Open a session in this project first.");
    var picker = Choice("Destination", targets.Select((d, i) => (i.ToString(), d.Name)));
    var dialog = Dialog(this, "Send this file?", targets.Length == 1 ? Words("Send to " + targets[0].Name) : picker, "Send");
    if (await dialog.ShowAsync() == ContentDialogResult.Primary) await artifacts.SendAsync(folder.Path, artifact.RelPath, targets[int.Parse(Picked(picker))].Target);
  }, "Send request finished.");
  private static string? Kind(string path) => ArtifactCatalogPolicy.Kind(path);
}
