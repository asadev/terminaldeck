using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.App.Views;

internal sealed class McpSecretFields : StackPanel
{
  private readonly List<(TextBox Name, PasswordBox Value)> fields = [];
  public McpSecretFields(string label)
  {
    Spacing = 8;
    Children.Add(new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap });
    var add = new Button { Content = "Add value" }; add.Click += (_, _) => Add(); Children.Add(add);
  }
  private void Add()
  {
    var name = new TextBox { Header = "Name", MaxLength = 128 };
    var value = new PasswordBox { Header = "Secure value", MaxLength = 2560 };
    var row = new StackPanel { Spacing = 8 }; row.Children.Add(name); row.Children.Add(value);
    var remove = new Button { Content = "Remove value" };
    remove.Click += (_, _) => { fields.RemoveAll(f => f.Name == name); value.Password = ""; Children.Remove(row); };
    row.Children.Add(remove); fields.Add((name, value)); Children.Add(row);
  }
  public Dictionary<string, string> Read()
  {
    if (fields.Any(f => string.IsNullOrWhiteSpace(f.Name.Text) || f.Value.Password.Length == 0)) throw new McpRefusal("Give every secure value a name and value, or remove its empty row.");
    if (fields.Select(f => f.Name.Text).Distinct(StringComparer.OrdinalIgnoreCase).Count() != fields.Count) throw new McpRefusal("Use each secure value name once.");
    return fields.ToDictionary(f => f.Name.Text, f => f.Value.Password);
  }
  public void ClearValues() { foreach (var field in fields) field.Value.Password = ""; }
}

internal static class McpServerForm
{
  public static async Task<bool> ShowAsync(McpManager manager, XamlRoot root, ElementTheme theme,
    (string Label, string Folder)[] projects, McpServerSettings? source = null)
  {
    var name = new TextBox { Header = "Name", MaxLength = 80, Text = source is null ? "" : source.Server.Name + "-copy" };
    var kind = new ComboBox { Header = "Connection", ItemsSource = new[] { "Command", "Web address", "SSE" }, SelectedIndex = source?.Server.Transport switch { "stdio" => 0, "sse" => 2, _ => 1 }, HorizontalAlignment = HorizontalAlignment.Stretch };
    var address = new TextBox { Header = "Web address", PlaceholderText = "https://example.com/mcp", Text = source?.Url ?? "" };
    var command = new TextBox { Header = "Command", Text = source?.Executable is { } exe ? WindowsCommandLine.Compose(exe, source.Arguments) : "" };
    var scope = new ComboBox { Header = "Save for", ItemsSource = new[] { "Every project", "Shared in project", "Private to project" }, SelectedIndex = source?.Server.Scope == "project" ? 1 : source?.Server.Scope == "local" ? 2 : 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    var project = new ComboBox { Header = "Project folder", ItemsSource = projects.Select(p => p.Label + " · " + p.Folder).ToArray(), SelectedIndex = projects.Length > 0 ? 0 : -1, HorizontalAlignment = HorizontalAlignment.Stretch };
    var env = new McpSecretFields("Environment variables · saved values stay hidden");
    var headers = new McpSecretFields("Request headers · saved values stay hidden");
    var explanation = new TextBlock { Text = source is null ? "Credentials belong in secure values, not the web address." : "This makes an independent server. Saved credentials are not copied; enter the values it needs.", TextWrapping = TextWrapping.Wrap };
    var feedback = new Notices.CompactNotice();
    var projectNote = new TextBlock { Text = projects.Length == 0 ? "Add a project before saving a project server." : projects.Length == 1 ? projects[0].Label + " · " + projects[0].Folder : "", TextWrapping = TextWrapping.Wrap };
    ContentDialog? activeDialog = null;
    void Refresh()
    {
      command.Visibility = env.Visibility = kind.SelectedIndex == 0 ? Visibility.Visible : Visibility.Collapsed;
      address.Visibility = headers.Visibility = kind.SelectedIndex == 0 ? Visibility.Collapsed : Visibility.Visible;
      project.Visibility = scope.SelectedIndex != 0 && projects.Length > 1 ? Visibility.Visible : Visibility.Collapsed;
      projectNote.Visibility = scope.SelectedIndex != 0 && projects.Length <= 1 ? Visibility.Visible : Visibility.Collapsed;
      if (activeDialog is not null) activeDialog.IsPrimaryButtonEnabled = scope.SelectedIndex == 0 || projects.Length > 0;
    }
    kind.SelectionChanged += (_, _) => Refresh(); scope.SelectionChanged += (_, _) => Refresh(); Refresh();
    var body = new StackPanel { Spacing = 16 };
    foreach (var child in new UIElement[] { explanation, feedback, name, kind, command, address, scope, project, projectNote, env, headers }) body.Children.Add(child);
    body.Children.Add(new TextBlock { Text = "Project servers are private to this Windows user.", TextWrapping = TextWrapping.Wrap });
    var dialog = new ContentDialog { XamlRoot = root, RequestedTheme = theme, Title = source is null ? "Add server" : "Duplicate server", Content = new ScrollViewer { Content = body, MaxHeight = 440, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalContentAlignment = HorizontalAlignment.Stretch }, PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
    activeDialog = dialog; Refresh();
    dialog.PrimaryButtonClick += async (_, args) =>
    {
      var deferral = args.GetDeferral(); feedback.Text = "Saving…";
      try
      {
        if (scope.SelectedIndex != 0 && project.SelectedIndex < 0) throw new McpRefusal("Choose a project folder.");
        await manager.AddAsync(new() { Name = name.Text.Trim(), Scope = scope.SelectedIndex == 0 ? "user" : scope.SelectedIndex == 1 ? "project" : "local", Folder = scope.SelectedIndex == 0 ? null : projects[project.SelectedIndex].Folder,
          Transport = kind.SelectedIndex switch { 0 => "stdio", 2 => "sse", _ => "http" }, Command = kind.SelectedIndex == 0 ? command.Text : null, Url = kind.SelectedIndex == 0 ? null : address.Text,
          Environment = kind.SelectedIndex == 0 ? env.Read() : [], Headers = kind.SelectedIndex == 0 ? [] : headers.Read() });
      }
      catch (Exception ex) when (ex is McpRefusal or ArgumentException or IOException or UnauthorizedAccessException) { args.Cancel = true; feedback.Text = ex is McpRefusal ? ex.Message : "The server could not be saved. Check the fields and try again."; }
      finally { deferral.Complete(); }
    };
    try { return await dialog.ShowAsync() == ContentDialogResult.Primary; }
    finally { env.ClearValues(); headers.ClearValues(); }
  }
}
