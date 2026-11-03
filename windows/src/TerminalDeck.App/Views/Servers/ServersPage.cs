using System.Collections.Immutable;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.ViewModels.Servers;
using TerminalDeck.Core.Servers;
using static TerminalDeck.App.Views.Servers.ServerUi;

namespace TerminalDeck.App.Views.Servers;

public sealed partial class ServersPage : Grid
{
  public ServersViewModel Model { get; }
  private readonly IServerPageHost host;
  private readonly Action changed;
  private readonly bool settingsWindow;
  public ServersPage(ServersViewModel model, IServerPageHost host, bool settingsWindow = false)
  {
    Model = model; this.host = host; this.settingsWindow = settingsWindow;
    AllowDrop = true;
    DragOver += (_, args) => args.AcceptedOperation = Model.Selected is { Access.LookOnly: false } && Model.Section == "Files" && !Model.IsBusy && args.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)
      ? Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy : Windows.ApplicationModel.DataTransfer.DataPackageOperation.None;
    Drop += async (_, args) =>
    {
      if (Model.Selected is not { Access.LookOnly: false } || Model.Section != "Files" || Model.IsBusy || !args.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
      try { await UploadFilesAsync((await args.DataView.GetStorageItemsAsync()).OfType<Windows.Storage.StorageFile>().Select(file => file.Path).ToArray()); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { await Model.RunAsync(() => throw new ServerRefusal("Those dropped files could not be read. Try the file chooser.")); }
    };
    Style = Canvas(); changed = () => DispatcherQueue.TryEnqueueHandled(Render);
    Loaded += (_, _) => { Model.Changed += changed; Model.Refresh(); };
    Unloaded += (_, _) => Model.Changed -= changed;
    if (host is IServerSigninUiHost signin)
    {
      void SigninChanged(ServerSigninState state) { if (state.ServerId == Model.SelectedId && Model.Section == "Coding AIs") DispatcherQueue.TryEnqueueHandled(Render); }
      Loaded += (_, _) => signin.ServerSigninChanged += SigninChanged;
      Unloaded += (_, _) => signin.ServerSigninChanged -= SigninChanged;
    }
    Model.Refresh(); Render();
  }
  public void OpenServer(string id)
  {
    Model.Select(id); _ = Model.LoadAppsAsync();
  }
  private void Render()
  {
    if (settingsWindow) { RenderServerSettings(); return; }
    Children.Clear(); var body = Stack(28); body.Margin = new Thickness(24, 20, 24, 32); body.HorizontalAlignment = HorizontalAlignment.Stretch;
    if (Model.Selected is { } server) Detail(body, server); else Directory(body);
    if (Model.IsBusy)
    {
      var skeleton = Stack(12); skeleton.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 4 });
      foreach (var width in new[] { 0.85, 0.6, 0.7 }) skeleton.Children.Add(new Border { Height = 28, Opacity = width, Style = (Style)Application.Current.Resources["SurfaceCardStyle"] });
      body.Children.Add(skeleton);
    }
    if (Model.IsError) body.Children.Add(Button("Try Again", async () => { if (Model.Selected is null) Model.Refresh(); else if (Model.Section == "Files") await Model.RefreshFilesAsync(); else if (Model.Section == "Health") await Model.LoadHealthAsync(); else if (Model.Section == "Coding AIs") await Model.LoadCodingAisAsync(); else if (Model.Section == "Websites") await Model.LoadWebsitesAsync(); else await Model.LoadAppsAsync(); }));
    if (Model.Message.Length > 0) body.Children.Add(new TerminalDeck.App.Views.Notices.CompactNotice { IsOpen = true, IsClosable = false, Message = Model.Message, Severity = Model.IsError ? InfoBarSeverity.Error : InfoBarSeverity.Informational });
    if (Model.Preview.Length > 0)
    {
      var preview = Stack(8); var actions = Horizontal(Button(Model.LogsAppId is null ? "Close preview" : "Hide logs", () => { Model.ClosePreview(); return Task.CompletedTask; }));
      if (Model.LogsAppId is { } appId && Model.Apps?.FirstOrDefault(a => a.Id == appId) is { } app)
        actions.Children.Add(Button("Show older", async () => { await Model.LogsAsync(app); }));
      if (Model.PreviewPath is { } path)
      {
        actions.Children.Add(Button("Copy path", () => { Copy(path); return Task.CompletedTask; }));
        actions.Children.Add(Button("Open folder", async () => { await Model.LoadFilesAsync(path[..Math.Max(1, path.LastIndexOf('/'))]); }));
        actions.Children.Add(Button("Download", () => DownloadAsync(Model.Selected!, path)));
      }
      preview.Children.Add(actions); preview.Children.Add(new TextBox { Text = Model.Preview, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 400, Header = Model.PreviewPath ?? "Logs", FontFamily = TerminalDeck.App.Views.DeckFonts.Mono });
      body.Children.Add(Card(preview));
    }
    Children.Add(TerminalDeck.App.Views.Projects.ProjectAgentUi.PageFrame(body));
  }
  private void Directory(StackPanel body)
  {
    body.Children.Add(TerminalDeck.App.Views.Projects.ProjectAgentUi.PageHeader("Servers", "", null, null, Button("Add a server", AddAsync, true)));
    if (Model.Rows.Length == 0) body.Children.Add(Card(Words("No servers saved yet. Add a host and SSH user to get started. New servers are Look only.", muted: true)));
    var project = new ComboBox { Header = "Project", DisplayMemberPath = "Name", ItemsSource = new[] { new ServerProjectChoice("", "All projects") }.Concat(host.Projects).ToArray(), MaxWidth = 240, HorizontalAlignment = HorizontalAlignment.Left };
    project.SelectedItem = ((IEnumerable<ServerProjectChoice>)project.ItemsSource).FirstOrDefault(p => p.Id == (projectFilter ?? ""));
    project.SelectionChanged += (_, _) => { projectFilter = (project.SelectedItem as ServerProjectChoice)?.Id; Render(); };
    body.Children.Add(project);
    var rows = Stack(6);
    foreach (var server in Model.Rows.Where(s => string.IsNullOrEmpty(projectFilter) || s.ProjectId == projectFilter))
    {
      var labels = Stack(2); labels.Children.Add(Words(server.Name, 14));
      labels.Children.Add(Words(server.User + "@" + server.Host + ":" + server.Port, 12, true));
      var content = DataRow(Icon("\uE968"), labels, Words(server.Access.LookOnly ? "Look only" : "Changes ask first", 12, true), Icon("\uE76C"));
      var open = Button("Open " + server.Name, async () => { Model.Select(server.Id); await Model.LoadAppsAsync(); });
      open.Content = content; open.HorizontalAlignment = HorizontalAlignment.Stretch;
      open.HorizontalContentAlignment = HorizontalAlignment.Stretch; open.Padding = new Thickness(12, 10, 12, 10);
      var menu = new MenuFlyout();
      AddMenu(menu, "Open terminal", () => Model.RunAsync(async () => host.OpenSession(await Model.Servers.OpenTerminalAsync(server.Id, ServerCaller.Person)), "Opening a server session…", "Server session opened."), !server.Access.LookOnly);
      AddMenu(menu, "Settings…", () => ShowServerSettingsAsync(server.Id));
      AddMenu(menu, "Check now", () => Model.RunAsync(async () => { var result = await Model.Servers.TestAsync(server.Id, ServerCaller.Person); await Dialog(XamlRoot, "Connection", Words(result), "Done").ShowAsync(); }, "Checking server…", "Check finished."));
      AddMenu(menu, "Remove…", () => RemoveServerAsync(server)); open.ContextFlyout = menu;
      rows.Children.Add(open);
    }
    body.Children.Add(rows);
  }
  private void Detail(StackPanel body, SavedServer server)
  {

    var back = IconButton("\uE72B", "Back to servers", () => { Model.Select(null); return Task.CompletedTask; });
    var settings = IconButton("\uE713", "Server settings", () => Task.CompletedTask);
    var menu = new MenuFlyout();
    foreach (var section in new[] { "Access", "Connection" })
    {
      var item = new MenuFlyoutItem { Text = section == "Connection" ? "Advanced" : section }; item.Click += async (_, _) => await ShowServerSettingsAsync(server.Id, section); menu.Items.Add(item);
    }
    settings.Flyout = menu;
    var terminal = Button("Open terminal", OpenTerminalAsync, true);
    terminal.IsEnabled = !server.Access.LookOnly && !Model.IsBusy;
    var actions = Horizontal(settings, terminal);
    var switcher = TerminalDeck.App.Views.Projects.ProjectAgentUi.ViewSwitch(Model.Section,
      new[] { "Apps", "Coding AIs", "Websites", "Health", "Files" }, section => _ = SelectSectionAsync(section));
    body.Children.Add(TerminalDeck.App.Views.Projects.ProjectAgentUi.PageHeader(server.Name,
      server.User + "@" + server.Host + ":" + server.Port, back, switcher, actions));
    if (Model.Section is "Access" or "Connection") body.Children.Add(Words("Server settings · " + Model.Section, 13, true));
    if (Model.Section != "Health") body.Children.Add(Button(Model.Health is { } health ? $"CPU {health.CpuPercent:0.#}% · Memory {health.MemoryUsed * 100d / health.MemoryTotal:0.#}% · Disk {health.DiskUsed * 100d / health.DiskTotal:0.#}% → Health" : "Health · Not checked →", () => { Model.Tab("Health"); return Task.CompletedTask; }));
    if (Model.Section == "Files") Files(body, server);
    else if (Model.Section == "Apps") Apps(body, server);
    else if (Model.Section == "Health") Health(body);
    else if (Model.Section == "Coding AIs") CodingAis(body, server);
    else if (Model.Section == "Websites") Websites(body, server);
    else if (Model.Section == "Access") Access(body, server);
    else Connection(body, server);
  }
  private async Task SelectSectionAsync(string section)
  {
    Model.Tab(section);
    if (section == "Apps" && Model.Apps is null) await Model.LoadAppsAsync();
    else if (section == "Coding AIs" && Model.CodingAis is null) await Model.LoadCodingAisAsync();
    else if (section == "Websites" && Model.Websites is null) await Model.LoadWebsitesAsync();
    else if (section == "Files" && Model.Files is null && Model.Selected?.Access.Folders.Length > 0) await Model.LoadFilesAsync();
  }
  private Task OpenTerminalAsync() => Model.RunAsync(async () =>
  {
    if (Model.Selected is not { } server) throw new ServerRefusal("Choose a server.");
    host.OpenSession(await Model.Servers.OpenTerminalAsync(server.Id, ServerCaller.Person));
  }, "Opening a server session…", "Server session opened.");
  private string fileQuery = "";
  private string fileSort = "Name";
  private bool fileDescending;
  private bool fileGrid;
  private static void Copy(string text)
  {
    var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(text);
    Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data);
  }
  private Task DownloadAsync(SavedServer server, string path) => Model.RunAsync(async () =>
  {
    var local = await SaveFileAsync(host.WindowHandle, path.Split('/').Last());
    if (local is not null) await Model.Servers.DownloadAsync(server.Id, path, local, ServerCaller.Person);
  }, "Saving a file…", "Download finished.");
  private void Files(StackPanel body, SavedServer server)
  {
    if (server.Access.Folders.Length == 0) { body.Children.Add(Card(Words("Choose the folders this app may open in Access, then come back to Files."))); return; }
    body.Children.Add(Words("Files", 18));
    var path = Field("Folder", Model.Folder); path.TextChanged += (_, _) => Model.Folder = path.Text;
    path.KeyDown += async (_, args) => { if (args.Key == Windows.System.VirtualKey.Enter) { args.Handled = true; await Model.LoadFilesAsync(); } };
    var back = Button("Back", async () => { await Model.BackAsync(); }); back.IsEnabled = Model.CanGoBack && !Model.IsBusy;
    body.Children.Add(Header(path, Horizontal(back, Button("Open folder", async () => { await Model.LoadFilesAsync(); }), Button("Refresh", async () => { await Model.RefreshFilesAsync(); }))));
    var currentPath = Model.Files?.Path ?? Model.Folder;
    var crumbs = Horizontal();
    var root = server.Access.Folders.Where(r => currentPath == r.TrimEnd('/') || currentPath.StartsWith(r.TrimEnd('/') + "/", StringComparison.Ordinal)).OrderByDescending(r => r.Length).FirstOrDefault();
    if (root is not null)
    {
      var full = root.TrimEnd('/'); var rootPath = full.Length == 0 ? "/" : full;
      crumbs.Children.Add(Button(rootPath, async () => { await Model.LoadFilesAsync(rootPath); }));
      foreach (var part in currentPath[root.TrimEnd('/').Length..].Split('/', StringSplitOptions.RemoveEmptyEntries))
      {
        full += "/" + part; var destination = full;
        crumbs.Children.Add(Words("›", 12, true)); crumbs.Children.Add(Button(part, async () => { await Model.LoadFilesAsync(destination); }));
      }
      body.Children.Add(new ScrollViewer { Content = crumbs, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
    }
    var upload = Button("Upload files", async () => await UploadFilesAsync(await PickFilesAsync(host.WindowHandle)));
    upload.IsEnabled = !server.Access.LookOnly && !Model.IsBusy; body.Children.Add(upload);
    if (Model.Files is not { } files) { body.Children.Add(Card(Words("Open a folder to see its files.", muted: true))); return; }
    var query = Field("Search this folder", fileQuery); var sort = new ComboBox { Header = "Sort by", ItemsSource = new[] { "Name", "Type", "Size", "Modified" }, SelectedItem = fileSort };
    var descending = new CheckBox { Content = "Descending", IsChecked = fileDescending };
    var mode = new ComboBox { Header = "View", ItemsSource = new[] { "List", "Grid" }, SelectedIndex = fileGrid ? 1 : 0 };
    var controls = Horizontal(query, sort, descending, mode); body.Children.Add(controls);
    controls.SizeChanged += (_, _) => controls.Orientation = controls.ActualWidth < 720 ? Orientation.Vertical : Orientation.Horizontal;
    var rows = Stack(8); body.Children.Add(Card(rows));
    void Fill()
    {
      rows.Children.Clear();
      var filtered = files.Entries.Where(f => f.Name.Contains(fileQuery, StringComparison.OrdinalIgnoreCase));
      IOrderedEnumerable<ServerFile> ordered = fileSort switch
      {
        "Size" => fileDescending ? filtered.OrderByDescending(f => f.Size) : filtered.OrderBy(f => f.Size),
        "Modified" => fileDescending ? filtered.OrderByDescending(f => f.Modified) : filtered.OrderBy(f => f.Modified),
        "Type" => fileDescending ? filtered.OrderByDescending(f => FileType(f)) : filtered.OrderBy(f => FileType(f)),
        _ => fileDescending ? filtered.OrderByDescending(f => f.Name, StringComparer.OrdinalIgnoreCase) : filtered.OrderBy(f => f.Name, StringComparer.OrdinalIgnoreCase)
      };
      var visible = ordered.ThenBy(f => f.Name, StringComparer.OrdinalIgnoreCase).ToArray();
      var grid = new Grid { ColumnSpacing = 12, RowSpacing = 12 };
      if (fileGrid) { grid.ColumnDefinitions.Add(new()); grid.ColumnDefinitions.Add(new()); rows.Children.Add(grid); }
      foreach (var file in visible)
      {
        var labels = Stack(2); labels.Children.Add(Words(file.Name, 14)); labels.Children.Add(Words(FileType(file) + " · " + (file.Kind == "folder" ? "—" : Size(file.Size)) + " · " + Modified(file.Modified), 12, true));
        var actions = Horizontal();
        Task Open() => file.Kind == "folder" ? Model.LoadFilesAsync(file.Path) : Model.ReadAsync(file);
        var menu = new MenuFlyout();
        AddMenu(menu, "Open", Open, file.Kind is "folder" or "file");
        if (file.Kind == "file")
        {
          AddMenu(menu, "Download", () => DownloadAsync(server, file.Path));
          AddMenu(menu, "Rename", () => FileChangeAsync(server, file, false), !server.Access.LookOnly);
          AddMenu(menu, "Delete", () => FileChangeAsync(server, file, true), !server.Access.LookOnly);
        }
        AddMenu(menu, "Copy path", () => { Copy(file.Path); return Task.CompletedTask; });
        var open = Button("Open " + file.Name, Open); open.Content = DataRow(Icon(FileGlyph(file)), labels); open.HorizontalContentAlignment = HorizontalAlignment.Stretch; open.HorizontalAlignment = HorizontalAlignment.Stretch;
        open.IsEnabled = file.Kind is "folder" or "file"; open.ContextFlyout = menu;
        var more = new Button { Content = Icon("\uE712"), Flyout = menu, MinWidth = 36, MinHeight = 36 }; AutomationProperties.SetName(more, "Actions for " + file.Name); actions.Children.Add(more);
        var row = Header(open, actions); row.ContextFlyout = menu;
        if (fileGrid)
        {
          var index = grid.Children.Count; if (index % 2 == 0) grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
          Grid.SetRow(row, index / 2); Grid.SetColumn(row, index % 2); grid.Children.Add(row);
        }
        else rows.Children.Add(row);
      }
      if (visible.Length == 0) rows.Children.Add(Words(fileQuery.Length > 0 ? "No matching files." : "This folder is empty.", muted: true));
    }
    query.TextChanged += (_, _) => { fileQuery = query.Text; Fill(); };
    sort.SelectionChanged += (_, _) => { fileSort = sort.SelectedItem?.ToString() ?? "Name"; Fill(); };
    descending.Click += (_, _) => { fileDescending = descending.IsChecked == true; Fill(); };
    mode.SelectionChanged += (_, _) => { fileGrid = mode.SelectedIndex == 1; Fill(); }; Fill();
    if (files.More) body.Children.Add(Button("Show more", async () => { await Model.MoreFilesAsync(); }));
  }
  private async Task UploadFilesAsync(IReadOnlyList<string> paths)
  {
    if (paths.Count == 0) return;
    var server = Model.Selected ?? throw new ServerRefusal("Choose a server.");
    var folder = Model.Files?.Path ?? Model.Folder;
    var files = paths.Select(path => new FileInfo(path)).ToArray();
    if (files.Length > 16 || files.Any(file => !file.Exists || file.Length > ServerFilesScript.TransferLimit))
    { await Model.RunAsync(() => throw new ServerRefusal("Choose up to 16 files, up to 8 MB each.")); return; }
    var preview = Stack(8); preview.Children.Add(Words("Upload to " + folder + ". Existing files will not be overwritten."));
    foreach (var file in files) preview.Children.Add(Words(file.Name + " · " + Size(file.Length)));
    if (await Dialog(XamlRoot, "Upload files?", preview, "Continue").ShowAsync() != ContentDialogResult.Primary) return;
    var completed = 0;
    var ok = await Model.RunAsync(async () =>
    {
      foreach (var file in files)
      {
        await Model.Servers.UploadAsync(server.Id, folder.TrimEnd('/') + "/" + file.Name, await File.ReadAllBytesAsync(file.FullName), ServerCaller.Person); completed++;
      }
    }, "Uploading files…", "Files uploaded.");
    if (ok) await Model.RefreshFilesAsync();
    else if (completed > 0)
    {
      var failure = Model.Message;
      await Model.RefreshFilesAsync();
      await Model.RunAsync(() => throw new ServerRefusal($"{completed} of {files.Length} files uploaded. The remaining files were kept. {failure}"));
    }
  }
  private static string Modified(double seconds)
  {
    try { return DateTimeOffset.FromUnixTimeSeconds((long)seconds).LocalDateTime.ToString("g"); }
    catch (ArgumentOutOfRangeException) { return "Unknown modified date"; }
  }
  private static string FileType(ServerFile file) => file.Kind == "folder" ? "Folder" : file.Kind == "link" ? "Link" : Path.GetExtension(file.Name).ToLowerInvariant() switch
  {
    ".png" or ".jpg" or ".jpeg" or ".gif" or ".webp" or ".svg" => "Picture",
    ".mp4" or ".mov" or ".webm" => "Video", ".mp3" or ".wav" or ".m4a" => "Audio",
    ".pdf" or ".docx" or ".txt" or ".md" => "Document", _ => file.Kind == "file" ? "File" : "Special file"
  };
  private static string FileGlyph(ServerFile file) => FileType(file) switch
  { "Folder" => "\uE8B7", "Picture" => "\uEB9F", "Video" => "\uE714", "Audio" => "\uE8D6", "Link" => "link", _ => "\uE8A5" };
  private static Grid FileRow(params FrameworkElement[] children)
  {
    var row = DataRow(children);
    row.ColumnDefinitions[2].Width = new GridLength(80);
    row.ColumnDefinitions[3].Width = new GridLength(88);
    return row;
  }
  private async Task FileChangeAsync(SavedServer server, ServerFile file, bool delete)
  {
    var value = Field(delete ? "Type the exact file name" : "New file name", delete ? "" : file.Name);
    var dialog = Dialog(XamlRoot, delete ? "Delete file" : "Rename file", value, "Continue");
    if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
    if (await Model.RunAsync(async () => await Model.Servers.ChangeFileAsync(server.Id, file.Path, delete ? "delete" : "rename", delete ? null : value.Text, delete ? value.Text : null, ServerCaller.Person), "Changing file…", "File changed.")) await Model.RefreshFilesAsync();
  }
  private void Apps(StackPanel body, SavedServer server)
  {
    var appActions = Horizontal(Button("Refresh apps", async () => { await Model.LoadAppsAsync(); }));
    if (Model.Servers is ServerService owningApps)
    {
      var create = Button("Create app…", () => EditDockerAppAsync(server, owningApps, false), true); create.IsEnabled = !server.Access.LookOnly && !Model.IsBusy; appActions.Children.Add(create);
      var configure = Button("Configuration…", () => EditDockerAppAsync(server, owningApps, true)); configure.IsEnabled = !server.Access.LookOnly && !Model.IsBusy; appActions.Children.Add(configure);
    }
    body.Children.Add(Header(Words("Apps", 18), appActions));
    if (Model.Apps is null) { body.Children.Add(Card(Words("Refresh apps to read this server's Docker containers.", muted: true))); return; }
    var filters = Horizontal();
    foreach (var filter in new[] { "All", "Running", "Stopped" })
    {
      var count = Model.Apps.Count(app => Matches(app, filter));
      filters.Children.Add(Button(filter + " " + count, () => { appFilter = filter; Render(); return Task.CompletedTask; }, appFilter == filter));
    }
    body.Children.Add(filters);
    var rows = Stack(0);
    foreach (var app in Model.Apps.Where(app => Matches(app, appFilter)))
    {
      var labels = Stack(3); labels.Children.Add(Words(app.Name, 14)); labels.Children.Add(Words(app.Image, 12, true));
      if (!string.IsNullOrWhiteSpace(app.Ports)) labels.Children.Add(Words(app.Ports, 12, true));
      var actions = Horizontal(); actions.Children.Add(Button("Logs", async () => { await Model.LogsAsync(app); }));
      var more = new Button { Content = Icon("\uE712"), MinWidth = 32, MinHeight = 32 };
      AutomationProperties.SetName(more, "Actions for " + app.Name); ToolTipService.SetToolTip(more, "Actions for " + app.Name);
      var menu = new MenuFlyout();
      foreach (var op in new[] { "start", "stop", "restart" })
        AddMenu(menu, char.ToUpperInvariant(op[0]) + op[1..], async () =>
        { if (await Model.RunAsync(async () => await Model.Servers.ControlAsync(server.Id, app.Id, op, ServerCaller.Person), "Waiting for approval…", "App changed.")) await Model.LoadAppsAsync(); }, !server.Access.LookOnly);
      more.Flyout = menu; actions.Children.Add(more);
      rows.Children.Add(DataRow(Icon("\uE7B8"), labels, Words(app.State + " · " + app.Status, 12, true), actions));
    }
    if (!Model.Apps.Any(app => Matches(app, appFilter))) rows.Children.Add(Words("No apps in this view.", muted: true));
    body.Children.Add(Card(rows));
  }
  private void Health(StackPanel body)
  {
    body.Children.Add(Header(Words("Health", 18), Button("Check now", async () => { await Model.LoadHealthAsync(); })));
    if (Model.Health is not { } health)
    { body.Children.Add(Card(Words(Model.IsError ? "Server health could not be read. Check the connection and try again." : "Check now to read CPU, memory, disk and load from this server. No health check has run yet.", muted: true))); return; }
    body.Children.Add(Words("Checked " + health.CheckedAt.LocalDateTime.ToString("g") + (Model.IsError ? " · Last successful reading" : ""), 12, true));
    var metrics = Stack(16);
    foreach (var (name, text, value) in new[]
    {
      ("CPU", $"{health.CpuPercent:0.#}% · {health.Cpus} cores", health.CpuPercent),
      ("Memory", $"{Size(health.MemoryUsed)} of {Size(health.MemoryTotal)}", health.MemoryUsed * 100d / health.MemoryTotal),
      ("Disk", $"{Size(health.DiskUsed)} of {Size(health.DiskTotal)}", health.DiskUsed * 100d / health.DiskTotal)
    })
    {
      var metric = Stack(6); metric.Children.Add(Words(name + " · " + text)); metric.Children.Add(new ProgressBar { Minimum = 0, Maximum = 100, Value = value }); metrics.Children.Add(metric);
    }
    metrics.Children.Add(Words($"Load · {health.Load1:0.##} / {health.Load5:0.##} / {health.Load15:0.##} (1 / 5 / 15 minutes)")); body.Children.Add(Card(metrics));
  }
  private string appFilter = "All";
  private static bool Matches(ServerApp app, string filter) => filter == "All" || (filter == "Running" ? app.State.Equals("running", StringComparison.OrdinalIgnoreCase) : !app.State.Equals("running", StringComparison.OrdinalIgnoreCase));
  private void Access(StackPanel body, SavedServer server)
  {
    var look = new ToggleSwitch { Header = "Look only", IsOn = server.Access.LookOnly, OnContent = "Server changes are refused", OffContent = "Server changes ask first" };
    var folders = Field("Allowed folders · one full Linux path per line", string.Join('\n', server.Access.Folders), true);
    body.Children.Add(Words("Access", 18)); body.Children.Add(look); body.Children.Add(folders); body.Children.Add(Words("Files stays within these folders. A server terminal can run commands elsewhere and needs separate approval.", muted: true));
    body.Children.Add(Words("AI apps that may use this server", 18));
    var checks = host.AiApps.Select(app => (app.Id, Check: new CheckBox { Content = CallerName(app.Name), IsChecked = server.Access.AiApps.Contains(app.Id) })).ToArray();
    foreach (var (id, check) in checks)
    {
      ToolTipService.SetToolTip(check, "Connection identity: " + id);
      AutomationProperties.SetHelpText(check, "Connection identity: " + id);
      body.Children.Add(check);
    }
    if (checks.Length == 0) body.Children.Add(Words("No connected AI apps. Hoot and this machine's own sessions can use saved servers.", muted: true));
    body.Children.Add(Button("Save access", async () =>
    {
      var chosen = checks.Where(c => c.Check.IsChecked == true).Select(c => c.Id).Concat(server.Access.AiApps.Where(id => !host.AiApps.Any(a => a.Id == id))).ToImmutableArray();
      await Model.RunAsync(async () => await Model.Servers.SetAccessAsync(server.Id, new(look.IsOn, folders.Text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToImmutableArray(), chosen), ServerCaller.Person), "Waiting for approval…", "Access saved.");
    }, true));
  }
  private void Connection(StackPanel body, SavedServer server)
  {
    body.Children.Add(Words("Connection", 18));
    var serverName = Field("Server name", server.Name);
    body.Children.Add(Header(serverName, Button("Save name", () => Model.RunAsync(async () => await Model.Servers.RenameAsync(server.Id, serverName.Text, ServerCaller.Person), "Saving name…", "Server renamed."))));
    body.Children.Add(Button("Review host fingerprint", async () =>
    {
      string? key = null;
      if (!await Model.RunAsync(async () => key = await Model.Servers.ScanHostKeyAsync(server.Id, ServerCaller.Person), "Reading the host public key…", "Host public key read.")) return;
      var fingerprint = TerminalDeck.Platform.Windows.Servers.WindowsOpenSshRuntime.HostKeyFingerprint(key!);
      var dialog = Dialog(XamlRoot, "Check the server fingerprint", Words(fingerprint + "\n\nCompare this with the server owner through a trusted channel. A network scan alone does not prove who owns the server."), "Trust this key");
      if (await dialog.ShowAsync() == ContentDialogResult.Primary) await Model.RunAsync(async () => await Model.Servers.TrustHostKeyAsync(server.Id, key!, ServerCaller.Person), "Waiting for approval…", "Host key trusted.");
    }));
    body.Children.Add(Button("Test connection", async () => { string result = ""; await Model.RunAsync(async () => result = await Model.Servers.TestAsync(server.Id, ServerCaller.Person), "Testing SSH…", "Connection test finished."); if (result.Length > 0) await Dialog(XamlRoot, "Connection", Words(result), "OK").ShowAsync(); }));
    body.Children.Add(Button("Remove server", () => RemoveServerAsync(server)));
  }
  private async Task RemoveServerAsync(SavedServer server)
  {
    var fields = Stack(10); fields.Children.Add(Words("Remove this server from the app? Files and apps on the server stay where they are."));
    var name = Field("Type " + server.Name); fields.Children.Add(name);
    var dialog = Dialog(XamlRoot, "Remove server", fields, "Remove server");
    if (await dialog.ShowAsync() == ContentDialogResult.Primary && await Model.RunAsync(async () => await Model.Servers.RemoveAsync(server.Id, name.Text, ServerCaller.Person), "Removing server…", "Server removed.")) Model.Select(null);
  }
  private string? projectFilter;
  private async Task AddAsync()
  {
    var fields = Stack(14); var name = Field("Name"); var hostField = Field("Host"); var port = Field("SSH port", "22"); var user = Field("SSH user");
    var auth = new ComboBox { Header = "Sign in with", HorizontalAlignment = HorizontalAlignment.Stretch }; auth.Items.Add("Key file"); auth.Items.Add("Password"); auth.SelectedIndex = 0;
    var password = new PasswordBox { Header = "Key passphrase (if needed)" };
    string? picked = null; Button? pick = null;
    pick = Button("Choose key file", async () => { picked = await PickFileAsync(this.host.WindowHandle); if (picked is not null && pick is not null) pick.Content = "Key: " + Path.GetFileName(picked); });
    auth.SelectionChanged += (_, _) => { password.Header = auth.SelectedIndex == 1 ? "SSH password" : "Key passphrase (if needed)"; pick.Visibility = auth.SelectedIndex == 0 ? Visibility.Visible : Visibility.Collapsed; };
    foreach (var field in new UIElement[] { name, hostField, port, user, auth, pick, password, Words("The key is copied into this app's protected data folder. Passwords are kept in Windows Credential Manager. New servers start Look only.", muted: true) }) fields.Children.Add(field);
    var project = new ComboBox { Header = "Project", HorizontalAlignment = HorizontalAlignment.Stretch, DisplayMemberPath = "Name", ItemsSource = new[] { new ServerProjectChoice("", "No project") }.Concat(host.Projects).ToArray(), SelectedIndex = 0 };
    fields.Children.Add(project);
    var error = new Notices.CompactNotice(); fields.Children.Add(error);
    var dialog = Dialog(XamlRoot, "Add server", fields, "Continue"); dialog.DefaultButton = ContentDialogButton.Primary;
    // The server service owns a second approval dialog. Close this form first,
    // then reopen its original controls on refusal so the draft is not lost.
    while (await dialog.ShowAsync() == ContentDialogResult.Primary)
    {
      var bytes = Encoding.UTF8.GetBytes(password.Password);
      try
      {
        if (!int.TryParse(port.Text, out var number)) { error.Text = "Enter a valid SSH port."; continue; }
        var ok = await Model.RunAsync(async () =>
        {
          var saved = await Model.Servers.AddAsync(new(name.Text, hostField.Text.Trim(), number, user.Text.Trim(), auth.SelectedIndex == 0 ? ServerAuthentication.Key : ServerAuthentication.Password, (project.SelectedItem as ServerProjectChoice)?.Id is { Length: > 0 } projectId ? projectId : null), auth.SelectedIndex == 0 ? picked : null, bytes);
          Model.Select(saved.Id);
        }, "Saving server…", "Server saved. Review its host fingerprint in Connection.");
        if (ok) break;
        error.Text = Model.Message;
      }
      finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(bytes); }
    }
    password.Password = "";
  }
}
