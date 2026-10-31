using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views;

public sealed partial class SettingsPane
{
  private static string CallerTag(string id) => id.Length > 8 ? id[^8..] : id;
  private CallerConnectionFiles CallerFiles => new(runtime.Root);
  private string? callerNotice;
  private async Task AddCallerRowsAsync(StackPanel stack, CancellationToken ct)
  {
    IReadOnlyList<McpCallerPolicy> callers = runtime.CallerAuthority.List().Where(c => c.CallerId.StartsWith("ai:", StringComparison.Ordinal)).ToArray();
    if (callerNotice is not null) stack.Children.Add(Description(callerNotice));
    var loading = Description("Reading the keys…"); stack.Children.Add(loading);
    IReadOnlyDictionary<string, string> names;
    try { names = await Task.Run(() => CallerFiles.Names(callers.Select(c => c.CallerId))).WaitAsync(ct); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
    { stack.Children.Remove(loading); stack.Children.Add(Card("Couldn’t read app keys", "Saved keys and permissions have been kept.", "Try Again", RenderAsync)); return; }
    stack.Children.Remove(loading);
    if (callers.Count == 0) stack.Children.Add(Description("No app keys yet"));
    foreach (var caller in callers)
    {
      var label = names[caller.CallerId];
      var card = Card(label, "Conversation " + (model.Sessions.FirstOrDefault(s => s.Id == caller.SessionId)?.Title ?? caller.SessionId ?? "Not assigned") + " · " + caller.Mode + (caller.Relay ? " · relay" : " · local") + " · Connection " + CallerTag(caller.CallerId), "Revoke…", () => RevokeCallerAsync(caller.CallerId));
      var menu = new MenuFlyout();
      var rename = new MenuFlyoutItem { Text = "Rename…" }; rename.Click += async (_, _) => await RenameCallerAsync(caller.CallerId); menu.Items.Add(rename);
      AddCardMenu(card, menu, "App key actions"); stack.Children.Add(card);
    }
  }
  private async Task RenameCallerAsync(string id)
  {
    var name = new TextBox { Header = "App name", MaxLength = 80, Text = CallerFiles.Names([id])[id] };
    var note = Description("Only this app’s label changes. Its key, conversation and permissions stay the same.");
    var body = new StackPanel { Spacing = 12 }; body.Children.Add(name); body.Children.Add(note);
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Rename app key", Content = body, PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
    name.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(name.Text);
    dialog.PrimaryButtonClick += (_, args) =>
    {
      try
      {
        if (!runtime.CallerAuthority.List().Any(c => c.CallerId == id)) throw new McpRefusal("This connection is no longer current. Reconnect the app first.");
        CallerFiles.Rename(id, name.Text);
      }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or McpRefusal)
      { args.Cancel = true; note.Text = ex is McpRefusal ? ex.Message : "The app name could not be saved. Try again."; }
    };
    if (await dialog.ShowAsync() == ContentDialogResult.Primary) await RenderAsync();
  }
  private async Task RevokeCallerAsync(string id)
  {
    var name = CallerFiles.Names([id])[id];
    var note = Description("Revoke “" + name + "” (connection " + CallerTag(id) + ")? This key stops working immediately. Other app keys stay connected. This app will need a new key to reconnect.");
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Revoke app key", Content = note, PrimaryButtonText = "Revoke", CloseButtonText = "Keep it", DefaultButton = ContentDialogButton.Close };
    dialog.PrimaryButtonClick += (_, args) =>
    {
      try { runtime.RevokeCaller(id); }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.Json.JsonException)
      {
        if (runtime.CallerAuthority.IsCurrent(id)) { args.Cancel = true; note.Text = "This key could not be revoked. It is still connected. Try again."; }
        else callerNotice = "The key was revoked. A private connection file could not be removed.";
      }
    };
    if (await dialog.ShowAsync() == ContentDialogResult.Primary) await RenderAsync();
  }
}
