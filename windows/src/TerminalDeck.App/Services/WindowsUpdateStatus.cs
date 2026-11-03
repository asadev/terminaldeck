using System.Xml.Linq;
using TerminalDeck.Core.Platform;
using Windows.Management.Deployment;

namespace TerminalDeck.App.Services;

internal static class WindowsUpdateStatus
{
  internal const string UpdateAvailableText = "Restart to update when you are ready. Your sessions reopen after the update.";
  internal const string RestartLabel = "Restart to update";
  internal const string UpdateWaitingText = "Update available. Terminal Deck restarts to update by itself once no AI is working and nobody is using this PC, or click Restart to update now. Your sessions reopen after the update.";
  [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
  private struct LastInputInfo { public uint Size; public uint Time; }
  [System.Runtime.InteropServices.DllImport("user32.dll")]
  private static extern bool GetLastInputInfo(ref LastInputInfo info);
  // Time since the last keyboard or mouse input in this Windows session (null: unknown).
  internal static TimeSpan? SinceLastInput()
  {
    var info = new LastInputInfo { Size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<LastInputInfo>() };
    if (!GetLastInputInfo(ref info)) return null;
    return TimeSpan.FromMilliseconds(unchecked((uint)Environment.TickCount - info.Time));
  }
  // Release 27: the update source is the public GitHub releases (GitHubReleaseChannel: the signed
  // release-manifest.json), the same one the Mac app reads. The last check's answer, for the side panel's card
  // just above Settings and for Settings' "Check for updates".
  internal static bool Available { get; private set; }
  internal static GitHubReleaseChannel.WindowsRelease? Offered { get; private set; }
  // Download progress while Restart to update fetches the package (0-100), null otherwise.
  internal static double? DownloadPercent { get; private set; }
  internal static event Action? Changed;
  internal static string ShortVersion(string version) => version.EndsWith(".0", StringComparison.Ordinal) && version.Count(c => c == '.') == 3 ? version[..^2] : version;
  internal static string AvailableText(string version) => "Update available · " + ShortVersion(version);
  // Any registered MSIX of this layout can update itself from GitHub; a loose review layout cannot.
  internal static bool HasUpdateSource()
  {
    try { return InstalledPackage() is not null; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { return false; }
  }
  internal static async Task<bool> IsUpdateAvailableAsync()
  {
    if (!HasUpdateSource()) return false;
    await CheckAsync();
    return Available;
  }

  [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
  private static extern int RegisterApplicationRestart(string? commandLine, int flags);

  // One step for the person: the package is downloaded from GitHub and checked (size, SHA-256, package name,
  // publisher and version from the signed manifest) BEFORE anything is stopped; then the keeper hands its
  // sessions over and exits, any Claude sign-in renewal still under way finishes saving, and Windows replaces the
  // package (checking its signature itself), closes this window and reopens it on the new version with the same
  // arguments. Nothing with a live session is ever force-closed: the handover runs first, and a failed handover
  // or a refused package stops the update with the sessions kept.
  // The offered package, downloaded and checked, ready to install. A file already downloaded for this exact release
  // is checked again (size, SHA-256, its own identity) and reused instead of fetched again (Reviewer #9, 4 Nov: the
  // automatic restart downloads first, then looks at the PC again, and may wait for the next quiet moment).
  internal static async Task<string> PrepareAsync(string updatesFolder)
  {
    var release = Offered ?? throw new InvalidOperationException("No update is waiting. Check for updates first.");
    var kept = Path.Combine(updatesFolder, "TerminalDeck-" + release.Version + "-x64.msix");
    if (File.Exists(kept))
    {
      try { GitHubReleaseChannel.VerifyFile(kept, release); GitHubReleaseChannel.VerifyPackage(kept, release); return kept; }
      catch (GitHubReleaseChannel.RefusedException) { File.Delete(kept); }
    }
    using var client = GitHubReleaseChannel.NewClient();
    var progress = new Progress<double>(percent => { DownloadPercent = Math.Min(100, Math.Floor(percent)); Changed?.Invoke(); });
    try { return await GitHubReleaseChannel.DownloadAsync(client, release, updatesFolder, progress, CancellationToken.None); }
    finally { DownloadPercent = null; Changed?.Invoke(); }
  }

  internal static async Task<string> RestartToUpdateAsync(string updatesFolder, Func<Task> handOver, Func<Task> settleSignIns, Func<Task> resume)
  {
    _ = InstalledPackage() ?? throw new InvalidOperationException("This build has no registered MSIX package, so it cannot update itself.");
    var file = await PrepareAsync(updatesFolder);
    await TerminalDeck.Core.Platform.PackageUpdateSequence.RunAsync(handOver, settleSignIns, async () =>
    {
      var arguments = Environment.GetCommandLineArgs().Skip(1).Select(a => a.Contains(' ') || a.Contains('"') ? "\"" + a.Replace("\"", "") + "\"" : a);
      RegisterApplicationRestart(string.Join(" ", arguments), 0);
      var manager = new PackageManager();
      var result = await manager.AddPackageAsync(new Uri(file), null, DeploymentOptions.ForceTargetApplicationShutdown);
      if (result.ExtendedErrorCode is { } error) throw new IOException(string.IsNullOrWhiteSpace(result.ErrorText) ? error.Message : result.ErrorText, error);
      // Still running: Windows had nothing newer to apply.
      Available = false; Offered = null; Changed?.Invoke();
    }, resume);
    return "You’re up to date.";
  }
  // Loose-layout review launches lack Package.Current. Match only this layout's
  // registration; never show a DLL/assembly version as an installed MSIX version.
  private static Windows.ApplicationModel.Package? InstalledPackage() => new PackageManager().FindPackagesForUser("")
    .FirstOrDefault(p => string.Equals(Path.TrimEndingDirectorySeparator(p.InstalledLocation.Path), Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory), StringComparison.OrdinalIgnoreCase));
  internal static string Version()
  {
    try { if (InstalledPackage() is { } package) { var v = package.Id.Version; return $"{v.Major}.{v.Minor}.{v.Build}.{v.Revision}"; } }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
    var manifest = Path.Combine(AppContext.BaseDirectory, "AppxManifest.xml");
    return File.Exists(manifest) ? XDocument.Load(manifest).Descendants().FirstOrDefault(e => e.Name.LocalName == "Identity")?.Attribute("Version")?.Value ?? "Unavailable" : "Unavailable";
  }
  internal static async Task<string> CheckAsync()
  {
    var package = InstalledPackage();
    if (package is null) return "This build has no registered MSIX package, so it cannot update itself. Install it from " + GitHubReleaseChannel.Repository + "'s GitHub releases.";
    try
    {
      using var client = GitHubReleaseChannel.NewClient();
      using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(45));
      var release = await GitHubReleaseChannel.FetchAsync(client, deadline.Token);
      var v = package.Id.Version;
      Available = GitHubReleaseChannel.IsNewer(release.Version, new System.Version(v.Major, v.Minor, v.Build, v.Revision));
      Offered = Available ? release : null;
      Changed?.Invoke();
      return Available ? AvailableText(release.Version) + ". Restart to update is in the side panel, just above Settings." : "You’re up to date.";
    }
    catch (GitHubReleaseChannel.RefusedException ex) { return ex.Message; }
    catch (Exception ex) when (ex is HttpRequestException or IOException or OperationCanceledException) { return "GitHub could not be reached to check for updates. " + ex.Message; }
  }
}
