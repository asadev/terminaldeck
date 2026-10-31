using System.Text.Json;
using Microsoft.UI.Xaml;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Browser;

namespace TerminalDeck.App.Verification;

internal static class IntegrationProof
{
  public static async Task RunAsync(ShellWindow window, string directory)
  {
    Directory.CreateDirectory(directory);
    var passed = new List<string>(); var failed = new List<string>();
    void Check(string name, bool value)
    {
      (value ? passed : failed).Add(name);
      File.WriteAllText(Path.Combine(directory, "checkpoint.json"), JsonSerializer.Serialize(new { passed, failed, passCount = passed.Count, failCount = failed.Count }));
    }
    var phase = Environment.GetEnvironmentVariable("TD_INTEGRATION_PHASE") ?? "create";
    try
    {
      await window.Ready.WaitAsync(TimeSpan.FromSeconds(30));
      window.SetTheme(ElementTheme.Dark);
      var runtime = window.Runtime;
      if (phase == "create")
      {
        var session = await runtime.StartAsync("shell", runtime.Root.DirectoryPath, title: "W4 PowerShell");
        window.Model.Sync(runtime.Sessions); window.Model.Selected = window.Model.Sessions.Single(s => s.Id == session.Definition.Id); window.Model.Page = ShellPage.Sessions;
        await window.WaitForTerminalsAsync().WaitAsync(TimeSpan.FromSeconds(30));
        await window.SelectedPane.InputForProofAsync("Write-Output 'W4_POWERSHELL_MARKER'");
        await UntilAsync(async () => (await runtime.Keeper.ListAsync()).Sessions!.Single(s => s.Definition.Id == session.Definition.Id).Replay.Contains("W4_POWERSHELL_MARKER", StringComparison.Ordinal));
        // Wait for the command's output as well as its echoed input.
        await UntilAsync(async () => (await runtime.Keeper.ListAsync()).Sessions!.Single(s => s.Definition.Id == session.Definition.Id).Replay.Split("W4_POWERSHELL_MARKER", StringSplitOptions.None).Length >= 3);
        Check("PowerShell marker typed through xterm and WebView bridge", true);
        await SnapshotAsync(directory, "01-powershell");
      }
      else if (phase is "restart" or "recovery")
      {
        var session = runtime.Sessions.Single(s => s.Definition.Title == "W4 PowerShell");
        window.Model.Selected = window.Model.Sessions.Single(s => s.Id == session.Definition.Id); window.Model.Page = ShellPage.Sessions;
        await window.WaitForTerminalsAsync().WaitAsync(TimeSpan.FromSeconds(30));
        if (phase == "restart")
        {
          Check("App restart restores keeper session and marker", session.Replay.Contains("W4_POWERSHELL_MARKER", StringComparison.Ordinal));
          await SnapshotAsync(directory, "02-app-restart");
        }
        await File.WriteAllTextAsync(Path.Combine(directory, "kill-keeper.request"), "ready");
        await UntilAsync(() => Task.FromResult(File.Exists(Path.Combine(directory, "kill-keeper.ack"))));
        await UntilAsync(async () => { try { await runtime.RefreshSessionsAsync(); return runtime.Sessions.Single(s => s.Definition.Id == session.Definition.Id).Replay.Contains("W4_POWERSHELL_MARKER", StringComparison.Ordinal); } catch (Exception ex) when (ex is IOException or TimeoutException) { return false; } });
        await window.SelectedPane.InputForProofAsync("Write-Output 'W4_AFTER_KEEPER_RESTART'");
        await UntilAsync(async () => (await runtime.Keeper.ListAsync()).Sessions!.Single(s => s.Definition.Id == session.Definition.Id).Replay.Split("W4_AFTER_KEEPER_RESTART", StringSplitOptions.None).Length >= 3);
        Check("Keeper restart preserves old output and accepts fresh terminal input", true);
        await SnapshotAsync(directory, "03-keeper-restart");
        window.Model.Split = SplitPresentation.Browser;
        await window.Browser.Ready.WaitAsync(TimeSpan.FromSeconds(45));
        await window.Browser.NavigateForProofAsync("https://example.com");
        Check("Real browser opens example.com", (await window.Browser.EvaluateForProofAsync("document.title")).GetProperty("result").GetProperty("value").GetString() == "Example Domain");
        await window.Browser.EvaluateForProofAsync("window.w4Retained='same-document'");
        window.Model.Page = ShellPage.Settings; window.Model.Page = ShellPage.Sessions;
        Check("Switch away and back retains the same browser document", (await window.Browser.EvaluateForProofAsync("window.w4Retained")).GetProperty("result").GetProperty("value").GetString() == "same-document");
        await SnapshotAsync(directory, "04-split-browser");
        await window.Browser.ExecuteAsync("size", "390x844");
        Check("Size changes the real viewport", (await window.Browser.EvaluateForProofAsync("innerWidth")).GetProperty("result").GetProperty("value").GetInt32() == 390);
        await window.Browser.ExecuteAsync("inspect");
        Check("Inspect command reaches WebView2", true);
        await SnapshotAsync(directory, "05-browser-size-inspect");
        window.Model.Page = ShellPage.Settings; window.Settings.SelectSection(0); await window.Settings.RenderAsync();
        Check("All three AIs are signed out in Core", runtime.Accounts.List().Count == 3 && runtime.Accounts.List().All(a => !a.SignedIn));
        await SnapshotAsync(directory, "06-coding-ais");
        var sheet = window.ShowAccountAsync(); await SnapshotAsync(directory, "07-accounts"); window.DismissAccountSheet(); await sheet;
        if ((await runtime.Mcp.ListAsync()).Count == 0) await runtime.Mcp.AddAsync(new() { Name = "w4-configured", Scope = "user", Transport = "http", Url = "http://127.0.0.1:1/mcp" });
        window.Settings.SelectSection(3); await window.Settings.RenderAsync();
        Check("MCP Settings lists the real saved configuration", (await runtime.Mcp.ListAsync()).Any(s => s.Name == "w4-configured"));
        await SnapshotAsync(directory, "08-mcp-servers");
        window.Settings.SelectSection(2); await window.Settings.ShowCodeAsync();
        Check("Devices generates a real six-digit pairing window", runtime.Remote.Trust.Pairing.IsOpen && window.Settings.ActiveCode?.Length == 6);
        // Credentials stay in the private scratch folder, never test logs/results.
        await File.WriteAllTextAsync(Path.Combine(directory, "pair-code.txt"), window.Settings.ActiveCode);
        await File.WriteAllTextAsync(Path.Combine(directory, "phone-ready"), "ready");
      }
      if (phase == "w4b")
      {
        var session = runtime.Sessions.Single(s => s.Definition.Title == "W4 PowerShell");
        window.Model.Selected = window.Model.Sessions.Single(s => s.Id == session.Definition.Id); window.Model.Page = ShellPage.Sessions;
        await window.WaitForTerminalsAsync().WaitAsync(TimeSpan.FromSeconds(30));
        Check("Main app restart restores the live session and marker", session.Replay.Contains("W4_POWERSHELL_MARKER", StringComparison.Ordinal));
        await SnapshotAsync(directory, "02-app-restart");
        await File.WriteAllTextAsync(Path.Combine(directory, "kill-keeper.request"), "ready");
        await UntilAsync(() => Task.FromResult(File.Exists(Path.Combine(directory, "kill-keeper.ack"))));
        await runtime.ReconnectAsync(); await runtime.RefreshSessionsAsync();
        await window.SelectedPane.InputForProofAsync("Write-Output 'W4B_MAIN_AFTER_KEEPER_RESTART'");
        await UntilAsync(async () => (await runtime.Keeper.ListAsync()).Sessions!.Single(s => s.Definition.Id == session.Definition.Id).Replay.Split("W4B_MAIN_AFTER_KEEPER_RESTART", StringSplitOptions.None).Length >= 3);
        Check("Main keeper restart preserves output and accepts fresh input", runtime.Sessions.Single(s => s.Definition.Id == session.Definition.Id).Replay.Contains("W4_POWERSHELL_MARKER", StringComparison.Ordinal));
        await SnapshotAsync(directory, "03-keeper-restart");
        window.Model.Split = SplitPresentation.Browser;
        await window.Browser.Ready.WaitAsync(TimeSpan.FromSeconds(45));
        await window.Browser.NavigateForProofAsync("https://example.com");
        Check("Main browser loads example.com", (await window.Browser.EvaluateForProofAsync("document.title")).GetProperty("result").GetProperty("value").GetString() == "Example Domain");
        await window.Browser.EvaluateForProofAsync("window.w4bRetained='same-document'");
        window.Model.Page = ShellPage.Settings; window.Model.Page = ShellPage.Sessions;
        Check("Main browser keeps its document when changing views", (await window.Browser.EvaluateForProofAsync("window.w4bRetained")).GetProperty("result").GetProperty("value").GetString() == "same-document");
        await SnapshotAsync(directory, "04-split-browser");
        await window.Browser.ExecuteAsync("size", "390x844");
        Check("Main Size changes the real viewport", (await window.Browser.EvaluateForProofAsync("innerWidth")).GetProperty("result").GetProperty("value").GetInt32() == 390);
        var tab = window.Browser.Core.Read().Tabs.Single(t => t.Id == window.Browser.Core.Read().SelectedTabId);
        // Controlled fixture elements exercise fixed operations without an AI call.
        await window.Browser.EvaluateForProofAsync("document.body.insertAdjacentHTML('beforeend','<input id=td-w4b-entry><input type=password id=td-w4b-private value=fixture><button id=td-w4b-button>Fixture action</button>')");
        await window.Browser.Core.PerformAsync(tab.Id, BrowserPageAction.Record, JsonSerializer.SerializeToElement(new { on = true }));
        await window.Browser.Core.PerformAsync(tab.Id, BrowserPageAction.Step, JsonSerializer.SerializeToElement(new { verb = "type", selector = "#td-w4b-entry", value = "typed fixture" }));
        Check("Main fixed browser input reaches the real page", (await window.Browser.EvaluateForProofAsync("document.querySelector('#td-w4b-entry').value")).GetProperty("result").GetProperty("value").GetString() == "typed fixture");
        var recorded = await window.Browser.Core.PerformAsync(tab.Id, BrowserPageAction.Recording, JsonSerializer.SerializeToElement(new { }));
        Check("Main Record keeps steps and omits typed values", recorded.GetProperty("steps").GetArrayLength() > 0 && !recorded.GetRawText().Contains("typed fixture", StringComparison.Ordinal));
        await window.Browser.Core.PerformAsync(tab.Id, BrowserPageAction.Record, JsonSerializer.SerializeToElement(new { on = false }));
        var caller = runtime.Door.RegisterCaller(new("w4b-browser-read", null, null, true, AiPermissionMode.Ask, ["browser.read", "browser.screenshot", "browser.page", "mcp.remote"], [McpTier.Read], ["browser:" + tab.Id, "profiles:" + tab.ProfileId, "origins:https://example.com", "settings:mcp"], DateTimeOffset.UtcNow.AddMinutes(2), true), (_, _, _, _, _) => ValueTask.FromResult(true));
        try
        {
          var read = await runtime.Door.CallAsync(caller.Id, "browser.read", JsonSerializer.SerializeToElement(new { window = tab.Id }));
          Check("Main MCP browser read returns page text with form values omitted", read.GetProperty("title").GetString() == "Example Domain" && read.GetProperty("text").GetString()!.Length > 0 && !read.GetRawText().Contains("typed fixture", StringComparison.Ordinal));
          var shot = await runtime.Door.CallAsync(caller.Id, "browser.screenshot", JsonSerializer.SerializeToElement(new { window = tab.Id }));
          await File.WriteAllBytesAsync(Path.Combine(directory, "browser-masked.png"), Convert.FromBase64String(shot.GetProperty("data").GetString()!));
          Check("Main MCP screenshot captures a masked real WebView", shot.GetProperty("privateFieldsHidden").GetBoolean());
          var page = await runtime.Door.CallAsync(caller.Id, "browser.page", JsonSerializer.SerializeToElement(new { window = tab.Id, action = "state" }));
          Check("Main MCP page resolves the same retained browser tab", page.GetProperty("Id").GetString() == tab.Id);
          var access = await runtime.Door.CallAsync(caller.Id, "mcp.remote", JsonSerializer.SerializeToElement(new { }));
          Check("Remote MCP is off until the person enables it", !access.GetProperty("enabled").GetBoolean());
        }
        finally { runtime.Door.Revoke(caller.Id); }
        await SnapshotAsync(directory, "05-browser-driver");
        window.Model.Page = ShellPage.Settings; window.Settings.SelectSection(0); await window.Settings.RenderAsync();
        Check("Main has three signed-out AI rows", runtime.Accounts.List().Count == 3 && runtime.Accounts.List().All(a => !a.SignedIn));
        await SnapshotAsync(directory, "06-coding-ais");
        if ((await runtime.Mcp.ListAsync()).Count == 0) await runtime.Mcp.AddAsync(new() { Name = "w4b-configured", Scope = "user", Transport = "http", Url = "http://127.0.0.1:1/mcp" });
        window.Settings.SelectSection(3); await window.Settings.RenderAsync();
        Check("Main MCP page lists the saved server", (await runtime.Mcp.ListAsync()).Any(s => s.Name == "w4b-configured"));
        await SnapshotAsync(directory, "08-mcp-servers");
        window.Settings.SelectSection(2); await window.Settings.ShowCodeAsync();
        Check("Main Devices creates a six-digit pairing offer", runtime.Remote.Trust.Pairing.IsOpen && window.Settings.ActiveCode?.Length == 6);
        // The code stays in the private scratch state. Expire it before capture.
        runtime.Remote.Trust.Pairing.Cancel(); window.Settings.ActiveCodeForProofClear(); await window.Settings.RenderAsync();
        await SnapshotAsync(directory, "09-devices");
        await runtime.SetRemoteToolsAsync(true);
        await File.WriteAllTextAsync(Path.Combine(directory, "remote-ready"), "ready");
        await UntilAsync(() => Task.FromResult(File.Exists(Path.Combine(directory, "remote-finish"))));
        await runtime.SetRemoteToolsAsync(false);
        Check("Main remote-tools grant can be enabled and revoked", !runtime.RemoteToolsEnabled && !File.Exists(Path.Combine(runtime.Root.DirectoryPath, "mcp", "remote-connection.json")));
      }
      if (phase == "browser-read")
      {
        window.Model.Page = ShellPage.Browser; await window.Browser.Ready.WaitAsync(TimeSpan.FromSeconds(45));
        await window.Browser.NavigateForProofAsync("https://example.com");
        await window.Browser.EvaluateForProofAsync("document.body.insertAdjacentHTML('beforeend','<h2>W4b public fixture</h2><input value=PRIVATE_FIXTURE_VALUE><textarea>PRIVATE_FIXTURE_VALUE</textarea>')");
        var tab = window.Browser.Core.Read().Tabs.Single(t => t.Id == window.Browser.Core.Read().SelectedTabId);
        var caller = runtime.Door.RegisterCaller(new("w4b-corrected-page-read", null, null, true, AiPermissionMode.Ask, ["browser.read"], [McpTier.Read], ["browser:" + tab.Id, "profiles:" + tab.ProfileId, "origins:https://example.com"], DateTimeOffset.UtcNow.AddMinutes(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
        try
        {
          var read = await runtime.Door.CallAsync(caller.Id, "browser.read", JsonSerializer.SerializeToElement(new { window = tab.Id }));
          Check("Main MCP browser read returns page text with form values omitted", read.GetProperty("text").GetString()!.Contains("W4b public fixture", StringComparison.Ordinal) && !read.GetRawText().Contains("PRIVATE_FIXTURE_VALUE", StringComparison.Ordinal));
          await File.WriteAllTextAsync(Path.Combine(directory, "browser-read.json"), read.GetRawText());
        }
        finally { runtime.Door.Revoke(caller.Id); }
        await SnapshotAsync(directory, "14-browser-read");
      }
      if (phase == "account-add")
      {
        window.Model.Page = ShellPage.Settings; window.Settings.SelectSection(0); await window.Settings.RenderAsync();
        var sheet = window.Settings.ShowAddAccountAsync();
        await SnapshotAsync(directory, "15-add-account");
        Check("Main account settings opens the add-account sheet", window.Settings.AddAccountDialogForProof is not null);
        window.Settings.AddAccountDialogForProof?.Hide(); await sheet;
        Check("Cancelling add-account preserves the three signed-out accounts", runtime.Accounts.List().Count == 3 && runtime.Accounts.List().All(a => !a.SignedIn));
      }
      if (phase == "inspect")
      {
        window.Model.Page = ShellPage.Browser;
        await window.Browser.Ready.WaitAsync(TimeSpan.FromSeconds(45));
        await window.Browser.ExecuteAsync("inspect");
        await SnapshotAsync(directory, "13-inspector-window");
        Check("Inspector has its own visible developer-tools window", true);
      }
      if (phase == "cleanup")
      {
        foreach (var session in runtime.Sessions.Where(s => s.Definition.Title == "W4 PowerShell" && s.State != TerminalDeck.Core.Sessions.SessionState.Exited)) await runtime.StopAsync(session.Definition.Id);
        foreach (var device in runtime.Remote.Trust.List()) runtime.Remote.Trust.Revoke(device.Id);
        Check("Owned proof session stopped and test phone revoked", runtime.Sessions.All(s => s.Definition.Title != "W4 PowerShell" || s.State == TerminalDeck.Core.Sessions.SessionState.Exited) && runtime.Remote.Trust.List().Count == 0);
      }
      if (phase == "delta")
      {
        window.Model.Page = ShellPage.Settings; window.Settings.SelectSection(0); await window.Settings.RenderAsync();
        var caller = runtime.Door.RegisterCaller(new("w4-workspace-read", null, null, true, AiPermissionMode.Ask, ["ui.workspace"], [McpTier.Read], ["settings:workspace"], DateTimeOffset.UtcNow.AddMinutes(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
        var workspace = await runtime.Door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { }));
        Check("MCP workspace reads the actual Settings selection", workspace.GetProperty("settings").GetString() == "Coding AIs");
        runtime.Door.Revoke(caller.Id);
        await SnapshotAsync(directory, "12-final-coding-ais");
      }
      if (phase == "settings")
      {
        window.Model.Page = ShellPage.Settings; window.Settings.SelectSection(3); await window.Settings.RenderAsync();
        await SnapshotAsync(directory, "08-mcp-servers");
        window.Settings.SelectSection(2); await window.Settings.ShowCodeAsync();
        Check("Devices generates a real six-digit pairing window", runtime.Remote.Trust.Pairing.IsOpen && window.Settings.ActiveCode?.Length == 6);
        await File.WriteAllTextAsync(Path.Combine(directory, "pair-code.txt"), window.Settings.ActiveCode);
        await File.WriteAllTextAsync(Path.Combine(directory, "phone-ready"), "ready");
      }
      if (phase is "restart" or "recovery" or "settings")
      {
        // A bounded proof control loop coordinates adb with this desktop process.
        // Product state is event-driven; this is not a product polling service.
        var until = DateTimeOffset.UtcNow.AddMinutes(30);
        while (!File.Exists(Path.Combine(directory, "phone-finish")) && DateTimeOffset.UtcNow < until)
        {
          if (File.Exists(Path.Combine(directory, "new-code.request")))
          {
            File.Delete(Path.Combine(directory, "new-code.request")); await window.Settings.ShowCodeAsync();
            await File.WriteAllTextAsync(Path.Combine(directory, "pair-code.txt"), window.Settings.ActiveCode);
          }
          if (File.Exists(Path.Combine(directory, "approve.request")))
          {
            File.Delete(Path.Combine(directory, "approve.request"));
            foreach (var pending in runtime.Remote.Trust.Pending()) runtime.Remote.Approve(pending.Id);
            await window.Settings.RenderAsync();
            await File.WriteAllTextAsync(Path.Combine(directory, "approved.ack"), "approved");
          }
          await Task.Delay(250);
        }
        runtime.Remote.Trust.Pairing.Cancel(); window.Settings.ActiveCodeForProofClear(); await window.Settings.RenderAsync();
        await SnapshotAsync(directory, "09-devices");
        if (File.Exists(Path.Combine(directory, "pair-code.txt"))) File.Delete(Path.Combine(directory, "pair-code.txt"));
      }
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      failed.Add("Proof stopped: " + ex.GetType().Name);
      await File.WriteAllTextAsync(Path.Combine(directory, "failure-location.txt"), ex.StackTrace ?? "No stack");
    }
    await File.WriteAllTextAsync(Path.Combine(directory, "result.json"), JsonSerializer.Serialize(new { phase, passed, failed, passCount = passed.Count, failCount = failed.Count, timestamp = DateTimeOffset.UtcNow }));
  }
  private static async Task UntilAsync(Func<Task<bool>> predicate)
  {
    var until = DateTimeOffset.UtcNow.AddSeconds(45);
    while (DateTimeOffset.UtcNow < until) { if (await predicate()) return; await Task.Delay(200); }
    throw new TimeoutException("The focused check timed out.");
  }
  private static async Task SnapshotAsync(string directory, string name)
  {
    await Task.Delay(500); await File.WriteAllTextAsync(Path.Combine(directory, "stage.json"), JsonSerializer.Serialize(new { name }));
    await UntilAsync(() => Task.FromResult(File.Exists(Path.Combine(directory, name + ".ack"))));
  }
}
