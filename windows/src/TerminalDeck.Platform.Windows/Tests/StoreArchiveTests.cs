using System.IO.Compression;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Store;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class StoreArchiveTests
{
  [Theory] [InlineData("../outside.txt")] [InlineData("nested/../../outside.txt")] [InlineData("C:/outside.txt")] [InlineData("nested\\outside.txt")]
  public async Task ArchiveCannotEscapeItsInstallationDirectory(string name)
  {
    var path = Path.Combine(Path.GetTempPath(), "store-archive-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(path);
    try { using var bytes = new MemoryStream(); using (var zip = new ZipArchive(bytes, ZipArchiveMode.Create, true)) { var entry = zip.CreateEntry(name); using var writer = new StreamWriter(entry.Open()); writer.Write("not installed"); } await Assert.ThrowsAsync<IOException>(() => SafeStoreArchive.ExtractAsync(bytes.ToArray(), path, CancellationToken.None)); Assert.Empty(Directory.EnumerateFileSystemEntries(path)); }
    finally { Directory.Delete(path, true); }
  }
  [Fact] public async Task BuiltInBrowserToolEnrollmentNeedsNoDownloadedExecutable()
  {
    var path = Path.Combine(Path.GetTempPath(), "store-archive-" + Guid.NewGuid().ToString("N")); var browser = new Browser(); using var http = new HttpClient(); var installer = new AppStoreInstaller(path, http, browser);
    var entry = NativeStoreStock.BuiltIns[0]; var receipt = await installer.InstallAsync(entry, false, CancellationToken.None);
    Assert.Equal("browser-tool:page-images", receipt.Receipt); Assert.Equal(0, browser.Installs); Assert.False(Directory.Exists(path)); await installer.RemoveAsync(entry, receipt.Receipt, CancellationToken.None); Assert.Equal(0, browser.Removals);
  }
  private sealed class Browser : IStoreBrowserExtensions
  {
    public int Installs, Removals;
    public ValueTask<string> InstallAsync(string directory, CancellationToken ct) { Installs++; return ValueTask.FromResult("extension"); }
    public ValueTask RemoveAsync(string extensionId, CancellationToken ct) { Removals++; return ValueTask.CompletedTask; }
  }
}
