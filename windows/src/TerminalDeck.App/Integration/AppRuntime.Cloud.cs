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
  /// The bridge from the account to the sync engine. Builds nothing while signed out or while "Use Cloud on this PC" is
  /// off. 7C-1: Deck Memory syncs; this PC keeps its copy per account in `cloud\accounts\<account>\memory` (nothing
  /// on Windows reads it yet). Removals do not travel to or from Windows yet and sync never deletes anything here.
  public CloudSyncBridge? CloudSync { get; private set; }

  private void InitializeCloud()
  {
    cloudHttp = new(() => new HttpClientCloudHttp());
    // Device trust: one protected list per account and the protected "How this PC trusts your other devices" choice,
    // both DPAPI files checked by a Credential Manager key; presses refused for two seconds after this app's own remote input.
    var trust = new CloudTrustPorts((issuer, subject) => new WindowsCloudTrustStore(Root, issuer, subject), WindowsCloudTrustStore.TrustMode(Root),
      () => WindowsRemoteInputGuard.JustNow);
    Cloud = CloudComposition.Create(CloudConfiguration.Today(Environment.MachineName, PhoneAppVersion), new WindowsCloudKeyStore(Root), new WindowsCloudBrowser(), cloudHttp,
      trust: trust);
    Cloud.StageLog = WriteCloudLog;
    CloudTools.Register(Cloud, Door);
    CloudSync = new CloudSyncBridge(Cloud, new CloudSyncPlatform(
      subject => CloudSyncStore.InFolder(CloudAccountFolder(subject), subject),
      () => new HttpClientCloudSyncHttp(), new ClientWebSocketCloudSyncSockets(), new CloudSyncEndpoint(new Uri(CloudWire.ProductionBase), test: false),
      (subject, deviceId) => [CloudMemoryAdapter.ForAccount(CloudAccountFolder(subject), deviceId)]), WriteCloudLog);
    CloudSync.Start();
  }

  private string CloudAccountFolder(string subject) => Path.Combine(Root.DirectoryPath, "cloud", "accounts", subject);

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

  private void DisposeCloud() { CloudSync?.Dispose(); Cloud?.Dispose(); cloudHttp?.Dispose(); }
}
