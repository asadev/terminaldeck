using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.App.Views;

internal sealed class McpServerEditor : Window
{
  private readonly McpManager manager;
  private readonly (string Label, string Folder)[] projects;
  private readonly Grid frame = new();
  private readonly TextBlock title = Text("MCP server");
  private readonly Grid root = new() { Padding = new Thickness(24), RowSpacing = 16 };
  private readonly StackPanel page = new() { Spacing = 16 };
  private readonly Notices.CompactNotice feedback = new();
  private readonly ComboBox section = new() { ItemsSource = new[] { "General", "Tools", "Secrets", "Log" }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
  private McpServerSettings? settings;
  private bool busy;
  private readonly Dictionary<string, McpArgumentForm> argumentForms = [];
  private readonly Dictionary<string, StackPanel> argumentHosts = [];
  public string ServerId { get; private set; }

  public McpServerEditor(McpManager manager, string id, ElementTheme theme, (string Label, string Folder)[] projects)
  {
    this.manager = manager; ServerId = id; this.projects = projects;
    frame.RequestedTheme = root.RequestedTheme = theme; root.SetResourceReference(Grid.BackgroundProperty, "DeckCanvasBrush");
    root.RowDefinitions.Add(new() { Height = GridLength.Auto }); root.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) }); root.RowDefinitions.Add(new() { Height = GridLength.Auto });
    root.Children.Add(section);
    var scroll = new ScrollViewer { Content = page, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }; Grid.SetRow(scroll, 1); root.Children.Add(scroll);
    Grid.SetRow(feedback, 2); root.Children.Add(feedback);
    frame.RowDefinitions.Add(new() { Height = new GridLength(40) }); frame.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    var header = new Grid(); header.SetResourceReference(Grid.BackgroundProperty, "DeckRailBrush");
    header.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var drag = new Grid(); title.FontSize = 13; title.Margin = new Thickness(16, 0, 0, 0); title.VerticalAlignment = VerticalAlignment.Center; drag.Children.Add(title); header.Children.Add(drag);
    var caption = new Grid(); Grid.SetColumn(caption, 1); header.Children.Add(caption);
    frame.Children.Add(header); Grid.SetRow(root, 1); frame.Children.Add(root); Content = frame; Title = "MCP server";
    _ = new WorkspaceTitleBar(this, frame, drag, caption);
    AppWindow.Resize(new Windows.Graphics.SizeInt32(760, 720));
    if (Environment.GetEnvironmentVariable("TD_SETTINGS_PROOF") is not null) AppWindow.Move(new Windows.Graphics.PointInt32(-20000, -20000));
    section.SelectionChanged += async (_, _) => await LoadAsync();
  }
  internal Task SelectSectionAsync(string name)
  {
    var index = name switch { "general" => 0, "tools" => 1, "secrets" => 2, "log" => 3, _ => throw new McpRefusal("Choose general, tools, secrets or log.") };
    section.SelectedIndex = index; return LoadAsync();
  }
  public void SetTheme(ElementTheme theme) => frame.RequestedTheme = root.RequestedTheme = theme;
  public async Task LoadAsync()
  {
    try
    {
      settings = await manager.SettingsAsync(ServerId); title.Text = Title = settings.Server.Name;
      page.Children.Clear();
      switch (section.SelectedIndex)
      {
        case 0: General(settings); break;
        case 1: Tools(); break;
        case 2: Secrets(settings); break;
        default: Log(); break;
      }
    }
    catch (Exception ex) when (ex is IOException or McpRefusal)
    { feedback.Text = "Couldn’t read server settings. Try again."; page.Children.Clear(); page.Children.Add(Action("Try Again", LoadAsync)); }
  }
  private void General(McpServerSettings current)
  {
    var server = current.Server;
    page.Children.Add(Text(server.Name, 22));
    page.Children.Add(Text(server.Transport + " · " + (server.Scope == "user" ? "Every project" : server.Scope + " · " + server.Folder)));
    page.Children.Add(Text("To change the connection type or project, remove this server and add it again."));
    if (server.Scope != "user") page.Children.Add(Text("This project server is private to this Windows user."));
    var enabled = new ToggleSwitch { Header = "On", IsOn = server.Enabled, OnContent = "On", OffContent = "Off" };
    enabled.Toggled += async (_, _) =>
    {
      enabled.IsEnabled = false;
      var desired = enabled.IsOn;
      await RunAsync(async () => await manager.EditPatchAsync(ServerId, JsonSerializer.SerializeToElement(new { enabled = desired })));
      // Read back saved policy after success or failure, without triggering another write.
      await LoadAsync();
    };
    page.Children.Add(enabled);
    page.Children.Add(Text(server.Connected ? "Connected" : "Disconnected"));
    if (server.Transport == "stdio")
    {
      var name = new TextBox { Header = "Name", MaxLength = 80, Text = server.Name };
      var command = new TextBox { Header = "Command", Text = WindowsCommandLine.Compose(current.Executable!, current.Arguments), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
      page.Children.Add(name); page.Children.Add(command);
      page.Children.Add(Action("Save", async () =>
      {
        await manager.EditPatchAsync(ServerId, JsonSerializer.SerializeToElement(new { name = name.Text.Trim(), command = command.Text }));
        ServerId = manager.ResolveId(name.Text.Trim(), server.Scope, server.Folder); await LoadAsync();
      }));
    }
    else
    {
      page.Children.Add(Text(current.Url ?? "Address not reported"));
      page.Children.Add(Text("Name and address are read-only. Remove and add the server to change them. Saved headers stay hidden."));
    }
    page.Children.Add(Action("Test connection", async () =>
    {
      feedback.Text = "Testing…";
      var tools = await manager.TestAsync(ServerId);
      feedback.Text = "Connection tested · " + tools.Count + " tools. Saved On/Off policy was kept.";
    }, complete: false));
    page.Children.Add(Action(server.Connected ? "Disconnect" : "Connect", async () =>
    { if (server.Connected) await manager.DisconnectAsync(ServerId); else await manager.ConnectAsync(ServerId); await LoadAsync(); }));
    page.Children.Add(Action("Duplicate", async () => { feedback.Text = await McpServerForm.ShowAsync(manager, root.XamlRoot, root.ActualTheme, projects, current) ? "Server added" : "Cancelled"; }, complete: false));
    page.Children.Add(Action("Remove…", async () =>
    {
      var dialog = new ContentDialog { XamlRoot = root.XamlRoot, RequestedTheme = root.ActualTheme, Title = "Remove server", Content = Text("Remove " + server.Name + " and its saved credentials? Its connection will stop. Other servers stay configured."), PrimaryButtonText = "Remove server", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
      if (await dialog.ShowAsync() == ContentDialogResult.Primary) { await manager.RemoveAsync(ServerId); Close(); }
      else feedback.Text = "Server kept";
    }, complete: false));
  }
  private void Tools()
  {
    page.Children.Add(Text("Read the server’s live tool list. Reading an off server uses a temporary test connection and keeps it off."));
    var list = new StackPanel { Spacing = 16 }; page.Children.Add(list);
    page.Children.Insert(0, Action("Read tools", async () =>
    {
      feedback.Text = "Reading tools…";
      var inventory = await manager.TestAsync(ServerId);
      list.Children.Clear();
      if (inventory.Count == 0) list.Children.Add(Text("No tools reported"));
      foreach (var tool in inventory) AddTool(list, tool);
      feedback.Text = inventory.Count + " tools read";
    }, complete: false));
  }
  private void AddTool(StackPanel list, McpRemoteTool tool)
  {
    var group = new StackPanel { Spacing = 8 };
    var enabled = new ToggleSwitch { Header = tool.Title ?? tool.Name, IsOn = !settings!.DisabledTools.Contains(tool.Name), OnContent = "On", OffContent = "Off" };
    enabled.Toggled += async (_, _) =>
    {
      enabled.IsEnabled = false;
      var success = false;
      await RunAsync(async () =>
      {
        var current = await manager.SettingsAsync(ServerId);
        var names = current.DisabledTools.ToHashSet(StringComparer.Ordinal);
        if (enabled.IsOn) names.Remove(tool.Name); else names.Add(tool.Name);
        await manager.EditPatchAsync(ServerId, JsonSerializer.SerializeToElement(new { disabledTools = names.ToArray() }));
        settings = await manager.SettingsAsync(ServerId); success = true;
      });
      if (!success) { await LoadAsync(); return; }
      enabled.IsEnabled = true;
    };
    group.Children.Add(enabled);
    group.Children.Add(Text(tool.Name));
    if (tool.Description is { Length: > 0 } description) group.Children.Add(Text(description));
    if (!argumentForms.TryGetValue(tool.Name, out var form)) argumentForms[tool.Name] = form = new McpArgumentForm(tool.InputSchema, null);
    if (argumentHosts.TryGetValue(tool.Name, out var oldHost)) oldHost.Children.Remove(form);
    var result = Text("");
    var body = new StackPanel { Spacing = 12 }; body.Children.Add(form); argumentHosts[tool.Name] = body;
    body.Children.Add(Action("Run tool", async () =>
    {
      var args = form.Read();
      McpSchema.Validate(tool.InputSchema, args);
      result.Text = "Running…";
      await manager.ConnectAsync(ServerId);
      var output = await manager.CallAsync(ServerId, tool.Name, args);
      result.Text = JsonSerializer.Serialize(output, new JsonSerializerOptions { WriteIndented = true });
    }));
    body.Children.Add(result);
    group.Children.Add(new Expander { Header = "Try a tool", Content = body, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch });
    list.Children.Add(group);
  }
  private void Secrets(McpServerSettings current)
  {
    page.Children.Add(Text("Saved values stay hidden. Setting a value changes only that named value."));
    var http = current.Server.Transport != "stdio";
    page.Children.Add(Text(http ? "Request headers are managed here using protected storage." : "Environment variables"));
    var names = http ? current.HeaderNames : current.EnvironmentNames;
    page.Children.Add(Text(names.Length == 0 ? "No saved values" : "Saved names: " + string.Join(", ", names)));
    var name = new TextBox { Header = "Name", MaxLength = 128 };
    var value = new PasswordBox { Header = "Secure value", MaxLength = 2560 };
    page.Children.Add(name); page.Children.Add(value);
    page.Children.Add(Action("Set value", async () =>
    {
      if (string.IsNullOrWhiteSpace(name.Text) || value.Password.Length == 0) throw new McpRefusal("Enter a name and secure value.");
      await manager.SetSecretAsync(ServerId, name.Text, value.Password, http);
      value.Password = ""; await LoadAsync();
    }));
  }
  private void Log()
  {
    page.Children.Add(Text("Last errors in this app run. Private server error text and credentials are omitted."));
    var log = Text("Log not read yet"); page.Children.Add(log);
    page.Children.Add(Action("Read log", async () =>
    {
      var exported = await manager.ExportAsync(ServerId);
      var rows = exported.GetProperty("log").EnumerateArray().Select(r => r.GetProperty("At").GetDateTimeOffset().ToLocalTime().ToString("g") + " · " + r.GetProperty("Message").GetString()).ToArray();
      log.Text = rows.Length == 0 ? "No errors reported" : string.Join("\n", rows);
    }));
  }
  private Button Action(string label, Func<Task> action, bool complete = true)
  {
    var button = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Left };
    button.Click += async (_, _) => { button.IsEnabled = false; await RunAsync(action, complete); button.IsEnabled = true; };
    return button;
  }
  private async Task RunAsync(Func<Task> action, bool complete = true)
  {
    if (busy) { feedback.Text = "Wait for the current action to finish."; return; }
    busy = true; section.IsEnabled = false; feedback.Text = "Working…";
    try { await action(); if (complete) feedback.Text = "Done"; }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    { feedback.Text = ex is McpRefusal ? ex.Message : ex is JsonException ? "Enter valid JSON arguments." : "The action could not finish. Your saved settings have been kept. Try again."; }
    finally { busy = false; section.IsEnabled = true; }
  }
  private static TextBlock Text(string value, double size = 14) => new() { Text = value, FontSize = size, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
}
