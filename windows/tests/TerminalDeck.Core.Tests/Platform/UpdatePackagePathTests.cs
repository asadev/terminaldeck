using System.Diagnostics;
using TerminalDeck.App.Services;

namespace TerminalDeck.Core.Tests.Platform;

public sealed class UpdatePackagePathTests
{
  [Fact]
  public void InstallerReceivesPhysicalFileInsteadOfTheRedirectedName()
  {
    if (!OperatingSystem.IsWindows()) return;
    var root = Path.Combine(Path.GetTempPath(), "deck-update-path-" + Guid.NewGuid().ToString("N"));
    var physical = Path.Combine(root, "LocalCache", "Local", "TerminalDeck", "updates");
    var alias = Path.Combine(root, "virtual-updates");
    Directory.CreateDirectory(physical);
    try
    {
      using var junction = Process.Start(new ProcessStartInfo("cmd.exe")
      {
        ArgumentList = { "/d", "/c", "mklink", "/J", alias, physical },
        CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false
      })!;
      junction.WaitForExit();
      Assert.Equal(0, junction.ExitCode);
      var virtualFile = Path.Combine(alias, "TerminalDeck-0.22.2.0-x64.msix");
      File.WriteAllText(virtualFile, "downloaded package bytes");
      var installerFile = UpdatePackagePath.PhysicalFile(virtualFile);
      Assert.Equal(Path.Combine(physical, Path.GetFileName(virtualFile)), installerFile, StringComparer.OrdinalIgnoreCase);
      Directory.Delete(alias);
      Assert.False(File.Exists(virtualFile));
      Assert.Equal("downloaded package bytes", File.ReadAllText(installerFile));
      Assert.Equal(installerFile, UpdatePackagePath.PhysicalFile(installerFile), StringComparer.OrdinalIgnoreCase);
      Assert.ThrowsAny<IOException>(() => UpdatePackagePath.PhysicalFile(virtualFile));
    }
    finally
    {
      if (Directory.Exists(alias)) Directory.Delete(alias);
      Directory.Delete(root, true);
    }
  }
}
