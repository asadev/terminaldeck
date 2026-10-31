using System.Text.Json;
using Microsoft.UI.Xaml;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views;

namespace TerminalDeck.App.Verification;

internal static class W9ThemeProof
{
  public static async Task RunAsync(ShellWindow window, string directory)
  {
    string[] passed = []; string[] failed = [];
    try
    {
      await window.Ready; window.SetTheme(ElementTheme.Light); window.Model.Page = ShellPage.Hoot;
      await File.WriteAllTextAsync(Path.Combine(directory, "ui-ready"), "ready");
      var until = DateTimeOffset.UtcNow.AddMinutes(3);
      while (!File.Exists(Path.Combine(directory, "details.complete")))
      { if (DateTimeOffset.UtcNow > until) throw new TimeoutException("The two dialog captures did not finish."); await Task.Delay(150); }
      using var result = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(directory, "details-result.json")));
      passed = result.RootElement.GetProperty("passed").Deserialize<string[]>() ?? [];
      failed = result.RootElement.GetProperty("failed").Deserialize<string[]>() ?? [];
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { failed = [ex.GetType().Name + ": " + ex.Message]; }
    await File.WriteAllTextAsync(Path.Combine(directory, "result.json"), JsonSerializer.Serialize(new { passed, failed, passCount = passed.Length, failCount = failed.Length, timestamp = DateTimeOffset.UtcNow }));
  }
}
