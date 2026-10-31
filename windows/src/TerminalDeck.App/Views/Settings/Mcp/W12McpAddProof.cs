using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task VerifyW12McpAddAsync(string output, Action<string, bool> check)
  {
    await settingsPanel!.SelectAsync("mcp"); InvokeW12(settingsPanel, "Add server"); await Task.Delay(150);
    var dialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(settings.XamlRoot).SelectMany(p => SettingsTree(p.Child)).OfType<ContentDialog>().Single();
    var scope = SettingsTree(dialog).OfType<ComboBox>().Single(c => c.Header as string == "Save for");
    check("New server scope exposes only functional global and private-project choices", scope.Items.Count == 2 && !scope.Items.Cast<string>().Any(s => s.Contains("Shared", StringComparison.Ordinal)));
    scope.SelectedIndex = 1; await Task.Delay(50);
    check("Missing project is information with Save disabled", !dialog.IsPrimaryButtonEnabled && SettingsTree(dialog).OfType<TextBlock>().Any(t => t.Text == "Add a project before saving a project server."));
    scope.SelectedIndex = 0;
    var name = SettingsTree(dialog).OfType<TextBox>().Single(t => t.Header as string == "Name"); name.Text = "ui-header-server";
    var address = SettingsTree(dialog).OfType<TextBox>().Single(t => t.Header as string == "Web address"); address.Text = "https://example.invalid/mcp";
    var headers = SettingsTree(dialog).OfType<McpSecretFields>().Single(f => f.Visibility == Microsoft.UI.Xaml.Visibility.Visible);
    InvokeW12(headers, "Add value"); await Task.Delay(50);
    SettingsTree(headers).OfType<TextBox>().Single().Text = "Authorization";
    var password = SettingsTree(headers).OfType<PasswordBox>().Single(); password.Password = "synthetic-ui-header";
    check("Header input stays masked", password.PasswordRevealMode != PasswordRevealMode.Visible);
    await CaptureSettingsAsync(dialog, Path.Combine(output, "mcp-add-headers-dark.png"));
    var formScroll = SettingsTree(dialog).OfType<ScrollViewer>().Single(s => s.Content is StackPanel panel && panel.Children.OfType<McpSecretFields>().Any()); formScroll.ChangeView(null, formScroll.ScrollableHeight, null); await Task.Delay(100);
    await CaptureSettingsAsync(dialog, Path.Combine(output, "mcp-add-headers-bottom-dark.png"));
    try
    {
    InvokeW12(dialog, "Save"); await Task.Delay(200);
    var server = (await Runtime.Mcp.ListAsync()).Single(s => s.Name == "ui-header-server");
    var config = (new TerminalDeck.Core.Storage.JsonStateStore<TerminalDeck.Core.Mcp.McpManagerState>(dataRoot, "mcp")).Load()!.Servers.Single(s => s.Id == server.Id);
    var reference = config.HeaderReferences["Authorization"];
    check("Add server writes a protected header and never reads its value back", (await Runtime.Mcp.SettingsAsync(server.Id)).HeaderNames.Contains("Authorization") && !(await Runtime.Mcp.ExportAsync(server.Id)).GetRawText().Contains("synthetic-ui-header", StringComparison.Ordinal));
    await Runtime.Mcp.RemoveAsync(server.Id);
    check("Removing this test server clears only its protected header", await new WindowsCredentialStore(dataRoot).ReadAsync(reference) is null && (await Runtime.Mcp.ListAsync()).Any(s => s.Name == "audit-server"));
    }
    finally
    {
      foreach (var leftover in (await Runtime.Mcp.ListAsync()).Where(s => s.Name == "ui-header-server")) await Runtime.Mcp.RemoveAsync(leftover.Id);
    }
  }
}
