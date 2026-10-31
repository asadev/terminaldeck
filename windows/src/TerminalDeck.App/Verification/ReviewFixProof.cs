using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;
using TerminalDeck.Platform.Windows.Chats;

namespace TerminalDeck.App.Verification;

// Opt-in, scratch-only checks of the production composition. No sign-in,
// package registration, provider request or shared-process kill is performed.
internal static class ReviewFixProof
{
  public static async Task RunAsync(ShellWindow window, string directory, string phase)
  {
    var passed = new List<string>(); var failed = new List<string>();
    void Check(string name, bool value) { (value ? passed : failed).Add(name); }
    try
    {
      await window.Ready.WaitAsync(TimeSpan.FromSeconds(50));
      if (phase == "review-authority") await Authority(window, directory, Check);
      else if (phase == "review-browser") await Browser(window, directory, Check);
      else if (phase == "review-ui") await Ui(window, directory, Check);
      else if (phase.StartsWith("review-redirect", StringComparison.Ordinal)) await Redirect(window, directory, Check);
      else if (phase == "review-chat") await Chat(window, directory, Check);
      else if (phase == "review-crash") await Crash(window, directory, Check);
      else if (phase == "review-cleanup")
      {
        foreach (var row in window.Runtime.Sessions.Where(s => s.LeaseIdentity is not null || s.State != SessionState.Exited)) await window.Runtime.StopAsync(row.Definition.Id);
        foreach (var chat in window.Runtime.Chats.List().Where(c => !c.Ended)) await window.Runtime.Chats.EndAsync(chat.Definition.Id);
        foreach (var root in new[] { window.Runtime.Root, AppDataRoot.Explicit(Path.Combine(window.Runtime.Root.DirectoryPath, "review-chat")) })
          foreach (var suffix in new[] { "keeper/auth-v2", "remote-host", "remote-identity" })
            await new WindowsCredentialStore(root).DeleteAsync(TerminalDeck.Core.Brand.Name + "/" + root.NamespaceId + "/" + suffix);
        Check("Owned scratch sessions are ended and scoped vault entries removed", window.Runtime.Chats.List().All(c => c.Ended) && window.Runtime.Sessions.All(s => s.State == SessionState.Exited));
      }
      else throw new ArgumentException("Choose a review proof phase.");
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { failed.Add("Walk stopped: " + ex.GetType().Name + " · " + ex.Message); }
    await File.WriteAllTextAsync(Path.Combine(directory, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, phase, passed, failed, passCount = passed.Count, failCount = failed.Count }));
  }

  private static async Task Authority(ShellWindow window, string directory, Action<string, bool> check)
  {
    var runtime = window.Runtime; var folder = runtime.Root.DirectoryPath;
    var mine = await runtime.StartAsync("shell", folder, title: "Review · caller target");
    var other = await runtime.StartAsync("shell", folder, title: "Review · outside grant");
    window.OpenSession(mine.Definition.Id); await window.WaitForTerminalsAsync();
    using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
    try
    {
      foreach (var mode in new[] { AiPermissionMode.Ask, AiPermissionMode.Plan, AiPermissionMode.Bypass })
      {
        var key = runtime.ConnectCaller("Synthetic " + mode, mine.Definition.Id, mode, []);
        async Task<bool> Call(string method, object arguments, int id)
        {
          using var request = new HttpRequestMessage(HttpMethod.Post, runtime.LocalToolAddress);
          request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key.Token);
          request.Content = new StringContent(JsonSerializer.Serialize(new { jsonrpc = "2.0", id, method, @params = arguments }), Encoding.UTF8, "application/json");
          using var reply = await http.SendAsync(request); using var content = JsonDocument.Parse(await reply.Content.ReadAsByteArrayAsync());
          if (method == "initialize") return reply.IsSuccessStatusCode && content.RootElement.TryGetProperty("result", out _);
          return content.RootElement.TryGetProperty("result", out var result) && !result.GetProperty("isError").GetBoolean();
        }
        check(mode + " caller authenticates through the real HTTP listener", await Call("initialize", new { protocolVersion = McpHttpEndpoint.Versions[^1] }, 1));
        var changed = await Call("tools/call", new { name = "sessions_rename", arguments = new { sessionId = mine.Definition.Id, title = "Review · " + mode } }, 2);
        check(mode + " uses its own permission mode without a second app card", changed == (mode != AiPermissionMode.Plan) && window.ToolApprovalForProof is null);
        check(mode + " refuses a conversation outside its grant", !await Call("tools/call", new { name = "sessions_rename", arguments = new { sessionId = other.Definition.Id, title = "must remain unchanged" } }, 3));
        check(mode + " outside app cannot manage browser profiles", !await Call("tools/call", new { name = "browser_profiles", arguments = new { action = "create", name = "must not exist" } }, 4));
        var policy = runtime.CallerAuthority.List().Single(p => p.SessionId == mine.Definition.Id && p.Mode == mode);
        runtime.RevokeCaller(policy.CallerId);
      }
      window.Model.Page = ShellPage.Settings; window.Settings.SelectSection(3); await window.Settings.RenderAsync();
      await Snapshot(directory, "fix-01-scoped-ai-connections");
    }
    finally { await runtime.StopAsync(mine.Definition.Id); await runtime.StopAsync(other.Definition.Id); }
  }

  private static async Task Browser(ShellWindow window, string directory, Action<string, bool> check)
  {
    await using var destination = new Fixture(); await using var source = new Fixture(destination.Origin);
    window.Model.Page = ShellPage.Browser; await window.Browser.Ready.WaitAsync(TimeSpan.FromSeconds(50));
    try
    {
      await window.Browser.NavigateForProofAsync(source.Origin + "/"); var original = window.Browser.Core.Read().SelectedTabId!;
      var count = window.Browser.TabCount;
      await window.Browser.Core.PerformAsync(original, BrowserPageAction.Step, J(new { verb = "click", selector = "#same" }));
      await Until(() => window.Browser.TabCount == count + 1 && window.Browser.Core.Read().SelectedTabId != original);
      var popup = window.Browser.Core.Read().Tabs.Single(t => t.Id != original && t.AutomationOrigin == source.Origin);
      check("Same-origin popup inherits the pin and cookie profile", popup.AutomationOrigin == source.Origin && popup.ProfileId == window.Browser.Core.Get(original).ProfileId);
      await window.Browser.Core.CloseAsync(popup.Id); await window.Browser.Core.SelectAsync(original);
      await window.Browser.Core.PerformAsync(original, BrowserPageAction.Step, J(new { verb = "click", selector = "#other" }));
      await Task.Delay(600);
      check("Cross-origin popup is refused before requesting the other origin", window.Browser.TabCount == count && destination.Requests == 0);
      await window.Browser.Core.PerformAsync(original, BrowserPageAction.Step, J(new { verb = "click", selector = "#redirect" }));
      await Until(() => source.Redirects > 0); await Task.Delay(700);
      check("Popup redirect cannot leave its inherited origin or retain a phantom tab", window.Browser.TabCount == count && window.Browser.Core.Read().Tabs.Length == count && destination.Requests == 0);
      await Snapshot(directory, "fix-02-popup-origin-boundary");
      await window.Browser.EvaluateForProofAsync("document.title='Fixture title'+String.fromCharCode(13,27,155);const p=document.createElement('p');p.textContent='Fixture selection'+String.fromCharCode(13,27,0,8232);document.body.append(p);const r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r)");
      var account = window.Runtime.Accounts.List("claude").First();
      var chat = await window.Runtime.Chats.CreateAsync("claude", window.Runtime.Root.DirectoryPath, account.Id);
      await Until(() => window.Model.Sessions.Any(s => s.Id == chat.Definition.Id));
      var sending = window.Browser.ExecuteAsync("send"); await Until(() => window.BrowserContextDialogForProof is not null);
      var dialog = window.BrowserContextDialogForProof!;
      var draft = Descendants(dialog).OfType<TextBox>().Single(t => t.Header is string text && text.StartsWith("Review the message", StringComparison.Ordinal));
      check("CR/ESC webpage title and selection become a reviewable untrusted draft", draft.Text.Contains("Untrusted webpage data", StringComparison.Ordinal) && !draft.Text.Any(char.IsControl));
      await Snapshot(directory, "fix-03-review-page-context"); draft.Text += "\r\u001b[201~";
      Invoke(Descendants(dialog).OfType<Button>().Single(b => b.Content as string == "Send")); await sending;
      await window.Runtime.Chats.RefreshAsync(); var message = window.Runtime.Chats.Get(chat.Definition.Id).Messages.Single();
      check("Even an edited draft cannot send terminal framing bytes", !message.Text.Any(char.IsControl) && message.Text.Contains("Fixture selection", StringComparison.Ordinal));
      await window.Runtime.Chats.EndAsync(chat.Definition.Id);
    }
    finally { foreach (var tab in window.Browser.Core.Read().Tabs) await window.Browser.Core.CloseAsync(tab.Id); }
  }

  private static async Task Ui(ShellWindow window, string directory, Action<string, bool> check)
  {
    // This check starts with the browser unopened. A scoped browser call needs
    // its session/profile/origin grants, without unrelated workspace-admin access.
    await using var fixture = new Fixture();
    var account = window.Runtime.Accounts.List("claude").First();
    var chat = await window.Runtime.Chats.CreateAsync("claude", window.Runtime.Root.DirectoryPath, account.Id);
    var key = window.Runtime.ConnectCaller("Scoped browser fixture", chat.Definition.Id, AiPermissionMode.Ask, [fixture.Origin]);
    var policy = window.Runtime.CallerAuthority.List().Single(p => p.SessionId == chat.Definition.Id);
    try
    {
      await window.Runtime.Door.CallAsync(key.Id, "browser.open", J(new { url = fixture.Origin + "/", sessionId = chat.Definition.Id, newWindow = true }));
      var tab = window.Browser.Core.Read().Tabs.Single(t => t.SessionId == chat.Definition.Id);
      var read = await window.Runtime.Door.CallAsync(key.Id, "browser.read", J(new { sessionId = chat.Definition.Id }));
      check("Scoped chat caller opens and reads its browser through the real dispatcher", tab.SessionId == chat.Definition.Id && read.GetProperty("untrusted").GetBoolean());
      await Snapshot(directory, "fix-10-scoped-chat-browser-tools");
    }
    finally
    {
      window.Runtime.RevokeCaller(policy.CallerId); await window.Runtime.Chats.EndAsync(chat.Definition.Id);
      foreach (var tab in window.Browser.Core.Read().Tabs) await window.Browser.Core.CloseAsync(tab.Id);
    }
    var folder = Path.Combine(Directory.GetParent(window.Runtime.Root.DirectoryPath)!.FullName, "review-ui-project"); Directory.CreateDirectory(folder);
    var project = window.Runtime.Projects.Create("Review UI project", folder);
    var agent = window.Runtime.Agents.Save(new("review-ui-agent", "Review UI agent", "gemini", "Synthetic UI review; no work is launched", ProjectId: project.Id, Seat: "review-ui"));
    window.SetTheme(ElementTheme.Light); window.OpenAgent(agent.Id); await Task.Delay(250);
    var buttons = Descendants(window.Agents).OfType<Button>().ToArray();
    check("Agent page has one new-session entry and one complete editor", buttons.Count(b => b.Content as string == "New session") == 1 && !buttons.Any(b => b.Content as string == "New chat") && buttons.Count(b => b.Content as string == "Agent settings") == 1);
    await Snapshot(directory, "fix-11-agent-options-light");
    window.SetTheme(ElementTheme.Dark); await Snapshot(directory, "fix-12-agent-options-dark");
    window.Model.Page = ShellPage.Projects; window.Projects.OpenProject(project.Id, "Settings");
    check("Project settings do not offer unavailable task execution defaults", !Descendants(window.Projects).OfType<ComboBox>().Any(c => c.Header is string header && header.StartsWith("Tasks", StringComparison.Ordinal)));
    await Snapshot(directory, "fix-13-project-defaults");
    window.OpenAgent(AgentSeats.HootId); await Snapshot(directory, "fix-14-hoot-unavailable");
    var root = AppDataRoot.Explicit(Path.Combine(window.Runtime.Root.DirectoryPath, "review-chat"));
    var accounts = new AccountService(new JsonStateStore<AccountState>(root, "accounts"), [new SyntheticAccount()]); var fake = accounts.List().First();
    var processes = new WindowsChatProcessKeeper(root, window.Runtime.KeeperExecutable, Path.Combine(root.DirectoryPath, "tools"), KeeperCredentials.GetOrCreate(root));
    await using var core = new ChatSessions(new ChatHistory(root), processes, accounts);
    var empty = await core.CreateAsync("claude", root.DirectoryPath, fake.Id); var page = new ChatPage(core, empty.Definition.Id, window.WindowHandle); window.ShowProofChat(page);
    try
    {
      Invoke(Descendants(page).OfType<Button>().Single(b => b.Content is TextBlock text && text.Text.StartsWith("Choose model", StringComparison.Ordinal)));
      await Until(() => page.ModelMenuForProof?.Items.OfType<MenuFlyoutItem>().Any(item => item.Text.Contains("Models unavailable", StringComparison.Ordinal)) == true);
      check("Empty model list explains its unavailable state", page.ModelMenuForProof!.Items.OfType<MenuFlyoutItem>().Any(item => item.Text.Contains("Coding AIs", StringComparison.Ordinal)));
      await Snapshot(directory, "fix-15-model-choices-unavailable"); page.ModelMenuForProof!.Hide();
      await core.EndAsync(empty.Definition.Id);
    }
    finally { window.HideProofChat(); await page.DisposeAsync(); }
  }
  private static async Task Redirect(ShellWindow window, string directory, Action<string, bool> check)
  {
    await using var destination = new Fixture(); await using var source = new Fixture(destination.Origin);
    window.Model.Page = ShellPage.Browser; await window.Browser.Ready.WaitAsync(TimeSpan.FromSeconds(50));
    try
    {
      await window.Browser.NavigateForProofAsync(source.Origin + "/");
      var original = window.Browser.Core.Read().SelectedTabId!; var count = window.Browser.TabCount;
      await window.Browser.Core.PerformAsync(original, BrowserPageAction.Step, J(new { verb = "click", selector = "#redirect" }));
      await Until(() => source.Redirects > 0);
      await Until(() => window.Browser.TabCount == count && window.Browser.Core.Read().Tabs.Length == count);
      await File.WriteAllTextAsync(Path.Combine(directory, "redirect-details.json"), JsonSerializer.Serialize(new { sourceRedirects = source.Redirects, destinationRequests = destination.Requests, retainedViews = window.Browser.TabCount, retainedTabs = window.Browser.Core.Read().Tabs.Length, expected = count }));
      check("Popup redirect cannot leave its inherited origin or retain a phantom tab", destination.Requests == 0);
      await Snapshot(directory, "fix-09-redirect-boundary-" + Path.GetFileName(directory));
    }
    finally { foreach (var tab in window.Browser.Core.Read().Tabs) await window.Browser.Core.CloseAsync(tab.Id); }
  }
  private static async Task Chat(ShellWindow window, string directory, Action<string, bool> check)
  {
    var root = AppDataRoot.Explicit(Path.Combine(window.Runtime.Root.DirectoryPath, "review-chat")); WindowsPrivateDirectory.Ensure(root.DirectoryPath);
    var tools = Path.Combine(root.DirectoryPath, "tools"); var entry = Path.Combine(tools, "node_modules", "@anthropic-ai", "claude-code", "cli.js"); Directory.CreateDirectory(Path.GetDirectoryName(entry)!);
    File.WriteAllText(entry, """
      const fs=require('fs'),path=require('path');const emit=r=>process.stdout.write(JSON.stringify(r)+'\n');
      fs.writeFileSync(path.join(process.cwd(),'cli.json'),JSON.stringify({pid:process.pid}));
      emit({type:'system',subtype:'init',session_id:'review-chat-thread'});
      require('readline').createInterface({input:process.stdin}).on('line',line=>{
        const row=JSON.parse(line);if(row.type!=='user')return;
        emit({type:'user',uuid:row.uuid,message:row.message});
        const held=path.join(process.cwd(),'held-once');
        if(!fs.existsSync(held)){fs.writeFileSync(held,'yes');emit({type:'stream_event',event:{type:'message_start',message:{id:'partial'}}});emit({type:'stream_event',event:{type:'content_block_delta',index:0,delta:{type:'text_delta',text:'Synthetic reply in progress. No model or real account is used.'}}});return;}
        emit({type:'assistant',message:{id:'resumed',content:[{type:'text',text:process.argv.includes('--resume')?'Exact saved conversation resumed after worker crash.':'Resume identity missing.'}]}});
        emit({type:'result',subtype:'success'});
      });
      """);
    var accounts = new AccountService(new JsonStateStore<AccountState>(root, "accounts"), [new SyntheticAccount()]); var account = await accounts.CreateAsync("claude", "Synthetic CLI · no real sign-in");
    var processes = new WindowsChatProcessKeeper(root, window.Runtime.KeeperExecutable, tools, KeeperCredentials.GetOrCreate(root));
    await using var core = new ChatSessions(new ChatHistory(root), processes, accounts);
    using var serving = new CancellationTokenSource(); var server = new ChatSessionsPipeServer(root, core, KeeperCredentials.GetOrCreate(root)).RunAsync(serving.Token);
    var client = await WindowsChatSessionsClient.ConnectAsync(root, KeeperCredentials.GetOrCreate(root)); var chat = await client.CreateAsync("claude", root.DirectoryPath, account.Id);
    var page = new ChatPage(client, chat.Definition.Id, window.WindowHandle); window.ShowProofChat(page);
    try
    {
      page.Model.Draft = "Synthetic mid-turn crash fixture"; await page.Model.SendAsync(); await Until(() => page.Model.Rows.Any(r => r.Text.Contains("in progress", StringComparison.Ordinal)));
      await Snapshot(directory, "fix-04-chat-before-worker-kill");
      var identity = JsonSerializer.Deserialize<ChatWorkerIdentity>(File.ReadAllBytes(ChatWorkerPaths.FileFor(root, chat.CreationKey, ".identity.json")))!;
      using var worker = Process.GetProcessById(identity.Pid); RequireIdentity(worker, identity.StartedUtcTicks, window.Runtime.KeeperExecutable);
      using var pid = JsonDocument.Parse(File.ReadAllText(Path.Combine(root.DirectoryPath, "cli.json"))); using var cli = Process.GetProcessById(pid.RootElement.GetProperty("pid").GetInt32());
      worker.Kill(); await worker.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20)); await cli.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20));
      check("Actual chat-worker kill ends its CLI without killing the keeper", cli.HasExited);
      await page.Model.ReconnectAsync(); check("Mid-turn recovery keeps the sent message and saved thread", page.Model.Snapshot.Messages.Count(m => m.Text == "Synthetic mid-turn crash fixture") == 1 && page.Model.Snapshot.ConversationId == "review-chat-thread");
      await page.Model.RetryAsync(); await Until(() => page.Model.Rows.Any(r => r.Text == "Exact saved conversation resumed after worker crash.") && !page.Model.Snapshot.Busy);
      check("Retry resumes the exact saved conversation with a fresh worker", page.Model.Snapshot.CreationKey != chat.CreationKey);
      await Snapshot(directory, "fix-05-chat-recovered-light");
      Invoke(Descendants(page).OfType<Button>().Single(b => b.Content as string == "End chat")); await Until(() => page.Model.Snapshot.Ended);
      check("End chat button confirms worker retirement and keeps history", (await processes.ObserveAsync(ChatSessions.Session(page.Model.Snapshot), default)).Presence == ProcessPresence.Dead && page.Model.Snapshot.Events.Any(e => e.Kind == "message"));
      window.SetTheme(ElementTheme.Dark); await Snapshot(directory, "fix-06-ended-chat-dark");
    }
    finally
    {
      window.HideProofChat(); await page.DisposeAsync();
      var current = core.Get(chat.Definition.Id); if (!current.Ended) try { await processes.QuitAsync(current.CreationKey, CancellationToken.None); } catch (IOException) { }
      serving.Cancel(); await server;
    }
  }

  private static async Task Crash(ShellWindow window, string directory, Action<string, bool> check)
  {
    var runtime = window.Runtime; var root = runtime.Root; var childFile = Path.Combine(root.DirectoryPath, "review-child.json");
    var sleeper = Path.Combine(root.DirectoryPath, "review-sleeper.ps1"); File.WriteAllText(sleeper, "while ($true) { Start-Sleep -Milliseconds 250 }");
    var script = Path.Combine(root.DirectoryPath, "review-spawn.ps1");
    File.WriteAllText(script, """
      param([string]$Root)
      $s=New-Object Diagnostics.ProcessStartInfo
      $s.FileName=Join-Path $PSHOME 'powershell.exe';$s.UseShellExecute=$false;$s.CreateNoWindow=$true
      $s.Arguments='-NoProfile -NonInteractive -File "'+(Join-Path $Root 'review-sleeper.ps1')+'"'
      $child=[Diagnostics.Process]::Start($s)
      @{Pid=$child.Id;StartedUtcTicks=$child.StartTime.ToUniversalTime().Ticks}|ConvertTo-Json|Set-Content (Join-Path $Root 'review-child.json.tmp')
      Move-Item (Join-Path $Root 'review-child.json.tmp') (Join-Path $Root 'review-child.json')
      Write-Output 'Console-independent crash child is ready. Isolated proof only.'
      """);
    var row = await runtime.StartAsync("shell", root.DirectoryPath, title: "Review · worker crash containment"); window.OpenSession(row.Definition.Id); await window.WaitForTerminalsAsync();
    var identity = JsonSerializer.Deserialize<WorkerIdentity>(File.ReadAllBytes(WorkerPaths.PathFor(root, row.CreationKey, ".identity.json")))!;
    using var worker = Process.GetProcessById(identity.Pid); RequireIdentity(worker, identity.StartedUtcTicks, runtime.KeeperExecutable);
    Process? child = null;
    try
    {
      await runtime.Keeper.WriteAsync(row.Definition.Id, Encoding.UTF8.GetBytes("& '" + script + "' '" + root.DirectoryPath + "'\r")); await Until(() => File.Exists(childFile));
      using var identityChild = JsonDocument.Parse(File.ReadAllText(childFile)); child = Process.GetProcessById(identityChild.RootElement.GetProperty("Pid").GetInt32());
      if (child.StartTime.ToUniversalTime().Ticks != identityChild.RootElement.GetProperty("StartedUtcTicks").GetInt64()) throw new IOException("The test child changed identity.");
      await Snapshot(directory, "fix-07-worker-and-independent-child");
      await File.WriteAllTextAsync(Path.Combine(directory, "kill-keeper.request"), "owned keeper only"); await Until(() => File.Exists(Path.Combine(directory, "kill-keeper.ack")));
      await runtime.ReconnectAsync(); await runtime.RefreshSessionsAsync();
      check("Actual keeper kill preserves the exact worker and its independent child", !worker.HasExited && !child.HasExited && runtime.Sessions.Single(s => s.Definition.Id == row.Definition.Id).CreationKey == row.CreationKey);
      worker.Kill(); await worker.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20)); await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20));
      check("Actual worker-only kill contains its independent child", child.HasExited);
      await UntilAsync(async () => { await runtime.RefreshSessionsAsync(); return runtime.Sessions.Single(s => s.Definition.Id == row.Definition.Id).State == SessionState.Exited; });
      check("Keeper observes worker death without app restart or a duplicate shell", runtime.Sessions.Count(s => s.Definition.Id == row.Definition.Id) == 1 && runtime.Sessions.Single(s => s.Definition.Id == row.Definition.Id).LeaseIdentity is null);
      await Snapshot(directory, "fix-08-worker-crash-contained");
    }
    finally { if (child is not null) { if (!child.HasExited) child.Kill(); child.Dispose(); } if (!worker.HasExited) await runtime.StopAsync(row.Definition.Id); }
  }

  private static void RequireIdentity(Process process, long ticks, string executable)
  { if (process.StartTime.ToUniversalTime().Ticks != ticks || !string.Equals(process.MainModule?.FileName, executable, StringComparison.OrdinalIgnoreCase)) throw new IOException("Owned process identity changed; refusing to kill it."); }
  private static JsonElement J(object value) => JsonSerializer.SerializeToElement(value);
  private static void Invoke(Button button)
  { var peer = new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button); ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)peer.GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke(); }
  private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
  { yield return parent; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) foreach (var child in Descendants(VisualTreeHelper.GetChild(parent, i))) yield return child; }
  private static Task Until(Func<bool> predicate) => UntilAsync(() => Task.FromResult(predicate()));
  private static async Task UntilAsync(Func<Task<bool>> predicate)
  { var until = DateTimeOffset.UtcNow.AddSeconds(50); while (DateTimeOffset.UtcNow < until) { if (await predicate()) return; await Task.Delay(100); } throw new TimeoutException("The isolated review check timed out."); }
  private static async Task Snapshot(string directory, string name)
  { await Task.Delay(400); await File.WriteAllTextAsync(Path.Combine(directory, "stage.json"), JsonSerializer.Serialize(new { name })); await Until(() => File.Exists(Path.Combine(directory, name + ".ack"))); }
  private sealed class SyntheticAccount : IAccountProvider
  {
    public string Provider => "claude";
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(true, "fixture@example.test"));
    public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) => throw new InvalidOperationException("No real sign-in in a synthetic proof.");
    public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]);
  }
  private sealed class Fixture : IAsyncDisposable
  {
    private readonly TcpListener listener = new(IPAddress.Loopback, 0); private readonly CancellationTokenSource stop = new(); private readonly Task run;
    public string Origin { get; } public int Requests; public int Redirects; private readonly string? other;
    public Fixture(string? destination = null) { other = destination; listener.Start(); Origin = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port; run = Run(); }
    private async Task Run()
    {
      try
      {
        while (!stop.IsCancellationRequested)
        {
          using var client = await listener.AcceptTcpClientAsync(stop.Token); var stream = client.GetStream();
          using var reader = new StreamReader(stream, leaveOpen: true); var request = await reader.ReadLineAsync(stop.Token) ?? ""; string? header; do { header = await reader.ReadLineAsync(stop.Token); } while (!string.IsNullOrEmpty(header));
          Interlocked.Increment(ref Requests);
          if (request.Contains(" /redirect ", StringComparison.Ordinal)) { Interlocked.Increment(ref Redirects); await stream.WriteAsync(Encoding.UTF8.GetBytes("HTTP/1.1 302 Found\r\nLocation: " + other + "/blocked\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"), stop.Token); continue; }
          var html = "<html><head><title>Isolated Windows browser review</title></head><body style='font:20px Segoe UI;padding:32px'><h1>Browser origin boundary</h1><p>Synthetic local fixture. No accounts or external websites.</p><button id='same' onclick=\"window.open('/same')\">Same origin</button> <button id='other' onclick=\"window.open('" + other + "/blocked')\">Other origin</button> <button id='redirect' onclick=\"window.open('/redirect')\">Redirect to other origin</button></body></html>";
          var body = Encoding.UTF8.GetBytes(html); await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n"), stop.Token); await stream.WriteAsync(body, stop.Token);
        }
      }
      catch (Exception ex) when (stop.IsCancellationRequested && ex is OperationCanceledException or SocketException) { }
    }
    public async ValueTask DisposeAsync() { stop.Cancel(); listener.Stop(); await run; stop.Dispose(); }
  }
}
