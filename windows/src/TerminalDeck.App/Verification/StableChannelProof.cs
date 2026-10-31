using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.App.Services;
using TerminalDeck.App.Views;
using TerminalDeck.Core;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Verification;

// Explicitly enabled only by the stable install/update acceptance operation.
internal static class StableChannelProof
{
  internal static async Task RunIfRequestedAsync(ShellWindow window)
  {
    var output = Environment.GetEnvironmentVariable("TD_REAL_CHANNEL_PROOF");
    if (output is null) return;
    if (!StableChannel.IsStable(AppContext.BaseDirectory) || !Path.GetFullPath(output).StartsWith(@"C:\TD\channel-proof\", StringComparison.OrdinalIgnoreCase) || !File.Exists(Path.Combine(output, "allow")))
      throw new IOException("Stable channel proof requires its own marked output directory.");
    try
    {
      await window.Ready;
      var runtime = window.Runtime;
      var root = runtime.Root;
      var test = AppDataRoot.Explicit(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), @"AppData\Local\Packages\TerminalDeck.Pipeline.Dev_s5zx918s088m4\LocalState"));
      var mode = Environment.GetEnvironmentVariable("TD_REAL_CHANNEL_PHASE");
      var before = runtime.General.Read();
      if (mode == "seed") runtime.General.Save(before with { CopyOnSelect = true });
      if (mode == "verify" && !before.CopyOnSelect) throw new IOException("The pre-update setting did not survive.");
      var crossDpapiRejected = false;
      var protectedMarker = new CurrentUserDpapi(root).Protect(Encoding.UTF8.GetBytes("channel-isolation"));
      try { new CurrentUserDpapi(test).Unprotect(protectedMarker); }
      catch (CryptographicException) { crossDpapiRejected = true; }
      var crossCredentialRejected = false;
      try { await new WindowsCredentialStore(root).ReadAsync($"{Brand.Name}/{test.NamespaceId}/channel-proof"); }
      catch (ArgumentException) { crossCredentialRejected = true; }
      var crossKeeperRejected = false;
      using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
      await using (var pipe = await new NamedPipeConnector(test).ConnectAsync(timeout.Token))
      {
        await KeeperWire.WriteAsync(pipe, new KeeperRequest { Secret = Encoding.UTF8.GetString(KeeperCredentials.GetOrCreate(root)), Operation = "hello" }, cancellationToken: timeout.Token);
        try
        {
          var response = await KeeperWire.ReadAsync<KeeperResponse>(pipe, true, timeout.Token);
          crossKeeperRejected = response.Error is not null;
        }
        catch (EndOfStreamException) { crossKeeperRejected = true; }
      }
      var sessions = (await runtime.Keeper.ListAsync()).Sessions?.Count ?? 0;
      var signedIn = runtime.Accounts.List().Count(a => a.SignedIn);
      var projects = runtime.Projects.List().Count(p => p.Id != TerminalDeck.Core.Projects.ProjectIdentity.IndependentId);
      if (!crossDpapiRejected || !crossCredentialRejected || !crossKeeperRejected || sessions != 0 || signedIn != 0 || runtime.Chats.List().Count != 0 || projects != 0 || runtime.Remote.Trust.List().Count != 0)
        throw new IOException($"Stable isolation check: DPAPI={crossDpapiRejected}, credential={crossCredentialRejected}, keeper={crossKeeperRejected}, sessions={sessions}, signedIn={signedIn}, chats={runtime.Chats.List().Count}, customProjects={projects}.");
      using var testConnection = JsonDocument.Parse(File.ReadAllText(Path.Combine(test.DirectoryPath, "mcp", "connection.json")));
      var testMcp = new Uri(testConnection.RootElement.GetProperty("url").GetString()!);
      if (testMcp.Scheme != "http" || testMcp.Host != "127.0.0.1" || testMcp.AbsolutePath != "/mcp" || testMcp == runtime.LocalToolAddress)
        throw new IOException("The two MCP listeners must have separate loopback addresses.");
      var caller = runtime.Door.RegisterCaller(new("stable-channel-proof", null, null, false, AiPermissionMode.Plan,
        [], [], [], DateTimeOffset.UtcNow.AddMinutes(1)), (_, _, _, _, _) => ValueTask.FromResult(false));
      int ownMcpStatus; int crossMcpStatus;
      try
      {
        using var http = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(8) };
        http.DefaultRequestHeaders.Authorization = new("Bearer", caller.Token);
        const string initialize = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"stable-channel-proof","version":"1"}}}""";
        using var ownReply = await http.PostAsync(runtime.LocalToolAddress, new System.Net.Http.StringContent(initialize, Encoding.UTF8, "application/json"));
        using var testReply = await http.PostAsync(testMcp, new System.Net.Http.StringContent(initialize, Encoding.UTF8, "application/json"));
        ownMcpStatus = (int)ownReply.StatusCode; crossMcpStatus = (int)testReply.StatusCode;
        if (ownMcpStatus != 200 || crossMcpStatus != 401) throw new IOException("MCP channel authentication did not stay separate.");
      }
      finally { runtime.Door.Revoke(caller.Id); }
      var hello = await runtime.Keeper.HelloAsync();
      var relayFingerprint = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(runtime.Remote.McpAddress ?? throw new IOException("Relay identity missing"))));
      var source = Windows.ApplicationModel.Package.Current.GetAppInstallerInfo()?.Uri.AbsoluteUri;
      var update = await WindowsUpdateStatus.CheckAsync();
      if (mode == "clean") runtime.General.Save(before with { CopyOnSelect = false });
      File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new {
        ok = true, mode, version = WindowsUpdateStatus.Version(), source, update,
        root = root.DirectoryPath, namespaceId = root.NamespaceId, testNamespaceId = test.NamespaceId,
        keeperInstance = hello.Instance, mcp = runtime.LocalToolAddress?.AbsoluteUri, relayFingerprint,
        sessions, chats = runtime.Chats.List().Count, signedIn, accounts = runtime.Accounts.List().Count,
        projects, independentProject = runtime.Projects.List().Any(p => p.Id == TerminalDeck.Core.Projects.ProjectIdentity.IndependentId), pairedDevices = runtime.Remote.Trust.List().Count,
        settingBefore = before.CopyOnSelect, settingAfter = runtime.General.Read().CopyOnSelect,
        crossDpapiRejected, crossCredentialRejected, crossKeeperRejected, ownMcpStatus, crossMcpStatus, testMcp = testMcp.AbsoluteUri,
        at = DateTimeOffset.UtcNow
      }, new JsonSerializerOptions { WriteIndented = true }));
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { ok = false, error = ex.ToString(), at = DateTimeOffset.UtcNow }));
    }
    finally { window.Close(); }
  }
}
