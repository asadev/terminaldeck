using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Mcp;
using TerminalDeck.App.Views.Settings;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  [DllImport("user32.dll")] private static extern nint GetWindow(nint window, uint command);
  [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
  private void InitializeSettingsWindowProof()
  {
    var mode = Environment.GetEnvironmentVariable("TD_SETTINGS_WINDOW_PROOF");
    if (mode is null) return;
    if (mode is not ("first" or "restart") || !dataRoot.DirectoryPath.StartsWith(@"C:\TD-SettingsWindowProof\", StringComparison.OrdinalIgnoreCase) ||
      !File.Exists(Path.Combine(dataRoot.DirectoryPath, ".settings-window-allow"))) throw new InvalidOperationException("Settings window proof requires its marked scratch root.");
    Root.Loaded += async (_, _) => await RunSettingsWindowProofAsync(mode);
  }
  private async Task RunSettingsWindowProofAsync(string mode)
  {
    var output = Path.Combine(dataRoot.DirectoryPath, "proof"); Directory.CreateDirectory(output);
    var passed = new List<string>(); var failed = new List<string>();
    void Check(string label, bool ok) => (ok ? passed : failed).Add(label);
    async Task Frame(string name)
    {
      await Task.Delay(350);
      var request = Path.Combine(output, name + ".request");
      File.WriteAllText(request + ".tmp", JsonSerializer.Serialize(new { handle = (settingsWindow is null ? WindowHandle : WinRT.Interop.WindowNative.GetWindowHandle(settingsWindow)).ToInt64(), pid = Environment.ProcessId }));
      File.Move(request + ".tmp", request, true);
      var until = DateTime.UtcNow.AddSeconds(30);
      while (!File.Exists(Path.Combine(output, name + ".captured")))
      { if (DateTime.UtcNow > until) throw new TimeoutException("Desktop capture: " + name); await Task.Delay(100); }
    }
    try
    {
      await Ready;
      var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
      if (AppWindow.Presenter is OverlappedPresenter main) main.Restore();
      AppWindow.MoveAndResize(new(area.X + 16, area.Y + 16, area.Width - 32, area.Height - 32));
      SaveSettingsTheme(ElementTheme.Light);
      var saved = settingsBounds;
      await Frame(mode + "-ctrl-comma"); await Task.Delay(450);
      Check("Ctrl+, opens Settings", settingsWindow is not null);
      var window = settingsWindow!; var handle = WinRT.Interop.WindowNative.GetWindowHandle(window);
      Check("Separate owned top-level HWND", handle != WindowHandle && GetWindow(handle, 4) == WindowHandle);
      Check("Native custom title bar", window.ExtendsContentIntoTitleBar);
      Check("Resizable with minimize and no maximize", window.AppWindow.Presenter is OverlappedPresenter { IsResizable: true, IsMinimizable: true, IsMaximizable: false, PreferredMinimumWidth: >= 680, PreferredMinimumHeight: >= 440 });
      Check("Settings is absent from main visual tree", !ProofTree(Root).Contains(settingsPanel!));
      if (mode == "restart")
      {
        Check("Position and size survive app restart", saved is not null && saved.X == window.AppWindow.Position.X && saved.Y == window.AppWindow.Position.Y && saved.Width == window.AppWindow.Size.Width && saved.Height == window.AppWindow.Size.Height);
        await Frame("restart-remembered-light");
      }
      else
      {
        Check("First opening is large beside sidebar below toolbar", window.AppWindow.Position.X >= AppWindow.Position.X + SidebarColumn.ActualWidth * WindowScale(this) && window.AppWindow.Position.Y >= AppWindow.Position.Y + TitleBarRow.ActualHeight * WindowScale(this) && settingsPanel!.ActualWidth >= 760);
        await Frame("initial-large-light");
        var dragStart = window.AppWindow.Position;
        await Frame("native-drag-light");
        Check("Native title bar drags outside its original position", window.AppWindow.Position.X != dragStart.X || window.AppWindow.Position.Y != dragStart.Y);
        var identity = settingsWindow;
        await RunShellCommandAsync("settings"); await Task.Delay(100);
        Check("Reopen focuses the same HWND", ReferenceEquals(identity, settingsWindow) && GetForegroundWindow() == handle);
        ((OverlappedPresenter)window.AppWindow.Presenter).Minimize(); ShowSettingsPanel();
        Check("Reopen restores minimized Settings", ((OverlappedPresenter)window.AppWindow.Presenter).State == OverlappedPresenterState.Restored);
        OpenCodingAIs(); await Task.Delay(150);
        Check("Account sign-in link opens Coding AIs in the window", settingsPanel!.SelectedCategory == "coding-ais" && settingsWindow == identity);
        foreach (var category in SettingsNavigation.Categories)
        {
          await OpenSettingsAsync(category.Id); await Task.Delay(100);
          Check("Category " + category.Id + " retains its page", settingsPanel!.SelectedCategory == category.Id && settingsWindow == identity);
        }
        var permissions = new SettingsProofPermissions(); var door = new McpDoor(permissions); door.Compose("ui.workspace", SettingsPanelTool);
        var caller = door.RegisterCaller(new("settings-window-proof", null, null, true, AiPermissionMode.Ask, ["ui.workspace"], Enum.GetValues<McpTier>(), ["*"], DateTimeOffset.UtcNow.AddMinutes(5), true), (_, _, _, _, _) => ValueTask.FromResult(true));
        try
        {
          var state = await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { settingsPresentation = "panel", settingsSection = "appearance", settingsSearch = "theme" }));
          Check("Legacy MCP panel route focuses the native window at the category", state.GetProperty("settingsPresentation").GetString() == "window" && settingsWindow == identity && settingsPanel!.SelectedCategory == "appearance" && state.GetProperty("settingsMatches").GetArrayLength() == 1 && permissions.Approvals == 1);
          settingsPanel!.Search("");
          await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { settingsPresentation = "closed" }));
          Check("MCP close releases the window", settingsWindow is null);
          await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { settingsSection = "general" }));
          Check("MCP deep link opens Settings", settingsWindow is not null && settingsPanel.SelectedCategory == "general");
          var moved = await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { settingsBounds = new { x = 40, y = 60, width = 820, height = 620 } }));
          Check("MCP bounds resize the actual AppWindow", Math.Abs(moved.GetProperty("settingsBounds").GetProperty("Width").GetDouble() - 820) < 2 && Math.Abs(settingsWindow!.AppWindow.Size.Width / WindowScale(settingsWindow) - 820) < 2);
        }
        finally { door.Revoke(caller.Id); }
        window = settingsWindow!;
        Check("Settings has no save footer", !ProofTree(settingsPanel!).OfType<TextBlock>().Any(text => text.Text == "Changes save as you make them."));
        var shortcuts = settingsPanel!.ShowShortcutsAsync();
        ContentDialog? dialog = null;
        var dialogDeadline = DateTime.UtcNow.AddSeconds(6);
        while (dialog is null && !shortcuts.IsCompleted && DateTime.UtcNow < dialogDeadline)
        {
          await Task.Delay(50);
          if (settingsPanel.XamlRoot is { } currentRoot)
            dialog = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(currentRoot).SelectMany(p => ProofTree(p.Child)).OfType<ContentDialog>().FirstOrDefault();
        }
        Check("Shortcuts opens in Settings XamlRoot", dialog?.Title as string == "Settings shortcuts"); dialog?.Hide(); await shortcuts.WaitAsync(TimeSpan.FromSeconds(5));
        Check("Footer remains present", ProofTree(settingsPanel).OfType<TextBlock>().Any(t => t.Text == "Changes save as you make them."));
        Check("No pop-out button", !ProofTree(settingsPanel).OfType<Button>().Any(b => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(b).Contains("own window", StringComparison.OrdinalIgnoreCase)));
        var scale = WindowScale(this);
        // Leave actual empty desktop to the right of the smaller main window.
        var settingsWidth = Math.Min(area.Width - 40, Math.Max((int)(700 * scale), (int)(area.Width * 0.46)));
        var mainWidth = area.Width - settingsWidth - 48;
        AppWindow.MoveAndResize(new(area.X + 8, area.Y + 24, mainWidth, Math.Min(area.Height - 48, (int)(700 * scale))));
        window.AppWindow.Resize(new(settingsWidth, Math.Min(area.Height - 60, (int)(800 * scale))));
        foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
        {
          SaveSettingsTheme(theme); await OpenSettingsAsync("general"); await Task.Delay(250);
          Check(theme + " follows live app theme", Root.ActualTheme == theme && settingsPanel.ActualTheme == theme && settingsWindowRoot!.ActualTheme == theme);
          window.AppWindow.Move(new(area.X + mainWidth - 160, area.Y + 50));
          await Frame("partly-outside-" + theme.ToString().ToLowerInvariant());
          window.AppWindow.Move(new(area.X + mainWidth + 32, area.Y + 50));
          Check(theme + " Settings fully outside main window", window.AppWindow.Position.X >= AppWindow.Position.X + AppWindow.Size.Width);
          await Frame("empty-desktop-" + theme.ToString().ToLowerInvariant());
        }
        SaveSettingsWindowBounds(window);
      }
      Check("No hidden UI errors", !File.Exists(Path.Combine(dataRoot.DirectoryPath, "logs", "errors.log")) || new FileInfo(Path.Combine(dataRoot.DirectoryPath, "logs", "errors.log")).Length == 0);
      File.WriteAllText(Path.Combine(output, mode + "-windows.json"), JsonSerializer.Serialize(new { main = WindowHandle.ToInt64(), settings = WinRT.Interop.WindowNative.GetWindowHandle(settingsWindow!).ToInt64(), placement = settingsBounds }));
    }
    catch (Exception ex) { failed.Add(ex.ToString()); }
    finally
    {
      var resultPath = Path.Combine(output, mode + "-result.json");
      File.WriteAllText(resultPath + ".tmp", JsonSerializer.Serialize(new { passed, failed }, new JsonSerializerOptions { WriteIndented = true }));
      File.Move(resultPath + ".tmp", resultPath, true);
      Close();
    }
  }
}
