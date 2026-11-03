using System.Text.Json;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Storage;
namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  public Action? ResetWindowPreferenceOwner { get; set; }
  public Func<CancellationToken, ValueTask>? ResetBrowserPreferenceOwner { get; set; }
  public async ValueTask<PreferenceResetResult> ResetAppPreferencesAsync(bool confirmed, BrowserModel? browser = null, Action? resetTheme = null, Action<bool>? closeConfirmation = null, CancellationToken ct = default)
  {
    ct.ThrowIfCancellationRequested();
    if (Notifications is null) throw new InvalidOperationException("Notification settings are still starting. Retry after the app connects.");
    var result = PreferenceReset.Run(confirmed,
      new("General", () => General.Save(new())), new("Notifications", () => Notifications.Save(new())), new("Terminal appearance", TerminalAppearance.Reset),
      new("Window preferences", () =>
      {
        if (resetTheme is not null && closeConfirmation is not null) { resetTheme(); closeConfirmation(true); }
        else if (ResetWindowPreferenceOwner is not null) ResetWindowPreferenceOwner();
        else throw new InvalidOperationException("The window preference owner is not connected.");
      }));
    var failed = result.Failed.ToList(); var completed = result.Completed.ToList();
    try
    {
      new JsonStateStore<BrowserStartPage>(Root, "browser-start-page").Save(new(""));
      if (ResetBrowserPreferenceOwner is not null) await ResetBrowserPreferenceOwner(ct);
      else if (browser is not null) await browser.SetStartUrlAsync("about:blank", ct);
      completed.Add("Browser preferences");
    }
    catch (Exception e) when (e is IOException or InvalidOperationException or ArgumentException or System.Runtime.InteropServices.ExternalException) { failed.Add("Browser preferences"); }
    return new(completed.ToArray(), failed.ToArray());
  }
  public IReadOnlyDictionary<string, string> PreferencePaths() => new Dictionary<string, string>
  {
    ["data"] = Root.DirectoryPath, ["state"] = Path.Combine(Root.DirectoryPath, "state"), ["logs"] = Path.Combine(Root.DirectoryPath, "logs"),
    ["general"] = Path.Combine(Root.DirectoryPath, "state", "general-settings.json"), ["appearance"] = Path.Combine(Root.DirectoryPath, "state", "appearance.json"),
    ["terminal"] = Path.Combine(Root.DirectoryPath, "state", "terminal-appearance.json"), ["notifications"] = Path.Combine(Root.DirectoryPath, "state", "notifications.json")
  };
  private void InitializePreferenceTools()
  {
    Door.Register("settings.preferences.read", (context, args, ct) =>
    { context.Require("settings", "workspace"); return ValueTask.FromResult(JsonSerializer.SerializeToElement(new { general = General.Read(), notifications = Notifications is null ? new JsonStateStore<TerminalDeck.Core.Notifications.NotificationPreferences>(Root, "notifications").Load() ?? new() : Notifications.Read(), terminal = TerminalAppearance.Preferences(), paths = PreferencePaths() })); });
    Door.Register("settings.preferences.reset", async (context, args, ct) =>
    { context.Require("settings", "workspace"); await context.EnsureCurrentAsync(ct); return JsonSerializer.SerializeToElement(await ResetAppPreferencesAsync(args.GetProperty("confirmed").GetBoolean(), ct: ct)); });
    Door.Register("settings.preferences.open_path", async (context, args, ct) =>
    {
      context.Require("settings", "workspace"); await context.EnsureCurrentAsync(ct);
      if (!PreferencePaths().TryGetValue(args.GetProperty("key").GetString()!, out var path)) throw new ArgumentException("Choose a known app-copy path.");
      var directory = Directory.Exists(path); if (!directory && !File.Exists(path)) throw new IOException("That path has not been created in this app copy yet.");
      var start = new System.Diagnostics.ProcessStartInfo("explorer.exe") { UseShellExecute = true }; start.ArgumentList.Add(directory ? path : "/select," + path); System.Diagnostics.Process.Start(start);
      return JsonSerializer.SerializeToElement(new { opened = true });
    });
  }
}
