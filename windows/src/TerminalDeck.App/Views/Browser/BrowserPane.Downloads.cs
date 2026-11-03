using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Windows.Storage;
using Windows.System;

namespace TerminalDeck.App.Views;

internal sealed class BrowserDownload(string id, string tabId, string url, string path, CoreWebView2DownloadOperation operation)
{
  public string Id { get; } = id;
  public string TabId { get; } = tabId;
  public string Url { get; } = url;
  public string Path { get; } = path;
  public CoreWebView2DownloadOperation Operation { get; } = operation;
  public string State => Operation.State switch
  {
    CoreWebView2DownloadState.Completed => "Saved on this computer",
    CoreWebView2DownloadState.Interrupted => Operation.InterruptReason == CoreWebView2DownloadInterruptReason.UserCanceled ? "Stopped" : "Failed · " + Operation.InterruptReason,
    _ => Operation.TotalBytesToReceive is { } total && total > 0 ? $"{Operation.BytesReceived:N0} / {total:N0} bytes" : $"{Operation.BytesReceived:N0} bytes"
  };
}

public sealed partial class BrowserPane
{
  private readonly List<BrowserDownload> downloads = [];
  private event Action? DownloadsChanged;
  // The known Downloads folder can be redirected by Windows; do not synthesize
  // it from USERPROFILE, which would silently bypass that destination.
  private string DownloadsDirectory => proofDownloads ?? WindowsDownloadsFolder.Path();
  private void StartDownload(BrowserTab tab, CoreWebView2DownloadStartingEventArgs args)
  {
    if (tab.AutomationOrigin is not null) { args.Cancel = true; SetTabStatus(tab, "A driven page cannot start a download. Hand the page back first."); return; }
    try
    {
      var directory = DownloadsDirectory; Directory.CreateDirectory(directory);
      var name = TerminalDeck.Core.Browser.BrowserDownloadNames.FileName(args.ResultFilePath);
      var path = Path.Combine(directory, name); var count = 1;
      while (File.Exists(path) || downloads.Any(d => d.Path.Equals(path, StringComparison.OrdinalIgnoreCase)))
        path = Path.Combine(directory, Path.GetFileNameWithoutExtension(name) + $" ({count++})" + Path.GetExtension(name));
      args.ResultFilePath = path; args.Handled = true;
      var item = new BrowserDownload(Guid.NewGuid().ToString("N"), tab.Id, args.DownloadOperation.Uri, path, args.DownloadOperation);
      downloads.Add(item);
      void Changed() { DownloadsChanged?.Invoke(); RefreshShellViews(); }
      item.Operation.BytesReceivedChanged += (_, _) => Changed(); item.Operation.StateChanged += (_, _) => Changed(); Changed();
      SetTabStatus(tab, "Downloading " + name);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { args.Cancel = true; SetTabStatus(tab, "The download could not be saved. Check your Downloads folder and try again."); }
  }
  private async Task ShowDownloadsAsync(BrowserTab tab, FrameworkElement? anchor = null)
  {
    var content = new StackPanel { Spacing = 10, Width = 360 };
    content.Children.Add(new TextBlock { Text = DownloadsDirectory, TextWrapping = TextWrapping.Wrap });
    var rows = new StackPanel { Spacing = 12 }; content.Children.Add(new ScrollViewer { Content = rows, MaxHeight = 320 });
    var clear = TextAction("Clear finished", () => { downloads.RemoveAll(d => d.Operation.State != CoreWebView2DownloadState.InProgress); DownloadsChanged?.Invoke(); RefreshShellViews(); }); content.Children.Add(clear);
    content.Children.Add(TextAction("Open Downloads Folder", async () => await GuardAsync(async () => { await Launcher.LaunchFolderPathAsync(DownloadsDirectory); }, tab)));
    void Render()
    {
      rows.Children.Clear(); clear.IsEnabled = downloads.Any(d => d.Operation.State != CoreWebView2DownloadState.InProgress);
      if (downloads.Count == 0) rows.Children.Add(new TextBlock { Text = "Nothing downloaded yet" });
      foreach (var item in downloads.AsEnumerable().Reverse())
      {
        var row = new StackPanel { Spacing = 4 };
        row.Children.Add(new TextBlock { Text = Path.GetFileName(item.Path), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        row.Children.Add(new TextBlock { Text = item.State, TextWrapping = TextWrapping.Wrap });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (item.Operation.State == CoreWebView2DownloadState.InProgress) actions.Children.Add(TextAction("Stop", () => item.Operation.Cancel()));
        if (item.Operation.State == CoreWebView2DownloadState.Completed)
        {
          async Task Open() { await Launcher.LaunchFileAsync(await StorageFile.GetFileFromPathAsync(item.Path)); }
          row.DoubleTapped += async (_, _) => await GuardAsync(Open, tab);
          actions.Children.Add(TextAction("Open", async () => await GuardAsync(Open, tab)));
          actions.Children.Add(TextAction("Show in Explorer", async () => await GuardAsync(async () =>
          {
            var file = await StorageFile.GetFileFromPathAsync(item.Path); var options = new FolderLauncherOptions(); options.ItemsToSelect.Add(file); await Launcher.LaunchFolderAsync(await file.GetParentAsync(), options);
          }, tab)));
        }
        actions.Children.Add(TextAction("Copy Address", () => { CopyText(item.Url); SetTabStatus(tab, "Download address copied."); })); row.Children.Add(actions); rows.Children.Add(row);
      }
    }
    DownloadsChanged += Render;
    if (anchor is not null)
    {
      content.Children.Insert(0, new TextBlock { Text = "Downloads", FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
      var popup = new Flyout { Content = content };
      TerminalDeck.App.Views.Projects.ProjectAgentUi.MatchFlyoutTheme(anchor, popup);
      var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
      popup.Closed += (_, _) => closed.TrySetResult();
      try { Render(); popup.ShowAt(anchor); await closed.Task; }
      finally { DownloadsChanged -= Render; }
      return;
    }
    var dialog = new ContentDialog { XamlRoot = RootFor(tab), RequestedTheme = tab.View.ActualTheme, Title = "Downloads", Content = content, CloseButtonText = "Done" };
    BrowserDialogForProof = dialog;
    try { Render(); await dialog.ShowAsync(); }
    finally { DownloadsChanged -= Render; BrowserDialogForProof = null; }
  }
}

internal static class WindowsDownloadsFolder
{
  [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
  private static extern int SHGetKnownFolderPath(in Guid id, uint flags, nint token, out nint path);
  public static string Path()
  {
    var id = new Guid("374DE290-123F-4565-9164-39C4925E467B");
    System.Runtime.InteropServices.Marshal.ThrowExceptionForHR(SHGetKnownFolderPath(in id, 0, 0, out var pointer));
    try { return System.Runtime.InteropServices.Marshal.PtrToStringUni(pointer) ?? throw new IOException("The Downloads folder is unavailable."); }
    finally { System.Runtime.InteropServices.Marshal.FreeCoTaskMem(pointer); }
  }
}
