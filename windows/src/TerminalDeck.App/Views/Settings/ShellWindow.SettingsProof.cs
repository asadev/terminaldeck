using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Mcp;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  // Opt-in proof runs only in this lane's private scratch tree, never the working app.
  private void InitializeSettingsProof()
  {
    var output = Environment.GetEnvironmentVariable("TD_SETTINGS_PROOF");
    if (output is null || !dataRoot.DirectoryPath.StartsWith(@"C:\TD-SettingsProof\", StringComparison.OrdinalIgnoreCase) ||
        !Path.GetFullPath(output).StartsWith(dataRoot.DirectoryPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return;
    AppWindow.Move(new Windows.Graphics.PointInt32(-20000, -20000));
    Root.Loaded += async (_, _) =>
    {
      var passed = new List<string>(); var failed = new List<string>();
      void Check(string name, bool condition) => (condition ? passed : failed).Add(name);
      Directory.CreateDirectory(output);
      try
      {
        AppWindow.Move(new Windows.Graphics.PointInt32(-20000, -20000));
        await Ready.WaitAsync(TimeSpan.FromSeconds(25));
        using var proofPhone = TerminalDeck.Core.Remote.NoiseIdentity.Generate();
        var pendingPhone = Runtime.Remote.Trust.Redeem(Runtime.Remote.Trust.Pairing.Create().Code, "Audit phone", "android", proofPhone.PublicKey);
        Runtime.ApprovePhone(pendingPhone.DeviceId);
        Check("Remote approval keeps the new device Full default", Runtime.Remote.Trust.List().Single(d => d.Id == pendingPhone.DeviceId).Access == TerminalDeck.Core.Remote.PhoneAccess.Full);
        await Runtime.Mcp.AddAsync(new() { Name = "audit-server", Scope = "user", Transport = "http", Url = "https://example.invalid/mcp" });
        Runtime.Agents.Save(new("w12-audit-coder", "Audit coder", "codex", Model: "fixture-model", Effort: "high", Seat: "review"));
        Model.Page = ShellPage.Settings;
        await Task.Delay(300);
        Check("Settings opens directly in its native window", settingsWindow is not null && settingsPanel?.Parent == settingsWindowRoot);
        Check("Settings has a native draggable title bar", settingsWindow?.ExtendsContentIntoTitleBar == true);
        Check("Only working Windows categories appear in Mac order", SettingsNavigation.Categories.Select(c => c.Id).SequenceEqual(new[] { "general", "appearance", "notifications", "coding-ais", "outside-ai-apps", "agent-defaults", "browser", "tasks", "advanced", "about" }));
        foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
        {
          SaveSettingsTheme(theme);
          foreach (var route in new[] { "appearance", "coding-ais", "accounts", "devices", "mcp", "about" })
          {
            await settingsPanel!.SelectAsync(route);
            await CaptureSettingsAsync(settingsWindowRoot!, Path.Combine(output, route + "-" + theme.ToString().ToLowerInvariant() + ".png"));
            if (route is "coding-ais" or "accounts")
            {
              var accountScroll = settings.Children.OfType<ScrollViewer>().Single(); accountScroll.ChangeView(null, accountScroll.ScrollableHeight, null);
              await CaptureSettingsAsync(settingsWindowRoot!, Path.Combine(output, route + "-bottom-" + theme.ToString().ToLowerInvariant() + ".png"));
              accountScroll.ChangeView(null, 0, null);
            }
            Check(theme + " / " + route + " renders", settingsPanel.ActualWidth > 600 && settingsPanel.SelectedCategory == SettingsNavigation.Canonical(route));
            if (route == "accounts") Check(theme + " saved model and effort remain read-only with one owning Agents link", SettingsTree(settings).OfType<TextBlock>().Any(t => t.Text.Contains("fixture-model", StringComparison.Ordinal) && t.Text.Contains("high", StringComparison.Ordinal)) && SettingsTree(settings).OfType<Button>().Any(b => b.Content as string == "Change in Agents…"));
          }
        }
        await VerifyW12AccountReadStatesAsync(output, Check);
        settingsPanel!.Search("pairing");
        Check("Search filters categories", SettingsNavigation.Matching(settingsPanel.SearchQuery).Single().Id == "advanced");
        settingsPanel.Search("zz-no-match");
        Check("Search has a real empty result", !SettingsNavigation.Matching(settingsPanel.SearchQuery).Any());
        await CaptureSettingsAsync(settingsWindowRoot!, Path.Combine(output, "search-empty-dark.png"));
        settingsPanel.Search("");
        await settingsPanel.SelectAsync("accounts");
        var existingWindow = settingsWindow; ShowSettingsPanel(); await Task.Delay(300);
        Check("Reopen focuses the same window and retains Who uses what", existingWindow == settingsWindow && settingsPanel.Parent == settingsWindowRoot && settingsWindow?.ExtendsContentIntoTitleBar == true && settings.SelectedSection == "Who uses what");
        await CaptureSettingsAsync(settingsPanel, Path.Combine(output, "own-window-dark.png"));
        CloseSettingsPanel(); await Task.Delay(200);
        Check("Close releases the separate window", settingsWindow is null && Model.Page != ShellPage.Settings);
        Model.Page = ShellPage.Settings; await settingsPanel.SelectAsync("appearance");
        settingsWindow!.AppWindow.Resize(new Windows.Graphics.SizeInt32(820, 650));
        await CaptureSettingsAsync(settingsWindowRoot!, Path.Combine(output, "narrow-dark.png"));
        Check("Content fits a smaller Settings window", settingsPanel!.ActualWidth <= 820 && settingsPanel.ActualHeight <= 650);
        var shortcuts = settingsPanel.ShowShortcutsAsync(); await Task.Delay(200);
        var dialog = SettingsTree(settingsPanel.XamlRoot.Content).OfType<ContentDialog>().FirstOrDefault();
        // ContentDialog is hosted in a popup, outside the ordinary content tree.
        dialog ??= VisualTreeHelper.GetOpenPopupsForXamlRoot(settingsPanel.XamlRoot).SelectMany(p => SettingsTree(p.Child)).OfType<ContentDialog>().FirstOrDefault();
        Check("Shortcuts opens its dialog", dialog is not null);
        dialog?.Hide(); await shortcuts.WaitAsync(TimeSpan.FromSeconds(5));
        Model.Page = ShellPage.Projects;
        Check("Main-window navigation leaves Settings in its own window", settingsWindow is not null);
        Check("Theme persisted in the private data root", settingsAppearance!.Load()?.Theme == "dark");
        await VerifyW12CallersAsync(output, Check);
        await VerifyW12McpAddAsync(output, Check);
        await VerifyW12PairingAsync(output, Check);
        await VerifyW12McpEditorAsync(output, Check);
        var permissions = new SettingsProofPermissions();
        var door = new McpDoor(permissions);
        door.Compose("ui.workspace", SettingsPanelTool);
        door.Compose("remote.manage", DeviceManagementTool);
        door.Register("mcp.open", OpenMcpServerTool);
        var caller = door.RegisterCaller(new("settings-proof", null, null, true, AiPermissionMode.Ask,
          ["ui.workspace", "remote.manage", "mcp.open"], Enum.GetValues<McpTier>(), ["*"], DateTimeOffset.UtcNow.AddMinutes(2), true),
          (_, _, _, _, _) => ValueTask.FromResult(true));
        try
        {
          var state = await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { }));
          Check("MCP reads state and categories without approval", permissions.Approvals == 0 && state.GetProperty("settingsCategories").GetArrayLength() == 10);
          state = await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { settingsSection = "appearance", settingsPresentation = "window", settingsSearch = "theme" }));
          Check("MCP navigation and search use existing approval", permissions.Approvals == 1 && state.GetProperty("settings").GetString() == "appearance" && state.GetProperty("settingsPresentation").GetString() == "window" && state.GetProperty("settingsMatches").GetArrayLength() == 1);
          state = await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { settingsPresentation = "closed" }));
          Check("MCP closes Settings", state.GetProperty("settingsPresentation").GetString() == "closed");
          var beforeDeviceActions = permissions.Approvals;
          using var pendingKey = TerminalDeck.Core.Remote.NoiseIdentity.Generate();
          var pending = Runtime.Remote.Trust.Redeem(Runtime.Remote.Trust.Pairing.Create().Code, "MCP audit device", "android", pendingKey.PublicKey);
          await door.CallAsync(caller.Id, "remote.manage", JsonSerializer.SerializeToElement(new { @do = "rename", deviceId = pending.DeviceId, name = "Renamed audit device" }));
          Check("Device rename is available through the MCP door", Runtime.Remote.Trust.Pending().Any(d => d.Id == pending.DeviceId && d.Name == "Renamed audit device"));
          var denied = await door.CallAsync(caller.Id, "remote.manage", JsonSerializer.SerializeToElement(new { @do = "deny", deviceId = pending.DeviceId }));
          Check("MCP pending denial uses approval and preserves other devices", denied.GetProperty("denied").GetBoolean() && permissions.Approvals == beforeDeviceActions + 2 && Runtime.Remote.Trust.List().Count >= 1);
          var serverId = (await Runtime.Mcp.ListAsync()).First().Id;
          var opened = await door.CallAsync(caller.Id, "mcp.open", JsonSerializer.SerializeToElement(new { serverId, section = "log" }));
          checkMcpOpened(opened);
          opened = await door.CallAsync(caller.Id, "mcp.open", JsonSerializer.SerializeToElement(new { serverId, section = "general" }));
          Check("MCP reuses the one server editor", opened.GetProperty("editorCount").GetInt32() == 1);
          var scoped = door.RegisterCaller(new("scoped-editor-proof", null, null, true, AiPermissionMode.Ask,
            ["mcp.open"], Enum.GetValues<McpTier>(), ["settings:workspace", "mcp:user:other"], DateTimeOffset.UtcNow.AddMinutes(1), true), (_, _, _, _, _) => ValueTask.FromResult(true));
          try
          {
            var refused = false;
            try { await door.CallAsync(scoped.Id, "mcp.open", JsonSerializer.SerializeToElement(new { serverId })); }
            catch (McpRefusal) { refused = true; }
            Check("MCP editor refuses a server outside the caller grant", refused && settings.OpenServerEditorCount == 1);
          }
          finally { door.Revoke(scoped.Id); }

          void checkMcpOpened(JsonElement value) => Check("MCP opens the server's own editor and selected tab", value.GetProperty("opened").GetBoolean() && value.GetProperty("section").GetString() == "log");


        }
        finally { door.Revoke(caller.Id); }
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { failed.Add(ex.ToString()); }
      await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, passed = passed.Count, failed = failed.Count, checksPassed = passed, checksFailed = failed }));
      Close();
    };
  }

  private sealed class SettingsProofPermissions : IMcpPermissionBroker
  {
    public int Approvals { get; private set; }
    public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest request, CancellationToken cancellationToken)
    {
      Approvals++;
      return ValueTask.FromResult(new McpPermissionProof(Guid.NewGuid(), request.CallerId, request.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), true));
    }
  }

  private static IEnumerable<DependencyObject> SettingsTree(DependencyObject node)
  {
    yield return node;
    for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
      foreach (var child in SettingsTree(VisualTreeHelper.GetChild(node, i))) yield return child;
  }

  private static async Task CaptureSettingsAsync(FrameworkElement target, string path)
  {
    await Task.Delay(250);
    var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(target);
    var buffer = await bitmap.GetPixelsAsync(); var pixels = new byte[buffer.Length];
    using (var reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(pixels);
    using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels);
    await encoder.FlushAsync();
    using var output = new DataReader(stream.GetInputStreamAt(0)); await output.LoadAsync((uint)stream.Size);
    var bytes = new byte[checked((int)stream.Size)]; output.ReadBytes(bytes); await File.WriteAllBytesAsync(path, bytes);
  }
}
