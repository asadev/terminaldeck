using System.Text.Json;
using Microsoft.UI.Xaml;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views;

namespace TerminalDeck.App.Verification;

// Opt-in proof runs only when the output directory is below the explicit scratch root.
// The desktop script supplies a local fixture and captures only this process's foreground window.
internal static class DesktopProof
{
  public static async Task RunAsync(ShellWindow window, string directory, bool checks)
  {
    Directory.CreateDirectory(directory);
    var passed = new List<string>();
    var failed = new List<string>();
    void Check(string name, bool condition) { (condition ? passed : failed).Add(name); }
    try
    {
      await Task.Delay(600);
      window.SetTheme(ElementTheme.Light);
      if (!checks) await SnapshotAsync(directory, "01-shell-light");
      var shell = window.Model;
      var terminal = shell.AddDraft("Codex", @"C:\TD\example", SessionPresentation.Terminal);
      var chat = shell.AddDraft("Claude Code", @"C:\TD\example", SessionPresentation.Chat);
      chat.Message = "Help me review the changes in this folder.";
      // Render the chat once with its draft, then keep the same view while navigating.
      shell.Page = ShellPage.Browser; shell.Page = ShellPage.Sessions;
      if (!checks) await SnapshotAsync(directory, "02-chat-light");
      shell.Split = SplitPresentation.Sessions;
      await window.WaitForTerminalsAsync().WaitAsync(TimeSpan.FromSeconds(30));
      if (!checks) await SnapshotAsync(directory, "03-sessions-light");
      shell.Split = SplitPresentation.Browser;
      await window.Browser.Ready.WaitAsync(TimeSpan.FromSeconds(30));
      if (!checks) await SnapshotAsync(directory, "04-split-browser-light");
      shell.Page = ShellPage.Browser;
      var browser = window.Browser;
      var fixture = Environment.GetEnvironmentVariable("TD_UI_FIXTURE") ?? "http://127.0.0.1:18765/";
      await browser.NavigateForProofAsync(fixture);
      if (!checks) await SnapshotAsync(directory, "05-browser-light");
      window.SetTheme(ElementTheme.Dark);
      await Task.Delay(400);
      var darkPage = (await browser.EvaluateForProofAsync("({dark:matchMedia('(prefers-color-scheme: dark)').matches,scheme:getComputedStyle(document.documentElement).colorScheme})")).GetProperty("result").GetProperty("value");
      await File.WriteAllTextAsync(Path.Combine(directory, "page-theme.json"), JsonSerializer.Serialize(new { theme = browser.ActualTheme.ToString(), page = darkPage }));
      if (checks) Check("Web page follows the dark shell theme", darkPage.GetProperty("dark").GetBoolean());
      if (!checks) await SnapshotAsync(directory, "06-browser-dark");
      shell.Page = ShellPage.Settings;
      for (var index = 0; index < 4; index++)
      {
        window.Settings.SelectSection(index);
        if (!checks) await SnapshotAsync(directory, $"{7 + index:00}-settings-dark");
      }
      if (!checks)
      {
        var sheet = window.ShowAccountAsync();
        await SnapshotAsync(directory, "11-account-sheet-dark");
        window.DismissAccountSheet();
        await sheet.WaitAsync(TimeSpan.FromSeconds(5));
      }
      if (checks)
      {
        Check("Two session drafts, no live process claim", shell.Sessions.Count == 2 && shell.Sessions.All(s => s.Label.EndsWith("draft", StringComparison.Ordinal)));
        Check("Draft text survives switching views", chat.Message == "Help me review the changes in this folder.");
        var refused = false;
        try { shell.AddDraft("Shell", @"C:\TD\example", SessionPresentation.Chat); } catch (ArgumentException) { refused = true; }
        Check("Shell cannot create an AI chat", refused && shell.Sessions.Count == 2);
        Check("Both split layouts selected", shell.Split == SplitPresentation.Browser);
        Check("Settings includes MCP destination", window.Settings.SelectedSection == "MCP servers");
        window.OpenCodingAIs();
        Check("Account sign-in link reaches Coding AIs", window.Settings.SelectedSection == "Coding AIs" && shell.Page == ShellPage.Settings);
        shell.ServiceUnavailable("Phone pairing");
        Check("Unavailable actions report no change", shell.Notice.Contains("Nothing was changed", StringComparison.Ordinal));
        Check("Localhost resolves to http", BrowserViewModel.ResolveAddress("localhost:18765").Scheme == "http");
        Check("Search words are encoded", BrowserViewModel.ResolveAddress("a & b").Query.Contains("%26", StringComparison.Ordinal));
        refused = false;
        try { BrowserViewModel.ResolveAddress("javascript:alert(1)"); } catch (ArgumentException) { refused = true; }
        Check("Unsafe address refused", refused);
        shell.Page = ShellPage.Browser;
        Check("Local fixture rendered by WebView2", (await browser.EvaluateForProofAsync("document.title")).GetProperty("result").GetProperty("value").GetString() == "Windows UI fixture");
        await browser.NavigateForProofAsync(fixture + "next");
        Check("Address navigation reaches the local next page", new Uri(browser.CurrentAddress).AbsolutePath == "/next");
        await browser.NavigateCommandForProofAsync("back");
        Check("Back restores the prior page", new Uri(browser.CurrentAddress).AbsolutePath == "/");
        await browser.NavigateCommandForProofAsync("forward");
        Check("Forward restores the next page", new Uri(browser.CurrentAddress).AbsolutePath == "/next");
        await browser.NavigateCommandForProofAsync("reload");
        Check("Reload completes on the current page", new Uri(browser.CurrentAddress).AbsolutePath == "/next");
        await browser.ExecuteAsync("size", "390x844");
        Check("Viewport preset changes actual page dimensions", (await browser.EvaluateForProofAsync("innerWidth")).GetProperty("result").GetProperty("value").GetInt32() == 390);
        await browser.ExecuteAsync("size", "fill");
        Check("Fill restores viewport", (await browser.EvaluateForProofAsync("innerWidth")).GetProperty("result").GetProperty("value").GetInt32() != 390);
        await browser.ExecuteAsync("record");
        await browser.EvaluateForProofAsync("document.querySelector('button').click();let a=document.querySelector('input');a.value='SYNTHETIC_VALUE_MUST_NOT_RECORD';a.dispatchEvent(new Event('change',{bubbles:true}));let p=document.querySelector('input[type=password]');p.value='SYNTHETIC_PASSWORD';p.dispatchEvent(new Event('change',{bubbles:true}));");
        await Task.Delay(400);
        Check("Recorder collects clicks and safe entry selectors", browser.StepCount == 2);
        Check("Recorder omits entered values and password fields", browser.StepsForProof().All(s => !s.Contains("SYNTHETIC", StringComparison.Ordinal)) && browser.StepsForProof().Any(s => s.Contains("value omitted", StringComparison.Ordinal)));
        await browser.ExecuteAsync("record");
        Check("Stop retains recorded steps", !browser.IsRecording && browser.StepCount == 2);
        var originalProfile = browser.ProfileForProof();
        await browser.AddTabAsync(isolated: true);
        Check("Isolated tab uses an actual private profile", browser.PrivateForProof() && browser.ProfileForProof() != originalProfile);
        await browser.CloseSelectedForProofAsync();
        Check("Closing a tab selects its neighbor", browser.TabCount == 1 && browser.ProfileForProof() == originalProfile);
        await browser.AddTabAsync(new BrowserProfile(Guid.NewGuid().ToString("N"), "Proof"));
        Check("Named profile uses a separate WebView2 profile", !browser.PrivateForProof() && browser.ProfileForProof() != originalProfile);
        await browser.CloseSelectedForProofAsync();
        shell.CloseDraft(chat);
        Check("Closing draft preserves other draft", shell.Sessions.Count == 1 && shell.Selected == terminal);
        window.SetTheme(ElementTheme.Light);
        await Task.Delay(300);
        Check("Light theme applied", window.Frame.ActualTheme == ElementTheme.Light);
        Check("Web page follows the light shell theme", (await browser.EvaluateForProofAsync("matchMedia('(prefers-color-scheme: light)').matches")).GetProperty("result").GetProperty("value").GetBoolean());
        await browser.ExecuteAsync("inspect");
        Check("Inspect command opens developer tools without error", true);
      }
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      // Do not copy arbitrary browser or provider exception messages into proof output.
      failed.Add("Proof stopped: " + ex.GetType().Name + " 0x" + ex.HResult.ToString("X8"));
      var frames = new System.Diagnostics.StackTrace(ex, true).GetFrames().Where(frame => frame.GetMethod()?.DeclaringType?.Namespace?.StartsWith("TerminalDeck.App", StringComparison.Ordinal) == true).Select(frame => new { method = frame.GetMethod()?.DeclaringType?.Name + "." + frame.GetMethod()?.Name, line = frame.GetFileLineNumber() });
      await File.WriteAllTextAsync(Path.Combine(directory, "failure-location.json"), JsonSerializer.Serialize(frames));
    }
    await File.WriteAllTextAsync(Path.Combine(directory, "result.json"), JsonSerializer.Serialize(new { timestamp = DateTimeOffset.Now, mode = checks ? "checks" : "screens", passed = passed.Count, failed = failed.Count, checksPassed = passed, checksFailed = failed }));
  }
  private static async Task SnapshotAsync(string directory, string name)
  {
    await Task.Delay(800);
    var ack = Path.Combine(directory, name + ".ack");
    var completion = new TaskCompletionSource();
    using var watcher = new FileSystemWatcher(directory, "*.ack") { EnableRaisingEvents = true };
    watcher.Created += (_, e) => { if (e.FullPath == ack) completion.TrySetResult(); };
    await File.WriteAllTextAsync(Path.Combine(directory, "stage.json"), JsonSerializer.Serialize(new { name }));
    if (File.Exists(ack)) completion.TrySetResult();
    await completion.Task.WaitAsync(TimeSpan.FromSeconds(30));
  }
}
