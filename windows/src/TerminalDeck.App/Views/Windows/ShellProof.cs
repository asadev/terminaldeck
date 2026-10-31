using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  // Explicit scratch-only fixture. It creates no provider process and uses the
  // actual retained controls; the render stays behind the person's review app.
  private async Task RunShellProofIfRequestedAsync()
  {
    var output = Environment.GetEnvironmentVariable("TD_SHELL_PROOF");
    if (output is null || !Path.GetFullPath(output).StartsWith(dataRoot.DirectoryPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return;
    Directory.CreateDirectory(output);
    var passed = new List<string>(); var failed = new List<string>();
    void Check(string label, bool ok) => (ok ? passed : failed).Add(label);
    try
    {
      await Ready;
      ShellProofNative.Behind(this);
      var presenter = (Microsoft.UI.Windowing.OverlappedPresenter)AppWindow.Presenter;
      ShellProofNative.SendMessage(WindowHandle, 0xA3, new(2), 0);
      await Task.Delay(150);
      Check("native caption double-click maximises", presenter.State == Microsoft.UI.Windowing.OverlappedPresenterState.Maximized);
      presenter.Restore();
      var first = Model.AddDraft("codex", dataRoot.DirectoryPath, SessionPresentation.Terminal);
      var second = Model.AddDraft("claude", dataRoot.DirectoryPath, SessionPresentation.Chat);
      first.SetAppearance("Deck Dev", null, "Decker"); second.SetAppearance("ClaudeCRM", null, "Alex");
      SelectSessionWindow(first);
      await WaitForTerminalsAsync().WaitAsync(TimeSpan.FromSeconds(40));
      await CreateWindowAsync(first.Id, "browser");
      var b1 = windowState.Tabs.Last(t => t.Kind == "browser").Id;
      await CreateWindowAsync(first.Id, "browser");
      var b2 = windowState.Tabs.Last(t => t.Kind == "browser").Id;
      windowState.Rename(b1, "B1 · Research"); windowState.Rename(b2, "B2 · Preview");
      windowState.Move(b1, 1);
      Check("two browser windows belong to one session", windowState.Get(b1).Owner == first.Id && windowState.Get(b2).Owner == first.Id);
      SelectSessionWindow(first);
      windowState.Split(first.Id, b1);
      windowState.Split(b1, second.Id, true, first.Id);
      Check("three panes including two sessions and a browser", windowState.Layout(first.Id).Root!.Tabs.Count() == 3);
      windowState.Focus(second.Id, first.Id); FocusWindow(first.Id, second.Id);
      Check("active pane follows focus", windowState.Layout(first.Id).Active == second.Id);
      var caller = Runtime.Door.RegisterCaller(new("shell-proof", null, null, true, TerminalDeck.Core.Mcp.AiPermissionMode.Ask,
        ["windows.list", "windows.pop_out", "ui.workspace"], [TerminalDeck.Core.Mcp.McpTier.Read, TerminalDeck.Core.Mcp.McpTier.Act], ["*"], DateTimeOffset.UtcNow.AddMinutes(5)), (_, _, _, _, _) => ValueTask.FromResult(true));
      var listed = await Runtime.Door.CallAsync(caller.Id, "windows.list", JsonSerializer.SerializeToElement(new { }));
      Check("MCP lists the retained window tabs", listed.GetProperty("tabs").GetArrayLength() >= 5);
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        SetTheme(theme); await Task.Delay(450); Root.UpdateLayout();
        Check(theme + " native title bar uses one 48 DIP row", ExtendsContentIntoTitleBar && TitleBarRow.ActualHeight == 48);
        Check(theme + " caption buttons have reserved room", CaptionSpace.ActualWidth >= 138);
        Check(theme + " tabs are in the title-bar row", WorkspaceHeader.TransformToVisual(Root).TransformPoint(new(0, 0)).Y < 48 && WorkspaceHeader.ActualHeight == 48);
        Check(theme + " three pane frames are visible", ProofTree(mainSurface).OfType<ContentControl>().Count(c => c.Tag as string == "workspace-view" && c.Content is not null) == 3);
        await SaveShellRenderAsync(Root, output, "shell-" + theme.ToString().ToLowerInvariant());
        Model.Page = ShellPage.Settings; await Task.Delay(300);
        Check(theme + " Settings is a separate native window", settingsWindow is not null && settingsPanel!.ActualWidth >= 680);
        await SaveShellRenderAsync(settingsWindowRoot!, output, "settings-" + theme.ToString().ToLowerInvariant());
        CloseSettingsPanel();
      }
      await Runtime.Door.CallAsync(caller.Id, "windows.pop_out", JsonSerializer.SerializeToElement(new { sessionId = b2 }));
      await Task.Delay(500);
      Check("MCP pop-out creates a separate native app window", detached.Count == 1 && windowState.Get(b2).Host != "main");
      var child = detached.Values.Single();
      Check("separate window has a custom title bar", child.Window.ExtendsContentIntoTitleBar);
      await SaveShellRenderAsync(child.Root, output, "detached-browser-dark");
      await Runtime.Door.CallAsync(caller.Id, "windows.pop_out", JsonSerializer.SerializeToElement(new { sessionId = b2, display = "dock" }));
      Check("MCP dock brings the same browser tab back", detached.Count == 0 && windowState.Get(b2).Host == "main");
      PopSession(first.Id); await Task.Delay(300);
      Check("pop session transfers all its windows", windowState.Tabs.Where(t => t.Owner == first.Id).Select(t => t.Host).Distinct().Single() != "main");
      foreach (var id in windowState.Tabs.Where(t => t.Host != "main").Select(t => t.Id).ToArray()) DockTab(id);
      Check("session windows return without duplication", detached.Count == 0 && windowState.Tabs.Select(t => t.Id).Distinct().Count() == windowState.Tabs.Count);
      SelectSessionWindow(first); Model.Page = ShellPage.Tasks;
      Check("sidebar selection clears on another page", SessionList.SelectedItem is null);
      Check("session tabs remain in the header on another page", ProofTree(WorkspaceHeader).OfType<Button>().Any(b => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(b) == first.Title));
      SelectSessionWindow(first);
      Check("sidebar selection follows the shown session", SessionList.SelectedItem == first);
      await CloseWindowAsync(b2);
      Check("closing one browser keeps its sibling", windowState.Tabs.Any(t => t.Id == b1) && !windowState.Tabs.Any(t => t.Id == b2));
      Runtime.Door.Revoke(caller.Id);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { failed.Add(ex.ToString()); }
    await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, passed, failed }, new JsonSerializerOptions { WriteIndented = true }));
    closingShell = true;
    Close();
  }
  private static IEnumerable<DependencyObject> ProofTree(DependencyObject node)
  {
    yield return node;
    for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
      foreach (var child in ProofTree(VisualTreeHelper.GetChild(node, i))) yield return child;
  }
  private static async Task SaveShellRenderAsync(FrameworkElement element, string output, string name)
  {
    var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(element);
    var pixels = await bitmap.GetPixelsAsync();
    var folder = await StorageFolder.GetFolderFromPathAsync(output);
    var file = await folder.CreateFileAsync(name + ".png", CreationCollisionOption.ReplaceExisting);
    using var stream = await file.OpenAsync(FileAccessMode.ReadWrite);
    var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
    var bytes = new byte[pixels.Length];
    using (var reader = Windows.Storage.Streams.DataReader.FromBuffer(pixels)) reader.ReadBytes(bytes);
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, bytes);
    await encoder.FlushAsync();
  }
}
