using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views;

public sealed partial class SettingsPane
{
  private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<McpManager, McpEditorRegistry> editorRegistries = new();
  private sealed class McpEditorRegistry
  {
    public Dictionary<string, McpServerEditor> Windows { get; } = [];
    public bool Closing { get; set; }
  }
  private McpEditorRegistry EditorRegistry => editorRegistries.GetValue(runtime.Mcp, _ => new());
  private Dictionary<string, McpServerEditor> ServerWindows => EditorRegistry.Windows;
  internal void CloseServerEditors()
  {
    EditorRegistry.Closing = true;
    foreach (var editor in ServerWindows.Values.ToArray()) editor.Close();
    ServerWindows.Clear();
  }
  private string? mcpProject;
  private async Task AddMcpRowsAsync(StackPanel stack, CancellationToken ct)
  {
    var loading = Description("Reading MCP servers…"); stack.Children.Add(loading);
    IReadOnlyList<McpServerView> servers;
    try { servers = await runtime.Mcp.ListAsync(ct); }
    catch (Exception ex) when (ex is IOException or InvalidOperationException)
    { loading.Text = "Couldn’t read MCP servers. Your saved configuration has been kept."; stack.Children.Add(Card("MCP servers", "Try reading the list again.", "Try Again", RenderAsync)); return; }
    stack.Children.Remove(loading);
    var projects = runtime.Projects.List();
    var choices = new[] { "Every project" }.Concat(projects.Select(p => p.Name)).ToArray();
    var picker = new ComboBox { Header = "Project", ItemsSource = choices, SelectedIndex = mcpProject is null ? 0 : Math.Max(0, Array.FindIndex(projects.ToArray(), p => p.Id == mcpProject) + 1), HorizontalAlignment = HorizontalAlignment.Stretch };
    picker.SelectionChanged += async (_, _) => { mcpProject = picker.SelectedIndex > 0 ? projects[picker.SelectedIndex - 1].Id : null; await RenderAsync(); };
    if (projects.Count > 0) stack.Children.Add(picker);
    var folders = projects.FirstOrDefault(p => p.Id == mcpProject)?.Folders.ToHashSet(StringComparer.OrdinalIgnoreCase);
    var shown = servers.Where(s => folders is null || s.Scope == "user" || s.Folder is not null && folders.Contains(s.Folder)).ToArray();
    stack.Children.Add(Card("MCP servers", shown.Length + " servers · " + servers.Count + " total", "Add server", ShowAddServerAsync));
    if (shown.Length == 0) stack.Children.Add(Description("No MCP servers yet"));
    string? lastGroup = null;
    foreach (var server in shown.OrderBy(s => s.Scope == "user" ? "" : s.Folder, StringComparer.OrdinalIgnoreCase))
    {
      var group = server.Scope == "user" ? "Every project" : projects.FirstOrDefault(p => p.Folders.Contains(server.Folder!))?.Name ?? server.Folder ?? "Project";
      if (group != lastGroup) { stack.Children.Add(new TextBlock { Text = group, FontSize = 18 }); lastGroup = group; }
      McpServerSettings details;
      try { details = await runtime.Mcp.SettingsAsync(server.Id, ct); }
      catch (McpRefusal) { continue; }
      var location = server.Scope == "user" ? "Every project" : "Private to project" + " · " + server.Folder;
      var card = Card(server.Name, (details.Url ?? details.Executable ?? "Command not reported") + "\n" + location + " · " + server.Transport + " · " + (server.Enabled ? "On" : "Off") + " · " + (server.Connected ? "Connected" : "Disconnected") + " · " + (server.ToolCount is { } count ? count + " tools" : "Tools not read"), "Open", () => OpenServerAsync(server.Id));
      var menu = new MenuFlyout(); var open = new MenuFlyoutItem { Text = "Open" }; open.Click += async (_, _) => await OpenServerAsync(server.Id); menu.Items.Add(open); card.ContextFlyout = menu;
      stack.Children.Add(card);
    }
  }

  internal int OpenServerEditorCount => ServerWindows.Count;
  internal async Task OpenServerAsync(string id, string? selectedSection = null)
  {
    if (EditorRegistry.Closing) throw new McpRefusal("The app is closing.");
    _ = await runtime.Mcp.SettingsAsync(id);
    if (ServerWindows.Values.FirstOrDefault(w => w.ServerId == id) is { } existing) { if (selectedSection is not null) await existing.SelectSectionAsync(selectedSection); ShellWindow.ShowSettingsOwnedWindow(existing); return; }
    var window = new McpServerEditor(runtime.Mcp, id, ActualTheme, runtime.Projects.List().SelectMany(p => p.Folders.Select(f => (p.Name, f))).ToArray());
    ServerWindows[id] = window;
    void FollowTheme(FrameworkElement sender, object args) => window.SetTheme(ActualTheme);
    ActualThemeChanged += FollowTheme;
    window.Closed += async (_, _) => { ActualThemeChanged -= FollowTheme; ServerWindows.Remove(id); if (!EditorRegistry.Closing) await RenderAsync(); };
    await window.LoadAsync(); if (selectedSection is not null) await window.SelectSectionAsync(selectedSection); ShellWindow.ShowSettingsOwnedWindow(window);
  }
}
