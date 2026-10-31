using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task VerifyW12CallersAsync(string output, Action<string, bool> check)
  {
    var folder = Path.Combine(dataRoot.DirectoryPath, "mcp", "callers"); Directory.CreateDirectory(folder);
    var server = (await Runtime.Mcp.ListAsync()).First().Id;
    var firstId = "ai:w12-first"; var otherId = "ai:w12-other";
    var first = Runtime.CallerAuthority.Provision(Runtime.Door, new(firstId, null, null, AiPermissionMode.Ask,
      ["mcp.list", "mcp.callers"], [McpTier.Read, McpTier.Alter], ["mcp:" + server]), _ => true);
    var other = Runtime.CallerAuthority.Provision(Runtime.Door, new(otherId, null, null, AiPermissionMode.Ask,
      ["mcp.list", "mcp.callers"], [McpTier.Read, McpTier.Alter], ["mcp:" + server]), _ => true);
    await File.WriteAllTextAsync(Path.Combine(folder, first.Id.ToString("N") + ".json"), JsonSerializer.Serialize(new { callerId = firstId, name = "Audit app A", token = first.Token }));
    await File.WriteAllTextAsync(Path.Combine(folder, other.Id.ToString("N") + ".json"), JsonSerializer.Serialize(new { callerId = otherId, name = "Audit app B", token = other.Token }));
    try
    {
      await settingsPanel!.SelectAsync("outside-ai-apps");
      check("App keys display their saved names", SettingsTree(settings).OfType<TextBlock>().Any(t => t.Text == "Audit app A") && SettingsTree(settings).OfType<TextBlock>().Any(t => t.Text == "Audit app B"));
      var card = CallerCard("Audit app A"); InvokeW12(card, "App key actions"); await Task.Delay(100);
      var item = VisualTreeHelper.GetOpenPopupsForXamlRoot(settings.XamlRoot).SelectMany(p => SettingsTree(p.Child)).OfType<MenuFlyoutItem>().Single(m => m.Text == "Rename…");
      if (FrameworkElementAutomationPeer.CreatePeerForElement(item)?.GetPattern(PatternInterface.Invoke) is not IInvokeProvider rename) throw new InvalidOperationException("Rename menu is not invokable.");
      rename.Invoke(); await Task.Delay(100);
      var dialog = CallerDialog(); SettingsTree(dialog).OfType<TextBox>().Single().Text = "Audit renamed app";
      InvokeW12(dialog, "Save"); await Task.Delay(150);
      check("Renaming an app key keeps its existing credential", new CallerConnectionFiles(dataRoot).Names([firstId])[firstId] == "Audit renamed app" && Runtime.Door.Authenticate(first.Token) == first.Id);
      await Runtime.Door.CallAsync(first.Id, "mcp.callers", JsonSerializer.SerializeToElement(new { action = "rename", name = "Audit MCP name" }));
      var listed = await Runtime.Door.CallAsync(first.Id, "mcp.callers", JsonSerializer.SerializeToElement(new { action = "list" }));
      check("App-key name reads and rename work through the real MCP door without returning the token", listed.GetArrayLength() == 1 && listed[0].GetProperty("Name").GetString() == "Audit MCP name" && !listed.GetRawText().Contains(first.Token, StringComparison.Ordinal));
      var refused = false;
      try { await Runtime.Door.CallAsync(other.Id, "mcp.callers", JsonSerializer.SerializeToElement(new { action = "rename", callerId = firstId, name = "Wrong app" })); }
      catch (McpRefusal) { refused = true; }
      check("An app cannot rename another app's key", refused && new CallerConnectionFiles(dataRoot).Names([firstId])[firstId] == "Audit MCP name");
      await settingsPanel.SelectAsync("outside-ai-apps");
      await CaptureSettingsAsync(settingsWindowRoot!, Path.Combine(output, "outside-app-keys-dark.png"));
      card = CallerCard("Audit MCP name"); InvokeW12(card, "Revoke…"); await Task.Delay(100); dialog = CallerDialog();
      check("Revoke names the selected app and warns that its key stops immediately", SettingsTree(dialog).OfType<TextBlock>().Any(t => t.Text.Contains("Audit MCP name", StringComparison.Ordinal) && t.Text.Contains("immediately", StringComparison.Ordinal)));
      await CaptureSettingsAsync(dialog, Path.Combine(output, "app-key-revoke-dark.png"));
      InvokeW12(dialog, "Keep it"); await Task.Delay(100);
      check("Keep it preserves the selected key", Runtime.Door.Authenticate(first.Token) == first.Id);
      InvokeW12(CallerCard("Audit MCP name"), "Revoke…"); await Task.Delay(100); InvokeW12(CallerDialog(), "Revoke"); await Task.Delay(150);
      var stopped = false; try { Runtime.Door.Authenticate(first.Token); } catch (McpRefusal) { stopped = true; }
      check("Confirmed revoke invalidates only the selected credential", stopped && Runtime.Door.Authenticate(other.Token) == other.Id);
    }
    finally { Runtime.RevokeCaller(firstId); Runtime.RevokeCaller(otherId); }
  }
  private ContentDialog CallerDialog() => VisualTreeHelper.GetOpenPopupsForXamlRoot(settings.XamlRoot).SelectMany(p => SettingsTree(p.Child)).OfType<ContentDialog>().Single();
  private Border CallerCard(string title) => SettingsTree(settings).OfType<Border>().First(b => b.Child is Grid row && row.Children.OfType<StackPanel>().Any(p => p.Children.OfType<TextBlock>().Any(t => t.Text == title)));
}
