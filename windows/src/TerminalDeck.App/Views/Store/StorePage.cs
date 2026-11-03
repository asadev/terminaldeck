using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Store;
using static TerminalDeck.App.Views.Servers.ServerUi;

namespace TerminalDeck.App.Views.Store;

public sealed class StorePage : Grid
{
  private readonly AppStoreService service;
  private readonly Action openMcp;
  private readonly StackPanel body = Stack(18);
  private string department = "Everything", query = "", category = "All", cost = "All";
  private bool installed;
  private bool busy;
  private string message = "";
  private readonly Action changed;
  public StorePage(AppStoreService service, Action openMcp, bool refreshCommunityOnLoad = true)
  {
    this.service = service; this.openMcp = openMcp;
    // Scroll() sizes the body to the viewport minus 48 px, so the margins must total 48 (wider ones clipped the right edge at 1280).
    Style = Canvas(); body.Margin = new Thickness(24, 34, 24, 24); body.MaxWidth = 1000; body.HorizontalAlignment = HorizontalAlignment.Left; Children.Add(Scroll(body));
    changed = () => DispatcherQueue.TryEnqueueHandled(Render);
    Loaded += async (_, _) => { service.Changed += changed; Render(); if (!refreshCommunityOnLoad) return; using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) }; await service.RefreshCommunityAsync(http); Render(); }; Unloaded += (_, _) => service.Changed -= changed; Render();
  }
  private void Render()
  {
    body.Children.Clear(); body.Children.Add(Header(new TextBlock(), Button("Add catalogue…", async () =>
    {
      var url = Field("Catalogue HTTPS URL", ""); var hash = Field("Trusted SHA-256 fingerprint", ""); var content = Stack(12); content.Children.Add(url); content.Children.Add(hash); content.Children.Add(Words("Use a catalogue and fingerprint supplied by a source you trust. Every installation will still show its own approval.", muted: true));
      if (await Dialog(XamlRoot, "Add app tools and extensions", content, "Read catalogue").ShowAsync() != ContentDialogResult.Primary) return;
      busy = true; RenderShelves();
      try { using var http = new HttpClient(); var count = await service.ImportCatalogAsync(url.Text, hash.Text, http); message = count + " catalogue entries added."; }
      catch (Exception ex) when (ex is not OutOfMemoryException) { message = ex.Message; }
      finally { busy = false; Render(); }
    })));
    if (department == "MCP servers") body.Children.Add(Button("Manage configured servers", () => { openMcp(); return Task.CompletedTask; }));
    var search = new TextBox { PlaceholderText = "adblock, cookies, youtube, postgres, github…", Text = query, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(12, 0, 0, 0) }; search.TextChanged += (_, _) => { query = search.Text; RenderShelves(); }; body.Children.Insert(0, search);
    var filters = Horizontal(); var available = service.Browse(department == "Everything" ? null : department);
    var categories = new ComboBox { Header = "Category", ItemsSource = new[] { "All" }.Concat(available.Select(r => r.Entry.Category).Distinct().Order()).ToArray(), SelectedItem = category };
    categories.SelectionChanged += (_, _) => { category = categories.SelectedItem as string ?? "All"; RenderShelves(); }; filters.Children.Add(categories);
    var costs = new ComboBox { Header = "Cost", ItemsSource = new[] { "All" }.Concat(available.Select(r => r.Entry.Cost).Distinct().Order()).ToArray(), SelectedItem = cost };
    costs.SelectionChanged += (_, _) => { cost = costs.SelectedItem as string ?? "All"; RenderShelves(); }; filters.Children.Add(costs);
    var onlyInstalled = new CheckBox { Content = "Installed", IsChecked = installed }; onlyInstalled.Click += (_, _) => { installed = onlyInstalled.IsChecked == true; RenderShelves(); }; filters.Children.Add(onlyInstalled); body.Children.Add(filters);
    var layout = new Grid { ColumnSpacing = 18, HorizontalAlignment = HorizontalAlignment.Stretch };
    layout.ColumnDefinitions.Add(new() { Width = new GridLength(228) }); layout.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    var rail = Stack(4);
    rail.Children.Add(Button("Everything · " + service.Browse().Length, () => { department = "Everything"; category = cost = "All"; Render(); return Task.CompletedTask; }, department == "Everything"));
    foreach (var item in AppStoreService.Departments)
    {
      var rows = service.Browse(item);
      rail.Children.Add(Button(item + " · " + rows.Length, () => { department = item; category = cost = "All"; Render(); return Task.CompletedTask; }, department == item && category == "All"));
      foreach (var shelf in rows.GroupBy(r => r.Entry.Category).OrderBy(g => g.Key))
      {
        var shelfButton = Button(shelf.Key + " · " + shelf.Count(), () => { department = item; category = shelf.Key; Render(); return Task.CompletedTask; }, department == item && category == shelf.Key); shelfButton.Margin = new Thickness(12, 0, 0, 0); rail.Children.Add(shelfButton);
      }
    }
    layout.Children.Add(rail); shelfHost?.Children.Remove(shelves); if (shelves.Parent is Panel previous) previous.Children.Remove(shelves); shelfHost = layout; Grid.SetColumn(shelves, 1); layout.Children.Add(shelves); body.Children.Add(layout); RenderShelves();
  }
  private readonly StackPanel shelves = Stack(18);
  // WinUI can report a null Parent for a child of a detached grid; remember the host explicitly.
  private Grid? shelfHost;
  private void RenderShelves()
  {
    shelves.Children.Clear();
    if (busy) shelves.Children.Add(new ProgressBar { IsIndeterminate = true });
    if (message.Length > 0) shelves.Children.Add(Words(message));
    if (department == "Community" && service.CatalogProblem is { } problem) shelves.Children.Add(Words("Community catalogue could not refresh: " + problem + ". Previously verified entries remain available when cached.", muted: true));
    if (department == "Community" && service.CatalogStale is { } stale) shelves.Children.Add(Words(stale, muted: true));
    var rows = service.Browse(department == "Everything" ? null : department, query, category == "All" ? null : category, cost == "All" ? null : cost, installed ? true : null);
    if (rows.Length == 0) { shelves.Children.Add(Words("No entries match this view. Clear your filters or add a trusted catalogue of app tools and browser extensions.", muted: true)); return; }
    foreach (var shelf in rows.GroupBy(r => r.Entry.Category))
    {
      var content = Stack(12); content.Children.Add(Words(shelf.Key, 17));
      foreach (var row in shelf)
      {
        var labels = Stack(4); labels.Children.Add(Words(row.Entry.Name, 13)); labels.Children.Add(Words(row.Entry.Summary, 12, true));
        labels.Children.Add(Words(row.Entry.Cost + " · " + row.Entry.Compatibility + " · " + row.Entry.Source + " · " + row.Entry.Version, 12, true));
        if (row.Entry.Needs is { Length: > 0 }) labels.Children.Add(Words("Needs " + string.Join(", ", row.Entry.Needs), 12, true));
        var actions = Horizontal();
        if (row.Entry.Delivery == "listing")
        {
          var open = Button("Open source", async () => { if (Uri.TryCreate(row.Entry.Source, UriKind.Absolute, out var uri) && uri.Scheme == "https" && string.IsNullOrEmpty(uri.UserInfo)) await Windows.System.Launcher.LaunchUriAsync(uri); }); actions.Children.Add(open);
        }
        else if (row.Installed is null) actions.Children.Add(Action(row, "install", "Install"));
        else
        {
          labels.Children.Add(Words("Installed " + row.Installed.Version, 12, true));
          if (row.UpdateAvailable || row.Entry.Delivery == "winget") actions.Children.Add(Action(row, "update", row.Entry.Delivery == "winget" ? "Check for update" : "Update"));
          actions.Children.Add(Action(row, "remove", "Remove…"));
        }
        content.Children.Add(DataRow(Icon("\uE719"), labels, actions));
      }
      shelves.Children.Add(Card(content));
    }
  }
  private Button Action(StoreRow row, string action, string label)
  {
    var button = Button(label, async () =>
    {
      busy = true; message = action + " · " + row.Entry.Name + "…"; RenderShelves();
      try
      {
        StoreInstallOptions? options = null;
        if (action != "remove" && (row.Entry.Delivery is "community" or "mcp-store") && row.Entry.Manifest is { } manifest)
        {
          var form = Stack(12); var folder = Field("Project folder · required for routines", ""); form.Children.Add(folder);
          var agentNames = manifest.TryGetProperty("agents", out var allowed) ? allowed.EnumerateArray().Select(a => a.GetString()!).ToArray() : new[] { "claude", "codex", "gemini" };
          var agents = agentNames.Select(a => new CheckBox { Content = a, IsChecked = true }).ToArray(); foreach (var agent in agents) form.Children.Add(agent);
          var values = new Dictionary<string, Func<string>>();
          var install = manifest.TryGetProperty("install", out var block) ? block : manifest;
          if (install.TryGetProperty("inputs", out var inputs)) foreach (var input in inputs.EnumerateArray()) { var key = input.GetProperty("key").GetString()!; if (input.TryGetProperty("kind", out var kind) && kind.GetString() == "secret") { var secret = new PasswordBox { Header = key }; values[key] = () => secret.Password; form.Children.Add(secret); }
            else { var field = Field(key, ""); values[key] = () => field.Text; form.Children.Add(field); } }
          if (await Dialog(XamlRoot, "Install " + row.Entry.Name, form, "Review installation").ShowAsync() != ContentDialogResult.Primary) return;
          options = new(string.IsNullOrWhiteSpace(folder.Text) ? null : folder.Text, agents.Where(a => a.IsChecked == true).Select(a => (string)a.Content).ToArray(), values.ToDictionary(p => p.Key, p => p.Value()));
        }
        await service.ChangeAsync(row.Entry.Id, action, options: options); message = action == "remove" ? "Removed " + row.Entry.Name + "." : "Installed " + row.Entry.Name + " " + row.Entry.Version + ".";
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { message = ex.Message; }
      finally { busy = false; RenderShelves(); }
    }); button.IsEnabled = !busy && (action == "remove" || row.Entry.Compatibility == "works"); return button;
  }
}
