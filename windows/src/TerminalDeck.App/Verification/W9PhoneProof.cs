using System.Text.Json;
using TerminalDeck.App.Views;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.App.Verification;

// Resume only the phone check after the desktop walk; no completed check runs again.
internal static class W9PhoneProof
{
  public static async Task RunAsync(ShellWindow window, string directory, bool hootOnly = false)
  {
    var runtime = window.Runtime; var passed = new List<string>(); var failed = new List<string>();
    string? shellId = null; string? phoneId = null;
    try
    {
      await window.Ready;
      var project = runtime.Projects.List().Single(p => p.Name == "W9 sample");
      if (hootOnly) await runtime.Hoot.ContinueAsync();
      else { var shell = await runtime.StartShellForProjectAsync(project.HomeFolder!, project.Id); shellId = shell.Definition.Id; }
      window.Model.Page = ShellPage.Settings; window.Settings.SelectSection(2); await window.Settings.ShowCodeAsync();
      await File.WriteAllTextAsync(Path.Combine(directory, "pair-code.txt"), window.Settings.ActiveCode);
      await File.WriteAllTextAsync(Path.Combine(directory, "phone-ready"), "ready");
      await WaitAsync(() => runtime.Remote.Trust.Pending().Count > 0);
      phoneId = runtime.Remote.Trust.Pending().Single().Id;
      runtime.SetPhoneWorkspace(phoneId, [project.Id], true, PhoneAccess.Full);
      await File.WriteAllTextAsync(Path.Combine(directory, "phone-approved"), "ready");
      await WaitAsync(() => File.Exists(Path.Combine(directory, "phone-done")));
      using var result = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(directory, "phone-done")));
      passed.AddRange(result.RootElement.GetProperty("passed").Deserialize<string[]>() ?? []);
      failed.AddRange(result.RootElement.GetProperty("failed").Deserialize<string[]>() ?? []);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    { failed.Add(ex.GetType().Name + ": " + ex.Message); await File.WriteAllTextAsync(Path.Combine(directory, "failure-stack.txt"), ex.ToString()); }
    finally
    {
      if (phoneId is not null) runtime.Remote.Trust.Revoke(phoneId);
      if (shellId is not null) await runtime.StopAsync(shellId);
    }
    await File.WriteAllTextAsync(Path.Combine(directory, "result.json"), JsonSerializer.Serialize(new { passed, failed, passCount = passed.Count, failCount = failed.Count, timestamp = DateTimeOffset.UtcNow }));
  }
  private static async Task WaitAsync(Func<bool> ready)
  { var until = DateTimeOffset.UtcNow.AddMinutes(8); while (DateTimeOffset.UtcNow < until) { if (ready()) return; await Task.Delay(150); } throw new TimeoutException("The phone walkthrough timed out."); }
}
