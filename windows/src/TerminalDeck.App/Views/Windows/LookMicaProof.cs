using System.Text.Json;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task RunLookMicaProofAsync()
  {
    var output = Environment.GetEnvironmentVariable("TD_LOOK_MICA_PROOF")!;
    if (!dataRoot.DirectoryPath.StartsWith(@"C:\TD-LookMicaProof\", StringComparison.OrdinalIgnoreCase) ||
      !File.Exists(Path.Combine(dataRoot.DirectoryPath, ".look-mica-allow")) ||
      !Path.GetFullPath(output).StartsWith(dataRoot.DirectoryPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
      throw new InvalidOperationException("Mica proof requires its marked scratch root.");
    var passed = new List<string>(); var failed = new List<string>();
    void Check(string name, bool ok) => (ok ? passed : failed).Add(name);
    async Task Frame(string name, Window window)
    {
      await Task.Delay(450);
      var request = Path.Combine(output, name + ".request");
      File.WriteAllText(request + ".tmp", JsonSerializer.Serialize(new { handle = WinRT.Interop.WindowNative.GetWindowHandle(window).ToInt64(), pid = Environment.ProcessId,
        bounds = new { x = window.AppWindow.Position.X, y = window.AppWindow.Position.Y, width = window.AppWindow.Size.Width, height = window.AppWindow.Size.Height },
        scale = (window.Content as FrameworkElement)?.XamlRoot?.RasterizationScale ?? 1 }));
      File.Move(request + ".tmp", request, true);
      var until = DateTime.UtcNow.AddSeconds(35);
      while (!File.Exists(Path.Combine(output, name + ".captured")))
      { if (DateTime.UtcNow > until) throw new TimeoutException("Desktop capture: " + name); await Task.Delay(100); }
    }
    try
    {
      await Ready;
      var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
      if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.Restore();
      AppWindow.MoveAndResize(new(area.X + 40, area.Y + 32, Math.Min(1440, area.Width - 120), Math.Min(900, area.Height - 100)));
      var folder = Path.Combine(dataRoot.DirectoryPath, "review-project"); Directory.CreateDirectory(folder);
      var project = Runtime.Projects.Create("Windows appearance", folder);
      for (var i = 0; i < 3; i++)
      {
        var row = Model.AddDraft("codex", folder, SessionPresentation.Terminal);
        row.Rename(new[] { "Window materials", "Tab geometry", "Review colours" }[i]);
        row.SetAppearance(project.Name, null, "Independent", project.Id);
      }
      var shell = Model.AddDraft("shell", folder, SessionPresentation.Terminal);
      shell.Rename("Review PowerShell");
      UpdateSidebarSessions(); RefreshProjectRows();
      foreach (var page in new[] { ShellPage.Projects, ShellPage.Tasks, ShellPage.Agents })
        windowState.Ensure("page:" + page, "pages", page.ToString(), "page", page.ToString());
      var task = Runtime.Tasks.Create(new("Review Windows appearance", "A synthetic task for the material review. No agent is started.", project.Id, folder), TaskActor.Owner);
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        var suffix = theme.ToString().ToLowerInvariant();
        SaveSettingsTheme(theme); Model.Notice = ""; workspaceOwner = "pages"; Model.Page = ShellPage.Projects; windowState.Select("page:Projects"); RenderWindows();
        await Frame("main-" + suffix, this);
        Model.Select(shell); SelectSessionWindow(shell); Model.Notice = ""; RenderWindows();
        await Frame("session-" + suffix, this);
        var headerTitle = ProofTree(Workspace).OfType<TextBlock>().Single(t => t.Text == "Review PowerShell" && t.ActualHeight > 0);
        Check(suffix + " shell heading is plain text", headerTitle.FontWeight.Equals(Microsoft.UI.Text.FontWeights.SemiBold) && !ProofTree(Workspace).OfType<TextBox>().Any(t => t.Text == shell.Title));
        Check(suffix + " shell has no account chip", WindowAccountLabel(windowState.Get(shell.Id)) == "");
        Check(suffix + " no global sign-in or Recovery banner", !Status.IsOpen && Status.Visibility == Visibility.Collapsed && Status.ActionButton is null);
        var ai = Model.Sessions.First(row => row.Provider == "codex");
        Model.Select(ai); SelectSessionWindow(ai); Model.Notice = ""; RenderWindows();
        await Frame("session-ai-" + suffix, this);
        Check(suffix + " signed-out AI identity stays in the account chip", WindowAccountLabel(windowState.Get(ai.Id)) == "Not signed in" && !Status.IsOpen);
        var accountView = ShowAccountAsync(ai); await Frame("accounts-" + suffix, this);
        Check(suffix + " account sheet has a management destination", accountSheet?.Title as string == "Switch account" && ProofTree(accountSheet).OfType<Button>().Any(button => button.Content as string == "Manage accounts…"));
        accountSheet?.Hide(); await accountView;
        workspaceOwner = "pages"; Model.Page = ShellPage.Projects; windowState.Select("page:Projects"); RenderWindows();
        Root.UpdateLayout();
        Check(suffix + " window has Mica", SystemBackdrop is MicaBackdrop);
        var cardTop = ContentCard.TransformToVisual(Root).TransformPoint(new(0, 0)).Y;
        Check(suffix + " content meets tab row", Math.Abs(cardTop - TitleBarRow.ActualHeight) < 0.5);
        var activeShapes = ProofTree(WorkspaceHeader).OfType<Microsoft.UI.Xaml.Shapes.Path>().Where(p => p.Visibility == Visibility.Visible && p.Data is PathGeometry).ToArray();
        Check(suffix + " one selected tab shape shares content fill", activeShapes.Length == 1 && ReferenceEquals(activeShapes[0].Fill, ContentCard.Background));
        Check(suffix + " primary ink meets AA on content", Contrast("DeckInkBrush", "DeckCanvasBrush") >= 4.5);
        Check(suffix + " secondary tab ink meets AA on solid chrome", Contrast("DeckSecondaryInkBrush", "DeckTopBarBrush") >= 4.5);
        Check(suffix + " blue selection keeps white text AA", Contrast("DeckSidebarSelectionInkBrush", "DeckSidebarSelectionBrush") >= 4.5);
        MorePages_Click(MorePages, new()); await Frame("menu-" + suffix, this);
        var shortcutButton = ProofTree((FrameworkElement)morePagesFlyout!.Content).OfType<Button>().Single(b => b.Content as string == "Keyboard Shortcuts  ·  Ctrl+/");
        ((IInvokeProvider)new ButtonAutomationPeer(shortcutButton).GetPattern(PatternInterface.Invoke)).Invoke(); await Task.Delay(250);
        var shortcuts = VisualTreeHelper.GetOpenPopupsForXamlRoot(Root.XamlRoot).SelectMany(p => ProofTree(p.Child)).OfType<ContentDialog>().FirstOrDefault();
        Check(suffix + " More opens keyboard shortcuts", shortcuts is not null && shortcuts.Title as string == "Keyboard Shortcuts" && ProofTree(shortcuts).OfType<TextBlock>().Any(text => text.Text.Contains("Ctrl+F   Search Settings", StringComparison.Ordinal))); shortcuts?.Hide();
        Check(suffix + " Ctrl+/ registered", Root.KeyboardAccelerators.Any(k => (int)k.Key == 191 && k.Modifiers == Windows.System.VirtualKeyModifiers.Control));
        Check(suffix + " menu uses Acrylic", ShellTheme.Resource(Root, "DeckGlassBrush") is AcrylicBrush);
        await OpenSettingsAsync("general"); await Task.Delay(250);
        Check(suffix + " Settings has Mica", settingsWindow?.SystemBackdrop is MicaBackdrop);
        Check(suffix + " no Settings footer", !ProofTree(settingsPanel!).OfType<TextBlock>().Any(t => t.Text == "Changes save as you make them.") && !ProofTree(settingsPanel!).OfType<Button>().Any(b => b.Content as string == "Shortcuts"));
        await Frame("settings-" + suffix, settingsWindow!);
        WindowMaterials.PaintChrome(settingsWindowRoot!, null, false); await Frame("settings-fallback-" + suffix, settingsWindow!);
        CloseSettingsPanel();
        WindowMaterials.PaintChrome(Root, TitleBarRow, false); await Frame("main-fallback-" + suffix, this);
        Check(suffix + " fallback paints sidebar and title separately", ReferenceEquals(Root.Background, ShellTheme.Resource(Root, "DeckRailBrush")) && ReferenceEquals(TitleBarRow.Background, ShellTheme.Resource(Root, "DeckTopBarBrush")));
        WindowMaterials.PaintChrome(Root, TitleBarRow, true);
        Model.Page = ShellPage.Tasks; windowState.Select("page:Tasks"); RenderWindows(); await Task.Delay(200); tasksPage!.OpenTask(task.Id);
        await Frame("task-" + suffix, this);
        var taskOverlay = ProofTree(tasksPage).OfType<Grid>().Single(grid => AutomationProperties.GetAutomationId(grid) == "tasks.popup");
        Check(suffix + " task popup uses Acrylic", taskOverlay.Children.OfType<Border>().Single().Background is AcrylicBrush);
        tasksPage.Model.Select(null);
      }
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { failed.Add(ex.ToString()); }
    finally
    {
      File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { passed, failed, at = DateTimeOffset.UtcNow, desktopFrames = 18, simulatedFallback = true,
        micaSupported = Microsoft.UI.Composition.SystemBackdrops.MicaController.IsSupported(),
        transparencyEnabled = new Windows.UI.ViewManagement.UISettings().AdvancedEffectsEnabled,
        highContrast = new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast }));
      CloseSettingsPanel(); Close();
    }
    double Contrast(string foreground, string background)
    {
      double L(string key)
      {
        var c = ((SolidColorBrush)ShellTheme.Resource(Root, key)).Color;
        double Channel(byte v) { var n = v / 255d; return n <= 0.04045 ? n / 12.92 : Math.Pow((n + 0.055) / 1.055, 2.4); }
        return 0.2126 * Channel(c.R) + 0.7152 * Channel(c.G) + 0.0722 * Channel(c.B);
      }
      var a = L(foreground); var b = L(background); return (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05);
    }
  }
}
