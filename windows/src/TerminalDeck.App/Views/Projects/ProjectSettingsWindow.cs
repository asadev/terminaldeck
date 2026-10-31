using System.Collections.Immutable;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Windowing;
using TerminalDeck.App.ViewModels.Projects;
using TerminalDeck.Core.Projects;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Projects;

internal static class ProjectSettingsWindow
{
  private sealed record Entry(Window Window, TaskCompletionSource Closed);
  private static readonly Dictionary<(IProjects, string), Entry> open = [];
  internal static Window? Find(IProjects projects, string id) => open.GetValueOrDefault((projects, id))?.Window;
  public static Task ShowAsync(XamlRoot owner, ProjectsViewModel model, string id)
  {
    var key = (model.Projects, id);
    if (open.TryGetValue(key, out var existing))
    {
      if (Environment.GetEnvironmentVariable("TD_W12_OFFSCREEN") != "1") existing.Window.Activate();
      return existing.Closed.Task;
    }
    var project = model.Projects.Get(id);
    if (id == ProjectIdentity.IndependentId) throw new ArgumentException("Independent has no project settings.");
    var window = new Window { Title = project.Name + " — Project settings" };
    var frame = new Grid { Style = PageStyle(), RequestedTheme = owner.Content is FrameworkElement source ? source.ActualTheme : ElementTheme.Default };
    frame.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) }); frame.RowDefinitions.Add(new() { Height = GridLength.Auto });
    var form = Stack(16); form.Margin = new Thickness(24); var error = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error };
    var name = Field("Name", project.Name, max: 80); var nameStatus = Words("", 12, true); var conflict = Stack(8); conflict.Visibility = Visibility.Collapsed;
    var nameEditor = new ProjectNameEditor((text, saved) => model.Projects.Rename(id, text, saved).Name, project.Name);
    Button? discard = null; var reading = false; var isClosed = false; var dispatcher = window.DispatcherQueue;
    void NameState()
    {
      if (isClosed) return;
      if (name.Text != nameEditor.Draft) { reading = true; name.Text = nameEditor.Draft; reading = false; }
      nameStatus.Text = nameEditor.Error.Length > 0 ? nameEditor.Error : nameEditor.Saving ? "Saving name…" : nameEditor.Dirty ? "Name not saved yet" : "Name saved";
      conflict.Visibility = nameEditor.Conflict ? Visibility.Visible : Visibility.Collapsed;
      if (discard is not null) discard.Visibility = nameEditor.Dirty ? Visibility.Visible : Visibility.Collapsed;
    }
    nameEditor.Changed += () => dispatcher.TryEnqueueHandled(NameState);
    name.BeforeTextChanging += (_, e) => { if (!reading) nameEditor.Edit(e.NewText); };
    conflict.Children.Add(Button("Keep mine", () => { nameEditor.Observe(model.Projects.Get(id).Name); nameEditor.KeepMine(); }));
    conflict.Children.Add(Button("Use saved", () => { nameEditor.Observe(model.Projects.Get(id).Name); nameEditor.UseSaved(); }));
    // Mac PROJPAGEProjectSettings: General, Server and Coding AI tabs. (The Mac's Tasks tab picks a
    // connected task system; that picker belongs to the Tasks page and is not on Windows yet.)
    var general = Stack(16); var server = Stack(16); var coding = Stack(16);
    var sections = new (string Title, StackPanel Panel)[] { ("General", general), ("Server", server), ("Coding AI", coding) };
    var tabs = new ContentControl();
    void ShowSection(string title)
    {
      foreach (var (t, panel) in sections) panel.Visibility = t == title ? Visibility.Visible : Visibility.Collapsed;
      tabs.Content = ViewSwitch(title, sections.Select(x => x.Title), ShowSection);
    }
    form.Children.Add(tabs); foreach (var (_, panel) in sections) form.Children.Add(panel);
    var nameGroup = Stack(8); nameGroup.Children.Add(name); nameGroup.Children.Add(nameStatus); nameGroup.Children.Add(conflict); Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(nameGroup, "projects.name-controls"); general.Children.Add(nameGroup);
    var about = Field("What it is", project.Preferences.Text("about"), true);
    general.Children.Add(about); general.Children.Add(AsyncButton("Save description", () => model.SaveValuesAsync(id, new Dictionary<string, JsonElement> { ["about"] = JsonSerializer.SerializeToElement(about.Text) })));
    var logo = new ContentControl(); var logoArea = Stack(8); logoArea.Children.Add(Heading("Logo", 18)); logoArea.Children.Add(logo);
    logoArea.Children.Add(Words("Found automatically in the project's folders when it has none. Drop an image here, choose one, or pick one found below. PNG, JPEG, WebP, BMP and ICO are supported.", 12, true));
    async Task SetLogo(string? path)
    {
      await model.RunAsync(() => model.Projects.SetPicture(id, path), path is null ? "Logo removed." : "Logo saved.");
    }
    logoArea.Children.Add(AsyncButton("Choose…", async () => { if (await PickPictureAsync(WinRT.Interop.WindowNative.GetWindowHandle(window)) is { } path) await SetLogo(path); }));
    var removeLogo = AsyncButton("Remove logo", () => SetLogo(null)); logoArea.Children.Add(removeLogo);
    logoArea.AllowDrop = true;
    logoArea.DragOver += (_, e) => { if (e.DataView.Contains(StandardDataFormats.StorageItems)) { e.AcceptedOperation = DataPackageOperation.Copy; e.Handled = true; } };
    logoArea.Drop += async (_, e) =>
    {
      var deferral = e.GetDeferral(); e.Handled = true;
      try { await model.RunAsync(async () => { var files = await e.DataView.GetStorageItemsAsync(); if (files.Count != 1 || files[0] is not Windows.Storage.StorageFile file) throw new ArgumentException("Drop one image file for the project logo."); model.Projects.SetPicture(id, file.Path); }, "Logo saved."); }
      finally { deferral.Complete(); }
    };
    var suggestions = Stack(6); logoArea.Children.Add(suggestions); general.Children.Add(Card(logoArea));
    var folders = Stack(8); general.Children.Add(Heading("Folders", 18)); general.Children.Add(folders);
    // Server: named in every brief for work in this project (Mac SETTINGS-TRUTH row 42).
    var linked = Field("Linked servers", project.Preferences.Text("linkedServers"), max: 2000);
    server.Children.Add(linked);
    server.Children.Add(Words("Names of your saved servers, separated by commas. Agent sessions started in this project are told them in their brief.", 12, true));
    server.Children.Add(AsyncButton("Save linked servers", () => model.SaveValuesAsync(id, new Dictionary<string, JsonElement> { ["linkedServers"] = JsonSerializer.SerializeToElement(linked.Text.Trim()) })));
    var providerChoices = new List<(string Use, ComboBox Provider, string? Account, string ProviderId)>();
    coding.Children.Add(Heading("Who uses what", 18));
    foreach (var use in new[] { "sessions", "chats" })
    {
      var target = coding;
      var saved = project.Preferences.WhoUsesWhat.FirstOrDefault(c => c.Use == use);
      var options = new[] { ("", "No default") }.Concat(Providers);
      if (saved is not null && !options.Any(o => o.Item1 == saved.Provider)) options = options.Append((saved.Provider, saved.Provider + " · unavailable saved AI"));
      var provider = Choice(use == "sessions" ? "Sessions" : "Chats", options, saved?.Provider ?? ""); target.Children.Add(provider);
      var account = saved?.AccountId is { } accountId ? model.Accounts?.List().FirstOrDefault(a => a.Id == accountId)?.Name ?? "Unavailable saved account" : "Its role's account, then the app default";
      target.Children.Add(Words("Account: " + account + ". Change account settings under Coding AIs.", 12, true));
      providerChoices.Add((use, provider, saved?.AccountId, saved?.Provider ?? ""));
    }
    Button SaveChoices() => AsyncButton("Save AI choices", () => model.RunAsync(() => model.Projects.SetWhoUsesWhat(id, providerChoices.Where(c => Picked(c.Provider).Length > 0)
      .Select(c => new ProjectAiChoice(c.Use, Picked(c.Provider), Picked(c.Provider) == c.ProviderId ? c.Account : null)).ToArray()), "AI choices saved."));
    var permission = Choice("Before agents change files", new[] { ("", "App default") }.Concat(TerminalDeck.Core.Agents.AgentOptions.PermissionModes.Select(m => (m, TerminalDeck.Core.Agents.AgentOptions.PermissionLabel(m)))), project.Preferences.Text("defaultPermission"));
    coding.Children.Add(SaveChoices()); coding.Children.Add(Heading("Agents in this project", 18)); coding.Children.Add(permission);
    coding.Children.Add(Words("Used by agents here whose own setting is App default. An agent's own choice wins.", 12, true));
    coding.Children.Add(AsyncButton("Save permission", () => model.SaveValuesAsync(id, new Dictionary<string, JsonElement> { ["defaultPermission"] = Picked(permission).Length == 0 ? JsonSerializer.SerializeToElement<string?>(null) : JsonSerializer.SerializeToElement(Picked(permission)) })));
    ShowSection("General");
    form.Children.Add(error); frame.Children.Add(PageScroll(form));
    var footer = Stack(8); footer.Orientation = Orientation.Horizontal; footer.HorizontalAlignment = HorizontalAlignment.Right; footer.Margin = new Thickness(24, 8, 24, 16);
    discard = Button("Discard name draft and close", () => { nameEditor.UseSaved(); window.Close(); }); discard.Visibility = Visibility.Collapsed; footer.Children.Add(discard);
    footer.Children.Add(AsyncButton("Done", async () => { if (!model.Projects.List().Any(p => p.Id == id) || await nameEditor.FlushAsync()) window.Close(); }, true)); Grid.SetRow(footer, 1); frame.Children.Add(footer); window.Content = frame;
    var ownerElement = owner.Content as FrameworkElement;
    void Theme(FrameworkElement element, object args) => frame.RequestedTheme = element.ActualTheme;
    if (ownerElement is not null) ownerElement.ActualThemeChanged += Theme;
    var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); open.Add(key, new(window, closed));
    var lifetime = new CancellationTokenSource(); string? scannedHome = null;
    async Task Suggest(IReadOnlyList<string> roots)
    {
      suggestions.Children.Clear();
      try
      {
        var paths = await Task.Run(() => ProjectLogoSuggestions.Find(roots), lifetime.Token); if (lifetime.IsCancellationRequested) return;
        if (paths.Count > 0) suggestions.Children.Add(Words("Found in the folder", 13, true));
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 }; var wrap = new ScrollViewer { Content = row, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Disabled };
        foreach (var path in paths)
        {
          var root = roots.FirstOrDefault(r => path.StartsWith(r, StringComparison.OrdinalIgnoreCase)); var label = root is null ? Path.GetFileName(path) : Path.GetRelativePath(root, path);
          var usable = ProjectLogoSuggestions.IsUsable(path);
          UIElement face = usable ? new Microsoft.UI.Xaml.Controls.Image { Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(path)), Width = 32, Height = 32, Stretch = Stretch.Uniform }
            : Path.GetExtension(path).Equals(".svg", StringComparison.OrdinalIgnoreCase) ? new Microsoft.UI.Xaml.Controls.Image { Source = new Microsoft.UI.Xaml.Media.Imaging.SvgImageSource(new Uri(path)), Width = 32, Height = 32 } : Words(Path.GetExtension(path), 11, true);
          var button = new Button { Content = face, Padding = new Thickness(4), IsEnabled = usable };
          button.Click += async (_, _) => await SetLogo(path);
          ToolTipService.SetToolTip(button, usable ? "Use " + label : label + " · export it as PNG to use it");
          Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, "Use " + label); row.Children.Add(button);
        }
        if (paths.Count > 0) suggestions.Children.Add(wrap);
      }
      catch (OperationCanceledException) { }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { if (!lifetime.IsCancellationRequested) suggestions.Children.Add(Words("Folder suggestions could not be read. You can still choose an image.", 12, true)); }
    }
    void Refresh()
    {
      if (isClosed) return;
      var current = model.Projects.List().FirstOrDefault(p => p.Id == id);
      if (current is null) { nameEditor.UseSaved(); nameEditor.Dispose(); form.IsHitTestVisible = false; error.Message = "This project was removed elsewhere. Close this window."; error.IsOpen = true; return; }
      nameEditor.Observe(current.Name); window.Title = current.Name + " — Project settings";
      logo.Content = ProjectPicture(model.Projects, current, 72); folders.Children.Clear();
      removeLogo.Visibility = model.Projects.PicturePath(current.Id) is null ? Visibility.Collapsed : Visibility.Visible; // nothing to remove on a letter tile
      folders.Children.Add(Words("Home: " + current.HomeFolder, 13));
      folders.Children.Add(AsyncButton("Choose home folder…", async () =>
      {
        if (await PickFolderAsync(WinRT.Interop.WindowNative.GetWindowHandle(window)) is not { } path) return;
        await model.RunAsync(() => { var before = model.Projects.Get(id); model.Projects.Save(new(id, before.Name, new[] { path }.Concat(before.Folders.Skip(1)).ToImmutableArray()), before); });
      }));
      foreach (var path in current.Folders.Skip(1))
      {
        var row = Stack(4); row.Children.Add(Words(path, 13)); row.Children.Add(AsyncButton("Remove folder", () => model.RunAsync(() => { var before = model.Projects.Get(id); model.Projects.Save(new(id, before.Name, before.Folders.Where(f => f != path).ToImmutableArray()), before); }))); folders.Children.Add(row);
      }
      folders.Children.Add(AsyncButton("Add a folder…", async () =>
      {
        if (await PickFolderAsync(WinRT.Interop.WindowNative.GetWindowHandle(window)) is not { } path) return;
        await model.RunAsync(() => { var before = model.Projects.Get(id); model.Projects.Save(new(id, before.Name, before.Folders.Add(path)), before); });
      }));
      error.Message = model.Message; error.Severity = model.IsError ? InfoBarSeverity.Error : InfoBarSeverity.Informational; error.IsOpen = model.Message.Length > 0;
      var scanKey = string.Join("|", current.Folders);
      if (scannedHome != scanKey && current.Folders.Length > 0) { scannedHome = scanKey; _ = Suggest(current.Folders); }
    }
    Action changed = () => dispatcher.TryEnqueueHandled(Refresh); model.Changed += changed;
    var closing = false;
    window.AppWindow.Closing += async (_, e) =>
    {
      if (!nameEditor.Dirty || closing) return;
      e.Cancel = true; if (await nameEditor.FlushAsync()) { closing = true; window.Close(); }
    };
    window.Closed += (_, _) =>
    {
      isClosed = true; if (ownerElement is not null) ownerElement.ActualThemeChanged -= Theme;
      lifetime.Cancel(); lifetime.Dispose(); nameEditor.Dispose(); model.Changed -= changed; open.Remove(key);
      if (Environment.GetEnvironmentVariable("TD_W12_OFFSCREEN") != "1" && model.Projects.List().Any(p => p.Id == id) && window.AppWindow.Presenter is not OverlappedPresenter { State: OverlappedPresenterState.Minimized })
      {
        try { model.Projects.PatchSettings(id, new Dictionary<string, JsonElement> { ["ui.settingsFrame"] = JsonSerializer.SerializeToElement(new { x = window.AppWindow.Position.X, y = window.AppWindow.Position.Y, width = window.AppWindow.Size.Width, height = window.AppWindow.Size.Height }) }); }
        catch (Exception ex) when (ex is IOException or ArgumentException or InvalidOperationException) { model.Notice("The project settings were kept, but its window position could not be saved.", true); }
      }
      closed.TrySetResult();
    };
    window.AppWindow.Resize(new SizeInt32(720, 820));
    if (project.Preferences.Values.TryGetValue("ui.settingsFrame", out var savedFrame) && savedFrame.ValueKind == JsonValueKind.Object)
    {
      try
      {
        var work = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        var width = Math.Clamp(savedFrame.GetProperty("width").GetInt32(), 560, Math.Max(560, work.Width)); var height = Math.Clamp(savedFrame.GetProperty("height").GetInt32(), 400, Math.Max(400, work.Height));
        window.AppWindow.MoveAndResize(new RectInt32(Math.Clamp(savedFrame.GetProperty("x").GetInt32(), work.X, Math.Max(work.X, work.X + work.Width - width)), Math.Clamp(savedFrame.GetProperty("y").GetInt32(), work.Y, Math.Max(work.Y, work.Y + work.Height - height)), width, height));
      }
      catch (Exception ex) when (ex is InvalidOperationException or FormatException or KeyNotFoundException or ArgumentException) { }
    }
    Refresh();
    if (Environment.GetEnvironmentVariable("TD_W12_OFFSCREEN") == "1") { window.AppWindow.Move(new PointInt32(-20000, -20000)); window.AppWindow.Show(false); } else window.Activate();
    return closed.Task;
  }
}
