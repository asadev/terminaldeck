using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Integration;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Settings;
using Windows.ApplicationModel.DataTransfer;
using AccountPages = TerminalDeck.App.Views.Settings.AccountPages;
using SettingsPanel = TerminalDeck.App.Views.Settings.SettingsPanel;

namespace TerminalDeck.App.Views.Advanced;

public sealed class AdvancedPreferencesPage : UserControl
{
  private readonly AppRuntime runtime;
  private readonly BrowserModel? browser;
  private readonly Action? resetTheme;
  private readonly Action<bool>? closeConfirmation;
  private readonly Func<bool>? openPaired;
  private readonly StackPanel body = new() { Spacing = 20, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(20, 8, 20, 20) };
  private readonly TextBlock notice = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, Margin = new Thickness(8, -8, 0, 0) };
  public AdvancedPreferencesPage(AppRuntime runtime, BrowserModel? browser, Action? resetTheme, Action<bool>? closeConfirmation, Func<bool>? openPaired = null)
  {
    this.runtime = runtime; this.browser = browser; this.resetTheme = resetTheme; this.closeConfirmation = closeConfirmation; this.openPaired = openPaired;
    Content = new ScrollViewer { Content = body, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }; Render();
  }
  // Advanced (Mac, 15 Nov): Debug mode · Open logs · Paired with a code · Reset all settings (red). No paths on the
  // surface: a path lives in its info button, the diagnostic details behind one click.
  private void Render()
  {
    body.Children.Clear();
    var debug = new ToggleSwitch { IsOn = runtime.General.Read().DebugSettings, OnContent = "", OffContent = "", MinWidth = 40 };
    debug.Toggled += (_, _) => { runtime.General.Save(runtime.General.Read() with { DebugSettings = debug.IsOn }); Render(); };
    var rows = new List<FrameworkElement> { SettingsPanel.SettingRow("Debug mode", "Shows saved preference values and where this app keeps its files, to help fix a problem.", debug) };
    if (debug.IsOn) rows.Add(SettingsPanel.SettingRow("Diagnostic details", "", Press("Show…", ShowDiagnosticsAsync)));
    var logs = Path.Combine(runtime.Root.DirectoryPath, "logs");
    rows.Add(SettingsPanel.SettingRow("Logs", "This app's logs are kept in " + logs, Press("Open", () => { Reveal(logs, true); return Task.CompletedTask; })));
    if (openPaired is { } paired)
      rows.Add(SettingsPanel.SettingRow("Paired with a code", "Phones and computers paired with a code, the web version and phone access to this PC's screen.", Press("Open…", () => { paired(); return Task.CompletedTask; })));
    body.Children.Add(SettingsPanel.GroupRows(rows));
    var reset = AccountPages.RedButton("Reset all settings…");
    reset.Click += async (_, _) => await ResetAsync();
    body.Children.Add(SettingsPanel.GroupRows([SettingsPanel.SettingRow("Reset all settings",
      "Resets General, notifications, terminal appearance, window theme, close confirmation and browser preferences. Browser tabs close when the saved sign-in mode changes. Projects, sessions, accounts, agents and saved palettes are kept.", reset)]));
    if (notice.Text.Length > 0) body.Children.Add(notice);
  }
  private Button Press(string label, Func<Task> work)
  {
    var button = new Button { Content = label, VerticalAlignment = VerticalAlignment.Center };
    button.Click += async (_, _) =>
    {
      try { await work(); }
      catch (Exception e) when (e is not OutOfMemoryException) { notice.Text = e.Message; Render(); }
    };
    return button;
  }
  private void Reveal(string path, bool directory)
  {
    try
    {
      if (directory && !Directory.Exists(path)) { notice.Text = "There are no logs yet."; Render(); return; }
      var launch = new ProcessStartInfo("explorer.exe") { UseShellExecute = true }; launch.ArgumentList.Add(directory ? path : "/select," + path); Process.Start(launch);
    }
    catch (Exception e) when (e is IOException or System.ComponentModel.Win32Exception or InvalidOperationException) { notice.Text = "Windows could not open this folder."; Render(); }
  }
  // Debug mode's details, behind one click: the saved preference values (sensitive-looking text hidden), the record
  // counts, and where the files are, each with Copy path and Open.
  private async Task ShowDiagnosticsAsync()
  {
    var details = new StackPanel { Spacing = 12 };
    var problem = new TextBlock { TextWrapping = TextWrapping.Wrap };
    var values = new Dictionary<string, JsonElement?>();
    foreach (var name in new[] { "general-settings", "notifications", "terminal-appearance", "appearance", "browser-start-page", "browser-privacy" })
    {
      var path = Path.Combine(runtime.Root.DirectoryPath, "state", name + ".json");
      try
      {
        if (!File.Exists(path)) { values[name] = null; continue; }
        if (new FileInfo(path).Length > 2 * 1024 * 1024 || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException();
        using var json = JsonDocument.Parse(File.ReadAllBytes(path));
        var safe = System.Text.Json.Nodes.JsonNode.Parse(json.RootElement.GetRawText());
        RedactPreference(safe); values[name] = JsonSerializer.SerializeToElement(safe);
      }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { problem.Text = "A preference file could not be read safely: " + name; }
    }
    details.Children.Add(new TextBox { Text = JsonSerializer.Serialize(values, new JsonSerializerOptions { WriteIndented = true }), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 260 });
    details.Children.Add(new TextBlock { Text = $"This app copy · {runtime.Sessions.Count} terminal records · {(runtime.Chats is null ? "starting" : runtime.Chats.List().Count.ToString())} chat records · Phone host: {runtime.Remote.State}", TextWrapping = TextWrapping.Wrap });
    foreach (var (label, path, directory) in new[] { ("This app's data", runtime.Root.DirectoryPath, true), ("Preference files", Path.Combine(runtime.Root.DirectoryPath, "state"), true), ("Logs", Path.Combine(runtime.Root.DirectoryPath, "logs"), true), ("General settings", Path.Combine(runtime.Root.DirectoryPath, "state", "general-settings.json"), false), ("Terminal appearance", Path.Combine(runtime.Root.DirectoryPath, "state", "terminal-appearance.json"), false) })
    {
      var row = new StackPanel { Spacing = 6 }; row.Children.Add(new TextBlock { Text = label + "\n" + path, TextWrapping = TextWrapping.Wrap });
      var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; var copy = new Button { Content = "Copy path" };
      copy.Click += (_, _) => { var data = new DataPackage(); data.SetText(path); Clipboard.SetContent(data); problem.Text = "Path copied."; }; controls.Children.Add(copy);
      var open = new Button { Content = directory ? "Open folder" : "Reveal file", IsEnabled = directory ? Directory.Exists(path) : File.Exists(path) };
      open.Click += (_, _) => Reveal(path, directory);
      controls.Children.Add(open); row.Children.Add(controls); details.Children.Add(row);
    }
    details.Children.Add(problem);
    await new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Diagnostic details", Content = new ScrollViewer { Content = details, MaxHeight = 480 }, CloseButtonText = "Done" }.ShowAsync();
  }
  private static void RedactPreference(System.Text.Json.Nodes.JsonNode? node)
  {
    if (node is System.Text.Json.Nodes.JsonObject row)
      foreach (var pair in row.ToArray())
        if (pair.Value is System.Text.Json.Nodes.JsonValue scalar && scalar.TryGetValue<string>(out var text)) row[pair.Key] = SafeText(text);
        else RedactPreference(pair.Value);
    else if (node is System.Text.Json.Nodes.JsonArray rows)
      for (var i = 0; i < rows.Count; i++)
        if (rows[i] is System.Text.Json.Nodes.JsonValue scalar && scalar.TryGetValue<string>(out var text)) rows[i] = SafeText(text); else RedactPreference(rows[i]);
  }
  private static string SafeText(string text)
  {
    if (Uri.TryCreate(text, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https") text = uri.GetLeftPart(UriPartial.Path);
    return TerminalDeck.Core.Remote.PhonePushFeatures.Redact(text);
  }
  private async Task ResetAsync()
  {
    var question = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Reset app settings?", Content = "Only the preferences listed here return to defaults. Browser tabs may close if the saved sign-in mode changes. Running terminal/chat sessions and saved data are kept.", PrimaryButtonText = "Reset app settings", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
    if (await question.ShowAsync() != ContentDialogResult.Primary) return;
    PreferenceResetResult result;
    try { result = await runtime.ResetAppPreferencesAsync(true, browser, resetTheme, closeConfirmation); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException or System.Runtime.InteropServices.ExternalException)
    { notice.Text = "The settings reset could not finish. " + e.Message; Render(); return; }
    var failed = result.Failed;
    notice.Text = failed.Length == 0 ? "Settings are back to their defaults. Projects, accounts and sessions were kept." : "Some settings were not reset. Try again for: " + string.Join(", ", failed);
    Render();
  }
}
