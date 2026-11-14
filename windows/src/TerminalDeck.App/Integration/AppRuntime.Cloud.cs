using TerminalDeck.Core.Cloud;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

/// Cloud on this PC. Built inert in the constructor (no request, key, file or listener); at start-up `ResumeAsync` only
/// reads the protected record if this PC already has one. Sign in starts from Settings → Cloud, or from a
/// `terminaldeck://cloud/signin` link after the person says yes; it finishes by itself when the website hands back
/// `terminaldeck://cloud/return/<token>` for the sign-in this copy started. Agents get the read-only `cloud.status` tool.
public sealed partial class AppRuntime
{
  private LazyCloudHttp? cloudHttp;
  private readonly object cloudLogGate = new();
  public CloudAccountClient Cloud { get; private set; } = null!;

  private void InitializeCloud()
  {
    cloudHttp = new(() => new HttpClientCloudHttp());
    Cloud = CloudComposition.Create(CloudConfiguration.Today(Environment.MachineName, PhoneAppVersion), new WindowsCloudKeyStore(Root), new WindowsCloudBrowser(), cloudHttp);
    Cloud.StageLog = WriteCloudLog;
    CloudTools.Register(Cloud, Door);
  }

  /// One plain line per sign-in stage, in `logs\cloud.log` of this copy's own data folder. The lines never carry a token,
  /// code, key, e-mail or name (CloudAccountClient writes only stage names and error kinds).
  private void WriteCloudLog(string line)
  {
    try
    {
      lock (cloudLogGate)
      {
        var logs = Path.Combine(Root.DirectoryPath, "logs");
        Directory.CreateDirectory(logs);
        File.AppendAllText(Path.Combine(logs, "cloud.log"), DateTimeOffset.UtcNow.ToString("O") + " " + line + Environment.NewLine);
      }
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
  }

  private async Task ResumeCloudAsync()
  {
    // A damaged or unreadable record leaves Cloud signed out; it never stops the app from starting.
    try { await Cloud.ResumeAsync(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
  }

  private void DisposeCloud() { Cloud?.Dispose(); cloudHttp?.Dispose(); }
}
