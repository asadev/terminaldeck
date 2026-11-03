using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.Core.Receiver;
using Windows.Data.Pdf;
using Windows.Media.Core;
using Windows.Storage;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Views.Receiver;

// Every file path here came from the catalog's guarded preview operation.
// HTML gets an isolated profile and no script, navigation or network access.
internal sealed class ArtifactPreviewSurface : Grid, IDisposable
{
  private readonly ArtifactPreview preview;
  private readonly TextBlock outcome = new() { TextWrapping = TextWrapping.Wrap };
  private readonly ProgressBar pending = new() { IsIndeterminate = true, Height = 3 };
  private WebView2? web;
  private MediaPlayerElement? media;
  private string? webRoot;
  private bool disposed;
  private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
  internal Task Ready => ready.Task;
  internal string? Problem { get; private set; }
  internal ArtifactPreviewSurface(ArtifactPreview preview)
  {
    this.preview = preview; MinHeight = 200; MaxHeight = 440;
    RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) }); RowDefinitions.Add(new() { Height = GridLength.Auto });
    Children.Add(pending); SetRow(outcome, 2); Children.Add(outcome);
    Loaded += async (_, _) =>
    {
      try { await LoadAsync(); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { Problem = ex.GetType().Name; outcome.Text = (ex is TimeoutException ? "The preview took too long to draw." : ex.GetType().Name == "WebView2RuntimeNotFoundException" ? "Web previews need the Microsoft Edge WebView2 Runtime." : "Preview could not open.") + " Use Open in its app to view the file."; }
      finally { pending.Visibility = Visibility.Collapsed; ready.TrySetResult(); }
    };
  }
  private void Content(FrameworkElement content) { SetRow(content, 1); Children.Add(content); }
  private async Task LoadAsync()
  {
    if (disposed) return;
    if (preview.MediaType == "application/pdf" && preview.FilePath is { } documentPath)
    {
      var document = await PdfDocument.LoadFromFileAsync(await StorageFile.GetFileFromPathAsync(documentPath)); if (disposed) return;
      var panel = new StackPanel { Spacing = 8 }; var image = new Image { MaxHeight = 350, Stretch = Stretch.Uniform };
      var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; uint page = 0;
      var previous = new Button { Content = "Previous page" }; var next = new Button { Content = "Next page" }; var count = new TextBlock();
      buttons.Children.Add(previous); buttons.Children.Add(count); buttons.Children.Add(next); panel.Children.Add(buttons); panel.Children.Add(image); Content(panel);
      async Task Show()
      {
        previous.IsEnabled = false; next.IsEnabled = false; pending.Visibility = Visibility.Visible;
        try
        {
          using var rendered = document.GetPage(page); using var stream = new InMemoryRandomAccessStream();
          await rendered.RenderToStreamAsync(stream, new PdfPageRenderOptions { DestinationWidth = 900 });
          var bitmap = new BitmapImage(); await bitmap.SetSourceAsync(stream); if (disposed) return;
          image.Source = bitmap; count.Text = $"Page {page + 1} of {document.PageCount}";
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) { Problem = ex.GetType().Name; outcome.Text = "This page could not be read. Try another page or open the document in its app."; }
        finally { previous.IsEnabled = page > 0; next.IsEnabled = page + 1 < document.PageCount; pending.Visibility = Visibility.Collapsed; }
      }
      previous.Click += async (_, _) => { if (page > 0) { page--; await Show(); } };
      next.Click += async (_, _) => { if (page + 1 < document.PageCount) { page++; await Show(); } };
      await Show(); return;
    }
    if ((preview.MediaType.StartsWith("audio/", StringComparison.Ordinal) || preview.MediaType.StartsWith("video/", StringComparison.Ordinal)) && preview.FilePath is { } recording)
    {
      media = new MediaPlayerElement { AreTransportControlsEnabled = true, AutoPlay = false, Height = preview.MediaType.StartsWith("audio/", StringComparison.Ordinal) ? 120 : 340 };
      media.Source = MediaSource.CreateFromUri(new Uri(recording)); Content(media); return;
    }
    if (preview.MediaType == "text/html" && preview.Text is { } html)
    {
      webRoot = Path.Combine(Path.GetTempPath(), "td-artifact-preview-" + Guid.NewGuid().ToString("N"));
      var environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, webRoot, null); if (disposed) return;
      web = new WebView2 { Height = 340 }; Content(web); await web.EnsureCoreWebView2Async(environment); if (disposed) return;
      var core = web.CoreWebView2; core.Settings.IsScriptEnabled = false; core.Settings.IsWebMessageEnabled = false;
      core.Settings.AreHostObjectsAllowed = false; core.Settings.AreDevToolsEnabled = false; core.Settings.AreDefaultContextMenusEnabled = false;
      core.NewWindowRequested += (_, e) => e.Handled = true;
      core.DownloadStarting += (_, e) => e.Cancel = true;
      // NavigateToString reports its own document as a data:text/html URI, not
      // about:blank; cancelling it failed every HTML preview. Allow exactly that
      // one navigation we start, and nothing after it.
      var started = false;
      core.NavigationStarting += (_, e) =>
      {
        if (!started && (e.Uri == "about:blank" || e.Uri.StartsWith("data:text/html", StringComparison.OrdinalIgnoreCase))) { started = true; return; }
        e.Cancel = true;
      };
      core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
      core.WebResourceRequested += (_, e) =>
      {
        if (e.Request.Uri.StartsWith("data:", StringComparison.OrdinalIgnoreCase)) return;
        e.Response = environment.CreateWebResourceResponse(null, 403, "Preview resource blocked", "Content-Type: text/plain");
      };
      var navigation = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
      core.NavigationCompleted += (_, e) => { if (e.IsSuccess) navigation.TrySetResult(); else navigation.TrySetException(new IOException("Page preview navigation failed.")); };
      core.NavigateToString("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'\">" + html);
      await navigation.Task.WaitAsync(TimeSpan.FromSeconds(15));
      if (preview.Truncated) outcome.Text = "Preview stops after 65,536 characters.";
      return;
    }
    if (preview.ImagePath is { } path)
    {
      Content(new Image { Source = path.EndsWith(".svg", StringComparison.OrdinalIgnoreCase) ? new SvgImageSource(new Uri(path)) : new BitmapImage(new Uri(path)), MaxHeight = 380, Stretch = Stretch.Uniform }); return;
    }
    Content(new TextBlock { Text = preview.Text ?? "No preview is available.", TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
  }
#if TD_W12_SERVERS_RECEIVER_HOOT
  internal async Task<byte[]> CapturePageAsync()
  {
    using var stream = new InMemoryRandomAccessStream();
    await web!.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
    stream.Seek(0); using var read = new DataReader(stream.GetInputStreamAt(0)); await read.LoadAsync((uint)stream.Size);
    var bytes = new byte[checked((int)stream.Size)]; read.ReadBytes(bytes); return bytes;
  }
  internal async Task<string> PageTextAsync() => await web!.CoreWebView2.ExecuteScriptAsync("document.body.innerText");
#endif
  public void Dispose()
  {
    disposed = true; media?.MediaPlayer?.Dispose(); web?.Close();
    if (webRoot is { } owned)
      try { Directory.Delete(owned, true); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
  }
}
