using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Integration;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Settings;
using Windows.ApplicationModel.DataTransfer;

namespace TerminalDeck.App.Views.Advanced;

public sealed class AdvancedPreferencesPage : UserControl
{
  private readonly AppRuntime runtime;
  private readonly BrowserModel? browser;
  private readonly Action? resetTheme;
  private readonly Action<bool>? closeConfirmation;
  private readonly StackPanel body = new() { Spacing = 16, Padding = new Thickness(24), MaxWidth = 900 };
  private readonly TextBlock notice = new() { TextWrapping = TextWrapping.Wrap };
  public AdvancedPreferencesPage(AppRuntime runtime, BrowserModel? browser, Action? resetTheme, Action<bool>? closeConfirmation)
  { this.runtime = runtime; this.browser = browser; this.resetTheme = resetTheme; this.closeConfirmation = closeConfirmation; Content = new ScrollViewer { Content = body }; Render(); }
  private void Render()
  {
    body.Children.Clear(); body.Children.Add(new TextBlock { Text = "Advanced", FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
    var debug = new ToggleSwitch { Header = "Show internal settings and diagnostic paths", IsOn = runtime.General.Read().DebugSettings };
    debug.Toggled += (_, _) => { runtime.General.Save(runtime.General.Read() with { DebugSettings = debug.IsOn }); Render(); }; body.Children.Add(debug);
    if (debug.IsOn)
    {
      body.Children.Add(new TextBlock { Text = "Saved preference values · sensitive-looking text is hidden", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
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
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { notice.Text = "A preference file could not be read safely: " + name; }
      }
      body.Children.Add(new TextBox { Text = JsonSerializer.Serialize(values, new JsonSerializerOptions { WriteIndented = true }), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 260 });
      body.Children.Add(new TextBlock { Text = $"This app copy · {runtime.Sessions.Count} terminal records · {(runtime.Chats is null ? "starting" : runtime.Chats.List().Count.ToString())} chat records · Phone host: {runtime.Remote.State}", TextWrapping = TextWrapping.Wrap });
      foreach (var (label, path, directory) in new[] { ("This app's data", runtime.Root.DirectoryPath, true), ("Preference files", Path.Combine(runtime.Root.DirectoryPath, "state"), true), ("Logs", Path.Combine(runtime.Root.DirectoryPath, "logs"), true), ("General settings", Path.Combine(runtime.Root.DirectoryPath, "state", "general-settings.json"), false), ("Terminal appearance", Path.Combine(runtime.Root.DirectoryPath, "state", "terminal-appearance.json"), false) })
      {
        var row = new StackPanel { Spacing = 6 }; row.Children.Add(new TextBlock { Text = label + "\n" + path, TextWrapping = TextWrapping.Wrap });
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; var copy = new Button { Content = "Copy path" };
        copy.Click += (_, _) => { var data = new DataPackage(); data.SetText(path); Clipboard.SetContent(data); notice.Text = "Path copied."; }; controls.Children.Add(copy);
        var open = new Button { Content = directory ? "Open folder" : "Reveal file", IsEnabled = directory ? Directory.Exists(path) : File.Exists(path) };
        open.Click += (_, _) =>
        {
          try { var launch = new ProcessStartInfo("explorer.exe") { UseShellExecute = true }; launch.ArgumentList.Add(directory ? path : "/select," + path); Process.Start(launch); }
          catch (Exception e) when (e is IOException or System.ComponentModel.Win32Exception or InvalidOperationException) { notice.Text = "Windows could not open this path."; }
        };
        controls.Children.Add(open); row.Children.Add(controls); body.Children.Add(row);
      }
    }
    body.Children.Add(new TextBlock { Text = "Restore app defaults", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
    body.Children.Add(new TextBlock { Text = "Resets General, notifications, terminal appearance, window theme, close confirmation and browser preferences. Browser tabs close when the saved sign-in mode changes. Projects, sessions, accounts, agents and saved palettes are kept.", TextWrapping = TextWrapping.Wrap });
    var reset = new Button { Content = "Reset app settings…" }; reset.Click += async (_, _) => await ResetAsync(); body.Children.Add(reset); body.Children.Add(notice);
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
    { notice.Text = "The settings reset could not finish. " + e.Message; return; }
    var failed = result.Failed;
    notice.Text = failed.Length == 0 ? "App preferences are back to defaults. Projects, accounts and sessions were kept." : "Some preferences reset. Retry these: " + string.Join(", ", failed);
    Render();
  }
}
