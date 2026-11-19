using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Mcp;
using Windows.ApplicationModel.DataTransfer;

namespace TerminalDeck.App.Views;

// Settings → AI apps (Mac, 15 Nov). Group 1: "Let AI apps use this PC" and, only while it is on, the
// connection address through Terminal Deck's server with a Copy button (the address itself, and any
// local address, never on the surface). Group 2 "Keys": one row per key (its name, what it may do,
// a "…" menu), "+ New key" last. Last group "WhatsApp": the WhatsApp agents (Views/WhatsApp).
public sealed partial class SettingsPane
{
  private CallerConnectionFiles CallerFiles => new(runtime.Root);
  private string? callerNotice;
  private async Task AddCallerRowsAsync(StackPanel stack, CancellationToken ct)
  {
    if (runtime.Cloud.Snapshot.Subscription.AllowsCloudServices)
    {
      var allow = new ToggleSwitch { IsOn = runtime.RemoteToolsEnabled, OnContent = "", OffContent = "", MinWidth = 40 };
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(allow, "aiApps.allow");
      allow.Toggled += async (_, _) =>
      {
        if (allow.IsOn == runtime.RemoteToolsEnabled) return;
        allow.IsEnabled = false;
        try { await runtime.SetRemoteToolsAsync(allow.IsOn); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { model.Notice = "That could not be changed. Try again."; }
        await RenderAsync();
      };
      var access = new List<FrameworkElement> { Settings.SettingsPanel.SettingRow("Let AI apps use this PC",
        "Lets other AI apps use " + TerminalDeck.Core.Brand.Name + " on this PC from anywhere, through " + TerminalDeck.Core.Brand.Name + "’s server. Each app uses its own key below. Turning this off stops those keys. It turns off when the app closes.", allow) };
      if (runtime.RemoteToolsEnabled && runtime.Remote.McpAddress is { } address)
      {
        var copy = new Button { Content = "Copy" };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(copy, "aiApps.copyAddress");
        copy.Click += (_, _) => { var data = new DataPackage(); data.SetText(address); Clipboard.SetContent(data); copy.Content = "Copied"; };
        access.Add(Settings.SettingsPanel.SettingRow("Connection address", "Paste it into the AI app’s MCP settings together with that app’s key. It works from anywhere.", copy));
      }
      stack.Children.Add(Settings.SettingsPanel.GroupRows(access));
    }

    IReadOnlyList<McpCallerPolicy> callers = runtime.CallerAuthority.List().Where(c => c.CallerId.StartsWith("ai:", StringComparison.Ordinal)).ToArray();
    if (callerNotice is not null) stack.Children.Add(Description(callerNotice));
    var loading = Description("Reading the keys…"); stack.Children.Add(loading);
    IReadOnlyDictionary<string, string> names;
    try { names = await Task.Run(() => CallerFiles.Names(callers.Select(c => c.CallerId))).WaitAsync(ct); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
    { stack.Children.Remove(loading); stack.Children.Add(Card("Couldn’t read app keys", "Saved keys and permissions have been kept.", "Try Again", RenderAsync)); return; }
    stack.Children.Remove(loading);
    var keys = new List<FrameworkElement>();
    foreach (var caller in callers)
    {
      var menu = new MenuFlyout();
      var rename = new MenuFlyoutItem { Text = "Rename…" }; rename.Click += async (_, _) => await RenameCallerAsync(caller.CallerId); menu.Items.Add(rename);
      var revoke = new MenuFlyoutItem { Text = "Revoke…" }; revoke.Click += async (_, _) => await RevokeCallerAsync(caller.CallerId); menu.Items.Add(revoke);
      keys.Add(AiPageRow(names[caller.CallerId], KeyMayDo(caller.Mode), AiPageMenu(menu, "App key actions")));
    }
    keys.Add(AiPageAddRow("New key", "aiApps.newKey", ConnectAiAppAsync));
    stack.Children.Add(AiPageSection("Keys", null, null, Settings.SettingsPanel.GroupRows(keys)));
    // MCP servers: a second page of this window, not a switch at the top (15 Nov).
    if (NavigateSettings is { } navigate)
      stack.Children.Add(Settings.SettingsPanel.GroupRows((FrameworkElement[])[AiPageLinkRow("MCP servers", () => navigate("mcp-servers"))]));
    // WhatsApp agents (15 Nov): the page's LAST group.
    stack.Children.Add(new WhatsApp.WhatsAppSettingsGroup(TerminalDeck.Core.WhatsApp.WhatsAppAgentsStore.Shared, WhatsAppChoices));
  }
  // Where a WhatsApp agent can be received: his saved agents (not archived) under their project, the open sessions by name.
  private WhatsApp.WhatsAppReceiverChoices WhatsAppChoices()
  {
    try
    {
      var projects = runtime.Projects.List().GroupBy(p => p.Id).ToDictionary(g => g.Key, g => g.First().Name);
      var agents = runtime.Agents.List().Where(a => a.Status != TerminalDeck.Core.Agents.SavedAgentStatus.Archived)
        .Select(a => (a.Id, a.Name, a.ProjectId == TerminalDeck.Core.Projects.ProjectIdentity.IndependentId ? "" : projects.GetValueOrDefault(a.ProjectId, "")));
      var sessions = runtime.Sessions.Where(s => s.State != TerminalDeck.Core.Sessions.SessionState.Exited).Select(s => (s.Definition.Id, s.Definition.Title)).ToList();
      if (runtime.Chats is not null) sessions.AddRange(runtime.Chats.List().Where(c => !c.Ended).Select(c => (c.Definition.Id, c.Definition.Title)));
      return WhatsApp.WhatsAppReceiverChoices.From(agents, sessions);
    }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or UnauthorizedAccessException) { return WhatsApp.WhatsAppReceiverChoices.Empty; }
  }
  // What a key may do, in words (its calling AI's permission setting).
  private static string KeyMayDo(AiPermissionMode mode) => mode switch
  {
    AiPermissionMode.Plan => "Look only",
    AiPermissionMode.Ask => "Asks before changes",
    AiPermissionMode.AcceptEdits => "Edits without asking",
    _ => "Full control"
  };
  private async Task RenameCallerAsync(string id)
  {
    var name = new TextBox { Header = "App name", MaxLength = 80, Text = CallerFiles.Names((string[])[id])[id] };
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
    var name = CallerFiles.Names((string[])[id])[id];
    var note = Description("Revoke “" + name + "”? This key stops working immediately. Other app keys stay connected. This app will need a new key to reconnect.");
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
