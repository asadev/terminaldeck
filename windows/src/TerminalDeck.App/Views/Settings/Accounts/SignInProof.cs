using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using TerminalDeck.App.Views.Agents;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
  {
    yield return root;
    for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root); i++)
      foreach (var child in Descendants(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, i))) yield return child;
  }
  private async Task RunSignInProofAsync()
  {
    var output = Environment.GetEnvironmentVariable("TD_SIGNIN_PROOF")!;
    if (!File.Exists(Path.Combine(dataRoot.DirectoryPath, ".signin-proof")) || !dataRoot.DirectoryPath.StartsWith(@"C:\TD\out\", StringComparison.OrdinalIgnoreCase)) throw new IOException("Sign-in proof requires its marked scratch root.");
    SetTheme(ElementTheme.Light);
    Directory.CreateDirectory(output); var checks = new List<string>(); var failed = new List<string>();
    void Check(string label, bool result) { (result ? checks : failed).Add(label); }
    try
    {
      var account = Runtime.Accounts.Default("claude")!;
      var planner = new WindowsProviderLaunchPlanner(dataRoot, WindowsProviderLaunchPlanner.BundledToolsDirectory);
      var home = planner.AccountHome(account.Provider, account.HomeId);
      Check("TEST Default stays in scratch home", home.StartsWith(dataRoot.DirectoryPath, StringComparison.OrdinalIgnoreCase) && account.HomeId != AccountHomes.ExistingLogin);
      var status = await Runtime.Accounts.InstallationAsync(account.Id);
      Check("Real Claude installation and version found", status.Installed == true && status.Version is not null);
      var launch = planner.Resolve("claude", ["--version"], new Dictionary<string, string>(), dataRoot.DirectoryPath);
      Check("Official native Claude path found", string.Equals(launch.Executable, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin", "claude.exe"), StringComparison.OrdinalIgnoreCase));
      await File.WriteAllTextAsync(Path.Combine(output, "detection.json"), JsonSerializer.Serialize(new { executable = launch.Executable, status.Version, scratchHome = home }));
      var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
      AccountSignInSheet.PresentedForProof = async (window, terminal) =>
      {
        try
        {
          var oauth = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
          void Changed() { if (terminal.OAuthReady) oauth.TrySetResult(); }
          terminal.OutputChanged += Changed; Changed();
          try { await oauth.Task.WaitAsync(TimeSpan.FromSeconds(75)); }
          finally { terminal.OutputChanged -= Changed; }
          Check("Real CLI reached browser OAuth step", terminal.OAuthReady);
          var browserMarker = Path.Combine(dataRoot.DirectoryPath, "browser-requested");
          var deadline = DateTimeOffset.UtcNow.AddSeconds(3);
          while (!File.Exists(browserMarker) && DateTimeOffset.UtcNow < deadline) await Task.Delay(50);
          Check("CLI browser launch safely routed to scratch profile", File.Exists(browserMarker));
          var browserHome = Path.Combine(dataRoot.DirectoryPath, "proof-browser");
          while (!Directory.Exists(browserHome) && DateTimeOffset.UtcNow < deadline) await Task.Delay(25);
          Check("OAuth browser opened using an empty scratch profile", Directory.Exists(browserHome));
          if (File.Exists(browserMarker))
            foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
            {
              SetTheme(theme); await Task.Delay(200);
              Check("Sign-in sheet follows " + theme + " app theme", ((FrameworkElement)window.Content).ActualTheme == theme);
              await Verification.W10Proof.CaptureAsync((FrameworkElement)window.Content, output, "claude-signin", theme.ToString().ToLowerInvariant(), "scratch-real-cli", _ => { });
            }
          SetTheme(ElementTheme.Light);
          // Cancel through this sheet's window. No browser credentials or OAuth
          // approval are entered, and no user's normal account is inspected.
          var progress = await AccountSignInSheet.ControlAsync(account.Id, "state");
          Check("Sign-in progress is available to app tools", progress.GetProperty("isOpen").GetBoolean());
          var cancelled = await AccountSignInSheet.ControlAsync(account.Id, "cancel");
          Check("App-tool cancellation closes the same sign-in", cancelled.GetProperty("state").GetString() == "cancelled" && !cancelled.GetProperty("isOpen").GetBoolean());
          completed.TrySetResult();
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) { failed.Add("OAuth proof: " + ex.GetType().Name); window.Close(); completed.TrySetResult(); }
      };
      var sessionCount = Runtime.Sessions.Count;
      var pickerTask = NewSessionPicker.ShowAsync(Root.XamlRoot, Runtime.Agents, Runtime.Projects, Runtime.Accounts, this, mode: "terminal",
        terminalStart: (_, _) => throw new IOException("The sign-in proof must never start a model or shell session."));
      var pickerDeadline = DateTimeOffset.UtcNow.AddSeconds(5);
      while (NewSessionPicker.ActiveDialogForProof is null && DateTimeOffset.UtcNow < pickerDeadline) await Task.Delay(25);
      var picker = NewSessionPicker.ActiveDialogForProof ?? throw new IOException("New-session dialog did not open.");
      while ((!picker.IsLoaded || picker.XamlRoot is null) && DateTimeOffset.UtcNow < pickerDeadline) await Task.Delay(25);
      var controls = Descendants(picker.Content as DependencyObject ?? picker).ToArray();
      foreach (var expander in controls.OfType<Expander>()) expander.IsExpanded = true;
      await Task.Delay(100);
      controls = Descendants(picker.Content as DependencyObject ?? picker).ToArray();
      var ai = controls.OfType<ComboBox>().Single(c => c.Header as string == "AI"); ai.SelectedValue = "claude";
      var folderInput = controls.OfType<TextBox>().Single(t => t.Header as string == "Working folder"); folderInput.Text = dataRoot.DirectoryPath;
      var draft = controls.OfType<TextBox>().Single(t => AutomationProperties.GetAutomationId(t) == "agents.hand.job"); draft.Text = "Keep this sign-in draft";
      foreach (var expander in controls.OfType<Expander>()) expander.IsExpanded = true;
      var signIn = controls.OfType<Button>().Single(b => b.Content as string == "Sign in to Claude Code…");
      ((IInvokeProvider)new ButtonAutomationPeer(signIn).GetPattern(PatternInterface.Invoke)).Invoke();
      await completed.Task.WaitAsync(TimeSpan.FromSeconds(90));
      var finishDeadline = DateTimeOffset.UtcNow.AddSeconds(10);
      while (!signIn.IsEnabled && DateTimeOffset.UtcNow < finishDeadline) await Task.Delay(25);
      Check("Cancel returns to the same new-session dialog", NewSessionPicker.ActiveDialogForProof == picker);
      Check("New-session draft and folder survive cancellation", draft.Text == "Keep this sign-in draft" && folderInput.Text == dataRoot.DirectoryPath);
      await Verification.W10Proof.CaptureAsync((FrameworkElement)picker.Content, output, "new-session-draft", "light", "scratch-real-cli", _ => { });
      picker.Hide(); await pickerTask;
      await Runtime.RefreshSessionsAsync();
      Check("Login sheet never adds an ordinary session", Runtime.Sessions.Count == sessionCount);
      Check("Cancelled scratch login stays signed out", !(await Runtime.Accounts.RefreshAsync(account.Id)).SignedIn);
      Check("Window-wide sign-in banner absent", !Model.Notice.Contains("Finish sign-in", StringComparison.OrdinalIgnoreCase));
      await OpenSettingsAsync("coding-ais");
      await Task.Delay(350);
      await Verification.W10Proof.CaptureAsync(settings, output, "coding-ais", "light", "scratch-real-cli", _ => { });
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { failed.Add(ex.GetType().Name + ": " + ex.Message); }
    finally
    {
      AccountSignInSheet.PresentedForProof = null;
      await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { ok = failed.Count == 0, checks, failed, at = DateTimeOffset.UtcNow }));
      Close();
    }
  }
}
