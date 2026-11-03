using System.Diagnostics;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Servers;

namespace TerminalDeck.Servers.Tests;

public sealed class ServerFilesTests
{
  [Theory]
  [InlineData("/srv/test/../outside")]
  [InlineData("/srv/test-other/file")]
  [InlineData("relative/file")]
  [InlineData("/srv/test/.ssh/id_ed25519")]
  [InlineData("/srv/test/.env.local")]
  [InlineData("/srv/test/key.pem")]
  public async Task EscapeAndSensitivePathsRefuseBeforeNetwork(string path)
  {
    using var f = new Fixture(); var row = await f.AddAsync(true);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.ReadAsync(row.Id, path, ServerCaller.Person));
    Assert.Empty(f.Runtime.Commands);
  }
  [Fact] public async Task DeleteRequiresExactFileNameBeforeApproval()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.ChangeFileAsync(row.Id, "/srv/test/sample.txt", "delete", null, "different", ServerCaller.Person));
    Assert.Empty(f.Approval.Actions); Assert.Empty(f.Runtime.Commands);
  }
  [Fact] public async Task DownloadsAskForExactDestinationAndKeepExistingFiles()
  {
    using var f = new Fixture(); var row = await f.AddAsync();
    await f.Store.SetAccessAsync(row.Id, row.Access with { Folders = ["/srv/test"] }, default);
    f.Runtime.Reply = _ => new(0, JsonSerializer.Serialize(new { path = "/srv/test/readme", base64 = Convert.ToBase64String("sample"u8), truncated = false }));
    var destination = Path.Combine(f.Path, "downloaded");
    await f.Service.DownloadAsync(row.Id, "/srv/test/readme", destination, ServerCaller.Person);
    Assert.Equal("sample", await File.ReadAllTextAsync(destination)); Assert.Contains(destination, Assert.Single(f.Approval.Actions).Target, StringComparison.Ordinal);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.DownloadAsync(row.Id, "/srv/test/readme", destination, ServerCaller.Person));
    Assert.Equal("sample", await File.ReadAllTextAsync(destination));
  }
  [Fact] public async Task DestinationAppearingDuringDownloadIsKeptAndTemporaryFileIsRemoved()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); var local = f.Path + "/download";
    f.Runtime.Reply = _ =>
    {
      File.WriteAllText(local, "keep existing");
      return new(0, JsonSerializer.Serialize(new { path = "/srv/test/readme", base64 = Convert.ToBase64String("new bytes"u8), truncated = false }));
    };
    await Assert.ThrowsAsync<IOException>(async () => await f.Service.DownloadAsync(row.Id, "/srv/test/readme", local, ServerCaller.Person));
    Assert.Equal("keep existing", File.ReadAllText(local)); Assert.Empty(Directory.GetFiles(f.Path, "*.partial"));
  }
  [Fact] public async Task TransferLimitsRefuseBeforeApproval()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.UploadAsync(row.Id, "/srv/test/large", new byte[ServerFilesScript.TransferLimit + 1], ServerCaller.Person));
    Assert.Empty(f.Approval.Actions); Assert.Empty(f.Runtime.Commands);
  }
  [Fact] public async Task RemoteHelperRoundTripsFilesAndRefusesSymlinksAndOverwrite()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true);
    var allowed = Path.Combine(f.Path, "allowed"); var outside = Path.Combine(f.Path, "outside"); Directory.CreateDirectory(allowed); Directory.CreateDirectory(outside);
    row = row with { Access = row.Access with { Folders = [allowed] } };
    var file = allowed + "/space ' quote.txt";
    Assert.Equal(0, (await RunPythonAsync(ServerFilesScript.Make(row, "upload", file, Convert.ToBase64String("sample"u8)))).ExitCode);
    Assert.NotEqual(0, (await RunPythonAsync(ServerFilesScript.Make(row, "upload", file, Convert.ToBase64String("overwrite"u8)))).ExitCode);
    var read = await RunPythonAsync(ServerFilesScript.Make(row, "read", file));
    Assert.Equal(0, read.ExitCode); using (var doc = JsonDocument.Parse(read.Output)) Assert.Equal("sample", Encoding.UTF8.GetString(Convert.FromBase64String(doc.RootElement.GetProperty("base64").GetString()!)));
    File.WriteAllText(outside + "/private.txt", "sample-outside"); Directory.CreateSymbolicLink(allowed + "/jump", outside); File.CreateSymbolicLink(allowed + "/link", outside + "/private.txt");
    Assert.NotEqual(0, (await RunPythonAsync(ServerFilesScript.Make(row, "read", allowed + "/jump/private.txt"))).ExitCode);
    Assert.NotEqual(0, (await RunPythonAsync(ServerFilesScript.Make(row, "read", allowed + "/link"))).ExitCode);
    var listing = await RunPythonAsync(ServerFilesScript.Make(row, "list", allowed)); Assert.Equal(0, listing.ExitCode); Assert.Contains("\"kind\": \"link\"", listing.Output, StringComparison.Ordinal);
    File.WriteAllText(allowed + "/taken", "keep"); Assert.NotEqual(0, (await RunPythonAsync(ServerFilesScript.Make(row, "rename", file, name: "taken"))).ExitCode);
    Assert.Equal("keep", File.ReadAllText(allowed + "/taken"));
    Assert.Equal(0, (await RunPythonAsync(ServerFilesScript.Make(row, "rename", file, name: "renamed"))).ExitCode);
    Assert.Equal(0, (await RunPythonAsync(ServerFilesScript.Make(row, "delete", allowed + "/renamed"))).ExitCode); Assert.False(File.Exists(allowed + "/renamed"));
  }
  [Fact] public async Task RemotePreviewTruncatesWhileDownloadRefusesOversizedFile()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); row = row with { Access = row.Access with { Folders = [f.Path] } };
    var file = f.Path + "/large.txt"; await File.WriteAllBytesAsync(file, new byte[ServerFilesScript.TransferLimit + 1]);
    var preview = await RunPythonAsync(ServerFilesScript.Make(row, "read", file)); Assert.Equal(0, preview.ExitCode);
    using var json = JsonDocument.Parse(preview.Output); Assert.True(json.RootElement.GetProperty("truncated").GetBoolean());
    Assert.Equal(262144, Convert.FromBase64String(json.RootElement.GetProperty("base64").GetString()!).Length);
    Assert.NotEqual(0, (await RunPythonAsync(ServerFilesScript.Make(row, "download", file))).ExitCode);
  }
  [Fact] public async Task RemoteListingCanReadPastTheFirstThousandWithoutDroppingNames()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); row = row with { Access = row.Access with { Folders = [f.Path] } };
    var folder = Path.Combine(f.Path, "many"); Directory.CreateDirectory(folder);
    for (var n = 0; n < 1003; n++) File.WriteAllText(Path.Combine(folder, $"file-{n:D4}.txt"), "fixture");
    var first = await RunPythonAsync(ServerFilesScript.Make(row, "list", folder));
    var second = await RunPythonAsync(ServerFilesScript.Make(row, "list", folder, offset: 1000));
    Assert.Equal(0, first.ExitCode); Assert.Equal(0, second.ExitCode);
    using var a = JsonDocument.Parse(first.Output); using var b = JsonDocument.Parse(second.Output);
    Assert.True(a.RootElement.GetProperty("more").GetBoolean()); Assert.False(b.RootElement.GetProperty("more").GetBoolean());
    Assert.Equal(1000, b.RootElement.GetProperty("offset").GetInt32());
    var names = a.RootElement.GetProperty("entries").EnumerateArray().Concat(b.RootElement.GetProperty("entries").EnumerateArray()).Select(e => e.GetProperty("name").GetString()).ToArray();
    Assert.Equal(1003, names.Length); Assert.Equal(1003, names.Distinct().Count()); Assert.Contains("file-1002.txt", names);
    Assert.Throws<ServerRefusal>(() => ServerFilesScript.Make(row, "list", folder, offset: -1));
  }
  private static async Task<ServerOutput> RunPythonAsync(ServerCommand command)
  {
    var start = new ProcessStartInfo("/bin/sh") { RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
    start.ArgumentList.Add("-c"); start.ArgumentList.Add(command.Script); using var p = Process.Start(start)!;
    var output = p.StandardOutput.ReadToEndAsync(); var error = p.StandardError.ReadToEndAsync();
    await p.StandardInput.WriteAsync(command.Input); p.StandardInput.Close(); await p.WaitForExitAsync(); _ = await error;
    return new(p.ExitCode, await output);
  }
}
