using System.Xml.Linq;
using Windows.Management.Deployment;

namespace TerminalDeck.App.Services;

internal static class WindowsUpdateStatus
{
  internal const string UpdateAvailableText = "Update available — Restart to update. Your sessions reopen after the update.";
  internal const string RestartLabel = "Restart to update";
  // Last check result; Settings shows the restart button straight away.
  internal static bool Available { get; private set; }
  internal static bool HasUpdateSource()
  {
    try { return InstalledPackage()?.GetAppInstallerInfo() is not null; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { return false; }
  }
  internal static async Task<bool> IsUpdateAvailableAsync()
  {
    if (!HasUpdateSource()) return false;
    await CheckAsync();
    // Windows may already have staged the newer version in the background; it
    // then reports no update while the keeper still holds the old files. Read a
    // private file channel directly so that staged update is still applied.
    if (!Available && InstalledPackage() is { } package && package.GetAppInstallerInfo()?.Uri is { IsFile: true } source)
    {
      try
      {
        var offered = XDocument.Load(source.LocalPath).Descendants().FirstOrDefault(e => e.Name.LocalName == "MainPackage")?.Attribute("Version")?.Value;
        var v = package.Id.Version;
        if (System.Version.TryParse(offered, out var newer) && newer > new System.Version(v.Major, v.Minor, v.Build, v.Revision)) Available = true;
      }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Xml.XmlException) { }
    }
    return Available;
  }

  [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
  private static extern int RegisterApplicationRestart(string? commandLine, int flags);

  // One step for the person: the keeper hands its sessions over and exits, then
  // Windows replaces the package through this package's own App Installer
  // source, closes this window and reopens it on the new version with the same
  // arguments. Nothing with a live session is ever force-closed: the handover
  // runs first, and a failed handover stops the update.
  internal static async Task<string> RestartToUpdateAsync(Func<Task> handOver, Func<Task> resume)
  {
    var package = InstalledPackage() ?? throw new InvalidOperationException("This build has no registered MSIX updater.");
    var source = package.GetAppInstallerInfo()?.Uri ?? throw new InvalidOperationException("This package has no update source configured.");
    await handOver();
    try
    {
      var arguments = Environment.GetCommandLineArgs().Skip(1).Select(a => a.Contains(' ') || a.Contains('"') ? "\"" + a.Replace("\"", "") + "\"" : a);
      RegisterApplicationRestart(string.Join(" ", arguments), 0);
      var manager = new PackageManager();
      var result = await manager.AddPackageByAppInstallerFileAsync(source, AddPackageByAppInstallerOptions.ForceTargetAppShutdown, manager.GetDefaultPackageVolume());
      if (result.ExtendedErrorCode is { } error) throw new IOException(string.IsNullOrWhiteSpace(result.ErrorText) ? error.Message : result.ErrorText, error);
    }
    catch { await resume(); throw; }
    // Still running: Windows had nothing newer to apply. Bring sessions back.
    Available = false;
    await resume();
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
    if (package is null) return "This build has no registered MSIX updater. Install a build with an App Installer update source to check online.";
    if (package.GetAppInstallerInfo() is null) return "Version " + Version() + ". This review package has no update source configured.";
    var result = await package.CheckUpdateAvailabilityAsync();
    Available = result.Availability is Windows.ApplicationModel.PackageUpdateAvailability.Available or Windows.ApplicationModel.PackageUpdateAvailability.Required;
    return result.Availability switch {
      Windows.ApplicationModel.PackageUpdateAvailability.Available or Windows.ApplicationModel.PackageUpdateAvailability.Required => UpdateAvailableText,
      Windows.ApplicationModel.PackageUpdateAvailability.NoUpdates => "You’re up to date.",
      _ => "Windows could not check this package’s update source. " + result.ExtendedError?.Message
    };
  }
}
