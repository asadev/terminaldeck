using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task VerifyW12McpEditorAsync(string output, Action<string, bool> check)
  {
    await using var manager = new McpManager(new JsonStateStore<McpManagerState>(dataRoot, "proof-mcp"), new W12ProofSecrets(), dataRoot, new W12ProofCommands(), new W12ProofConnections());
    var row = await manager.AddAsync(new() { Name = "tool-form", Scope = "user", Transport = "http", Url = "https://example.invalid/mcp" });
    var editor = new McpServerEditor(manager, row.Id, ElementTheme.Dark, []);
    try
    {
      await editor.LoadAsync(); ShowSettingsOwnedWindow(editor); await Task.Delay(300);
      var root = (FrameworkElement)editor.Content;
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        editor.SetTheme(theme);
        var section = SettingsTree(root).OfType<ComboBox>().First();
        foreach (var tab in new[] { 0, 1, 2, 3 })
        {
          section.SelectedIndex = tab; await Task.Delay(100);
          if (tab == 1)
          {
            InvokeW12(root, "Read tools"); await Task.Delay(150);
            var expander = SettingsTree(root).OfType<Expander>().First(); expander.IsExpanded = true; await Task.Delay(100);
          }
          if (tab == 3) { InvokeW12(root, "Read log"); await Task.Delay(100); }
          await CaptureSettingsAsync(root, Path.Combine(output, "mcp-editor-" + tab + "-" + theme.ToString().ToLowerInvariant() + ".png"));
          check("MCP editor " + theme + " tab " + tab + " renders", root.ActualWidth >= 600 && SettingsTree(root).OfType<Button>().Any());
        }
      }
      var tabs = SettingsTree(root).OfType<ComboBox>().First(); tabs.SelectedIndex = 1; await Task.Delay(100);
      InvokeW12(root, "Read tools"); await Task.Delay(150);
      SettingsTree(root).OfType<Expander>().First().IsExpanded = true; await Task.Delay(100);
      var message = SettingsTree(root).OfType<TextBox>().First(t => t.Header as string == "message"); message.Text = "retained argument";
      var count = SettingsTree(root).OfType<TextBox>().First(t => t.Header as string == "count"); count.Text = "invalid-number";
      tabs.SelectedIndex = 3; await Task.Delay(100); tabs.SelectedIndex = 1; await Task.Delay(100);
      InvokeW12(root, "Read tools"); await Task.Delay(150); SettingsTree(root).OfType<Expander>().First().IsExpanded = true; await Task.Delay(100);
      check("Tool argument drafts survive reopening including invalid numbers", SettingsTree(root).OfType<TextBox>().Any(t => t.Text == "retained argument") && SettingsTree(root).OfType<TextBox>().Any(t => t.Text == "invalid-number"));
      SettingsTree(root).OfType<TextBox>().First(t => t.Header as string == "count").Text = "2";
      InvokeW12(root, "Add item"); await Task.Delay(100);
      SettingsTree(root).OfType<TextBox>().First(t => (t.Header as string)?.StartsWith("Item", StringComparison.Ordinal) == true).Text = "array entry";
      InvokeW12(root, "Run tool"); await Task.Delay(200);
      check("Tool form runs through the real manager and displays the untrusted result", SettingsTree(root).OfType<TextBlock>().Any(t => t.Text.Contains("proof-result", StringComparison.Ordinal)));
      var toolSwitch = SettingsTree(root).OfType<ToggleSwitch>().First(); toolSwitch.IsOn = false; await Task.Delay(150);
      check("Tool toggle saves the actual enforced policy", (await manager.SettingsAsync(row.Id)).DisabledTools.Contains("proof"));
      await CaptureSettingsAsync(root, Path.Combine(output, "mcp-tool-result-dark.png"));
      var scroll = SettingsTree(root).OfType<ScrollViewer>().First(); scroll.ChangeView(null, scroll.ScrollableHeight, null); await Task.Delay(150);
      await CaptureSettingsAsync(root, Path.Combine(output, "mcp-tool-result-bottom-dark.png"));
      tabs.SelectedIndex = 0; await Task.Delay(150);
      SettingsTree(root).OfType<ToggleSwitch>().First().IsOn = false; await Task.Delay(150);
      check("Server On switch persists off policy", !(await manager.SettingsAsync(row.Id)).Server.Enabled);
      InvokeW12(root, "Test connection"); await Task.Delay(150);
      check("UI Test connection keeps off policy and no retained connection", !(await manager.SettingsAsync(row.Id)).Server.Enabled && !(await manager.SettingsAsync(row.Id)).Server.Connected);
    }
    finally { editor.Close(); }
  }
  private static void InvokeW12(DependencyObject root, string label)
  {
    var button = SettingsTree(root).OfType<Button>().First(b => b.Content as string == label || AutomationProperties.GetName(b) == label);
    var peer = FrameworkElementAutomationPeer.CreatePeerForElement(button);
    if (peer?.GetPattern(PatternInterface.Invoke) is IInvokeProvider invoke) invoke.Invoke();
    else throw new InvalidOperationException("Button cannot be invoked: " + label);
  }
  private sealed class W12ProofSecrets : ISecretStore
  {
    public ValueTask<byte[]?> ReadAsync(string name, CancellationToken ct = default) => ValueTask.FromResult<byte[]?>(null);
    public ValueTask WriteAsync(string name, ReadOnlyMemory<byte> value, CancellationToken ct = default) => ValueTask.CompletedTask;
    public ValueTask DeleteAsync(string name, CancellationToken ct = default) => ValueTask.CompletedTask;
  }
  private sealed class W12ProofCommands : IMcpCommandResolver
  { public McpCommand Resolve(string commandLine) => new(commandLine, []); }
  private sealed class W12ProofConnections : IMcpConnectionFactory
  {
    public ValueTask<IManagedMcpConnection> ConnectAsync(McpServerConfig config, ISecretStore secrets, CancellationToken ct) => ValueTask.FromResult<IManagedMcpConnection>(new W12ProofConnection());
  }
  private sealed class W12ProofConnection : IManagedMcpConnection
  {
    public ValueTask<IReadOnlyList<McpRemoteTool>> ToolsAsync(CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<McpRemoteTool>>([
      new("proof", JsonSerializer.SerializeToElement(new { type = "object", properties = new { message = new { type = "string", description = "Message sent to the tool" }, count = new { type = "integer" }, mode = new { type = "string", @enum = new[] { "brief", "full" } }, enabled = new { type = "boolean" }, items = new { type = "array", items = new { type = "string" } } } }), "Audit tool", "Synthetic tool for isolated form verification")]);
    public ValueTask<JsonElement> CallAsync(string tool, JsonElement arguments, CancellationToken ct) => ValueTask.FromResult(JsonSerializer.SerializeToElement(new { text = "proof-result", arguments }));
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
  }
}
