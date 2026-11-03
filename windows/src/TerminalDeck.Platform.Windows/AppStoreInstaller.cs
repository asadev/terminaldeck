using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Store;

namespace TerminalDeck.Platform.Windows;

public interface IStoreBrowserExtensions
{
  ValueTask<string> InstallAsync(string directory, CancellationToken ct);
  ValueTask RemoveAsync(string extensionId, CancellationToken ct);
}
public sealed class AppStoreInstaller(string root, HttpClient http, IStoreBrowserExtensions browser, CommunityStoreOperations? community = null) : IAppStoreInstaller
{
  public async ValueTask<StoreInstallation> InstallAsync(StoreEntry entry, bool update, CancellationToken ct, StoreInstallOptions? options = null)
  {
    if (options?.EnsureCurrent is { } current) await current(ct);
    if (entry.Delivery == "mcp-store")
    { if (community is null) throw new InvalidOperationException("The MCP Store owner is not connected."); return await community.InstallMcpStockAsync(entry, options ?? new(), http, ct); }
    if (entry.Delivery == "community")
    {
      if (community is null) throw new InvalidOperationException("The community installation owner is not connected.");
      return await community.InstallAsync(entry, options ?? new(), http, ct);
    }
    if (entry.Delivery == "browser-tool") return new("browser-tool:" + entry.Id, entry.Version);
    if (entry.Delivery == "winget")
    {
      await WingetAsync(update ? "upgrade" : "install", entry, ct); return new("winget:" + entry.Source, await InstalledVersionAsync(entry, ct));
    }
    if (entry.Artifact is null || !Uri.TryCreate(entry.Artifact, UriKind.Absolute, out var uri) || uri.Scheme != "https" || !string.IsNullOrEmpty(uri.UserInfo) || entry.Sha256?.Length != 64 || entry.Bytes is < 1 or > 128 * 1024 * 1024) throw new IOException("This archive lacks a bounded HTTPS download and fingerprint.");
    var home = Path.Combine(root, "store", Convert.ToHexStringLower(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(entry.Id)))); Directory.CreateDirectory(home);
    var stage = Path.Combine(home, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(stage);
    try
    {
      using var request = StoreNetwork.Get(uri.AbsoluteUri); using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct); response.EnsureSuccessStatusCode();
      if (response.RequestMessage?.RequestUri?.Scheme != "https") throw new IOException("The download redirected outside HTTPS.");
      if (response.Content.Headers.ContentLength is { } length && length != entry.Bytes) throw new IOException("The archive size does not match this catalogue.");
      await using var input = await response.Content.ReadAsStreamAsync(ct); using var data = new MemoryStream(); var buffer = new byte[65536];
      while (true) { var read = await input.ReadAsync(buffer, ct); if (read == 0) break; if (data.Length + read > entry.Bytes) throw new IOException("The archive exceeds its declared size."); await data.WriteAsync(buffer.AsMemory(0, read), ct); }
      var bytes = data.ToArray(); if (bytes.Length != entry.Bytes || !Convert.ToHexStringLower(SHA256.HashData(bytes)).Equals(entry.Sha256, StringComparison.OrdinalIgnoreCase)) throw new IOException("The downloaded archive fingerprint did not match.");
      await SafeStoreArchive.ExtractAsync(bytes, stage, ct);
      if (options?.EnsureCurrent is { } refresh) await refresh(ct);
      string? extension = null;
      if (entry.Delivery == "browser-extension") extension = await browser.InstallAsync(stage, ct);
      else if (entry.Delivery == "tool-archive")
      {
        var command = Path.GetFullPath(Path.Combine(stage, entry.Executable ?? throw new IOException("This app tool has no executable.")));
        if (!command.StartsWith(stage + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || !File.Exists(command)) throw new IOException("The app tool executable is missing or outside its archive.");
      }
      else throw new IOException("Unsupported delivery.");
      return new(JsonSerializer.Serialize(new StoreReceipt(stage, extension)), entry.Version);
    }
    catch { Directory.Delete(stage, true); throw; }
  }
  public async ValueTask RemoveAsync(StoreEntry entry, string receipt, CancellationToken ct)
  {
    if (entry.Delivery is "community" or "mcp-store")
    { if (community is null) throw new InvalidOperationException("The community installation owner is not connected."); await community.RemoveAsync(entry, receipt, ct); return; }
    if (entry.Delivery == "browser-tool") return;
    if (entry.Delivery == "winget") { await WingetAsync("uninstall", entry, ct); return; }
    var value = JsonSerializer.Deserialize<StoreReceipt>(receipt) ?? throw new IOException("The installation receipt is missing.");
    var home = Path.GetFullPath(Path.Combine(root, "store")) + Path.DirectorySeparatorChar; var directory = Path.GetFullPath(value.Directory);
    if (!directory.StartsWith(home, StringComparison.OrdinalIgnoreCase) || (new DirectoryInfo(directory).Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("The receipt is outside this app's Store.");
    if (value.ExtensionId is not null) await browser.RemoveAsync(value.ExtensionId, ct);
    Directory.Delete(directory, true);
  }
  private async Task<string> InstalledVersionAsync(StoreEntry entry, CancellationToken ct)
  {
    var temporary = Path.Combine(root, "store", "inventory-" + Guid.NewGuid().ToString("N") + ".json"); Directory.CreateDirectory(Path.GetDirectoryName(temporary)!);
    try
    {
      var start = new ProcessStartInfo("winget.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
      foreach (var argument in new[] { "export", "--output", temporary, "--include-versions", "--disable-interactivity", "--accept-source-agreements" }) start.ArgumentList.Add(argument);
      using var process = Process.Start(start) ?? throw new IOException("Windows package inventory could not start.");
      var output = process.StandardOutput.ReadToEndAsync(ct); var error = process.StandardError.ReadToEndAsync(ct);
      using var stop = ct.Register(() => { try { process.Kill(true); } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { } });
      await process.WaitForExitAsync(ct); await Task.WhenAll(output, error);
      if (process.ExitCode != 0 || !File.Exists(temporary) || new FileInfo(temporary).Length > 16 * 1024 * 1024) throw new IOException("The package operation completed, but its installed version could not be read. Check Windows Apps before retrying.");
      using var document = JsonDocument.Parse(await File.ReadAllBytesAsync(temporary, ct));
      foreach (var source in document.RootElement.GetProperty("Sources").EnumerateArray())
        foreach (var package in source.GetProperty("Packages").EnumerateArray())
          if (package.GetProperty("PackageIdentifier").GetString() == entry.Source && package.TryGetProperty("Version", out var version)) return version.GetString() ?? "Version unavailable";
      throw new IOException("The package operation completed, but Windows did not list the installed package. Check Windows Apps before retrying.");
    }
    finally { if (File.Exists(temporary)) File.Delete(temporary); }
  }
  private static async Task WingetAsync(string action, StoreEntry entry, CancellationToken ct)
  {
    if (!System.Text.RegularExpressions.Regex.IsMatch(entry.Source, "^[a-zA-Z0-9][a-zA-Z0-9._-]{1,199}$")) throw new IOException("The package ID is invalid.");
    var start = new ProcessStartInfo("winget.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
    foreach (var argument in new[] { action, "--id", entry.Source, "--exact", "--source", "winget", "--disable-interactivity" }) start.ArgumentList.Add(argument);
    using var process = Process.Start(start) ?? throw new IOException("Windows App Installer is unavailable. Install it from Microsoft Store, then retry.");
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromMinutes(15));
    using var cancel = deadline.Token.Register(() => { try { process.Kill(true); } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { } });
    var stdout = process.StandardOutput.ReadToEndAsync(deadline.Token); var stderr = process.StandardError.ReadToEndAsync(deadline.Token);
    await process.WaitForExitAsync(deadline.Token); await Task.WhenAll(stdout, stderr);
    if (process.ExitCode != 0) throw new IOException("Windows App Installer refused or could not finish " + action + ". Check its package requirements and retry.");
  }
  private sealed record StoreReceipt(string Directory, string? ExtensionId);
}
