using System.Text.Json;
using Microsoft.UI.Windowing;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Input;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Storage;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private SettingsPanel? settingsPanel;
  private Window? settingsWindow = null;
  private Grid? settingsWindowRoot = null;
  private ShellPage settingsReturnPage = ShellPage.Sessions;
  private JsonStateStore<SettingsAppearance>? settingsAppearance;

  // Called once by the shell, after its existing SettingsPane has been constructed.
  private void InitializeSettingsPanel()
  {
    settingsAppearance = new(dataRoot, "appearance");
    InitializeSettingsGeometry();
    Runtime.Accounts.Changed += () => DispatcherQueue.TryEnqueueHandled(RenderWindows);
    try { Root.RequestedTheme = ParseSettingsTheme(settingsAppearance.Load()?.Theme ?? "system"); }
    catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException or ArgumentException)
    { Model.Notice = "The saved appearance could not be read. Choose it again in Settings."; }
    Closed += (_, _) => { settings.CloseServerEditors(); settingsWindow?.Close(); settingsWindow = null; devicesWindow?.Close(); };
    Root.ActualThemeChanged += (_, _) =>
    {
      if (settingsPanel is not null) settingsPanel.RequestedTheme = Root.RequestedTheme;
      if (settingsWindowRoot is not null) settingsWindowRoot.RequestedTheme = Root.RequestedTheme;
    };
    InitializeSettingsProof();
    InitializeSettingsWindowProof();
  }

  [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
  private static extern nint SetSettingsOwner(nint window, int index, nint owner);

  private void ShowSettingsPanel()
  {
    settingsReturnPage = renderedPage is { } previous && previous != ShellPage.Settings ? previous : settingsReturnPage;
    if (Model.Page == ShellPage.Settings) Model.Page = settingsReturnPage;
    if (settingsWindow is { } existing)
    {
      if (existing.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore();
      ShowSettingsOwnedWindow(existing);
      return;
    }
    settingsPanel ??= CreateSettingsPanel();
    var window = new Window { Title = "Settings — " + TerminalDeck.Core.Brand.Name };
    // WinUI cannot format OEM comma as an automatic accelerator tooltip.
    // The window still handles Ctrl+,; its shortcut reference is in More and Ctrl+/.
    var root = new Grid { RequestedTheme = Root.RequestedTheme, KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden };
    root.Children.Add(settingsPanel); window.Content = root;
    WindowMaterials.Attach(window, root, kind: Microsoft.UI.Composition.SystemBackdrops.MicaKind.Base);
    settingsWindow = window; settingsWindowRoot = root;
    var settingsShortcut = new KeyboardAccelerator { Key = (Windows.System.VirtualKey)188, Modifiers = Windows.System.VirtualKeyModifiers.Control };
    settingsShortcut.Invoked += (_, args) => { ShowSettingsPanel(); args.Handled = true; };
    root.KeyboardAccelerators.Add(settingsShortcut);
    // An owned top-level HWND stays above this shell without becoming globally topmost.
    var handle = WinRT.Interop.WindowNative.GetWindowHandle(window);
    Marshal.SetLastPInvokeError(0);
    SetSettingsOwner(handle, -8, WinRT.Interop.WindowNative.GetWindowHandle(this));
    if (Marshal.GetLastPInvokeError() != 0) throw new System.ComponentModel.Win32Exception(Marshal.GetLastPInvokeError());
    if (window.AppWindow.Presenter is OverlappedPresenter native)
    {
      native.IsResizable = true; native.IsMinimizable = true; native.IsMaximizable = false;
    }
    window.ExtendsContentIntoTitleBar = true;
    window.SetTitleBar(settingsPanel.DragArea);
    void UpdateCaption()
    {
      var bar = window.AppWindow.TitleBar;
      bar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
      bar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
      bar.ButtonForegroundColor = ((SolidColorBrush)ShellTheme.Resource(root, "DeckInkBrush")).Color;
      bar.ButtonInactiveForegroundColor = bar.ButtonForegroundColor;
      bar.ButtonHoverBackgroundColor = ((SolidColorBrush)ShellTheme.Resource(root, "DeckHoverBrush")).Color;
    }
    root.ActualThemeChanged += (_, _) => UpdateCaption();
    root.Loaded += (_, _) => UpdateCaption();
    window.AppWindow.Closing += (_, _) => SaveSettingsWindowBounds(window);
    window.Closed += (_, _) =>
    {
      root.Children.Clear(); window.Content = null;
      settingsWindow = null; settingsWindowRoot = null;
    };
    RestoreSettingsWindowBounds(window);
    settingsPanel.Loaded += FocusSettingsCategory;
    UpdateCaption(); ShowSettingsOwnedWindow(window);
  }
  private void FocusSettingsCategory(object sender, RoutedEventArgs args)
  {
    if (settingsPanel is null) return;
    settingsPanel.Loaded -= FocusSettingsCategory;
    var selected = WorkspaceVisuals.Tree(settingsPanel).OfType<ListView>().Select(list => list.SelectedItem).OfType<Control>().FirstOrDefault();
    selected?.Focus(FocusState.Programmatic);
  }
  private SettingsPanel CreateSettingsPanel()
  {
    var navigation = new JsonStateStore<SettingsNavigationState>(dataRoot, "settings-navigation");
    var initial = "general";
    try { initial = navigation.Load()?.Section ?? initial; _ = SettingsNavigation.Canonical(initial); }
    catch (Exception ex) when (ex is IOException or JsonException or ArgumentException or UnauthorizedAccessException) { initial = "general"; }
    if (SettingsNavigation.IsHoot(initial)) initial = "general";
    if (initial == "mcp") initial = "outside-ai-apps";
    if (initial == "devices") initial = "general";
    var panel = new SettingsPanel(settings, () => Root.RequestedTheme, SaveSettingsTheme, initial);
    panel.NavigationChanged += section =>
    {
      try { navigation.Save(new(section)); }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Model.Notice = "The Settings destination could not be remembered."; }
    };
    panel.CloseRequested += CloseSettingsPanel;
    panel.OpenMainPage = name =>
    {
      if (!Enum.TryParse<ShellPage>(name, out var destination)) return false;
      CloseSettingsPanel(); Model.Page = destination; return true;
    };
    return panel;
  }
  private void CloseSettingsPanel()
  {
    settingsWindow?.Close();
    if (Model.Page == ShellPage.Settings) Model.Page = settingsReturnPage;
  }

  internal static void ShowSettingsOwnedWindow(Window window)
  {
    if (Environment.GetEnvironmentVariable("TD_SETTINGS_PROOF") is not null || Environment.GetEnvironmentVariable("TD_W10_PROOF") is not null || Environment.GetEnvironmentVariable("TD_W13_PROOF") is not null || W12Proof)
    { window.AppWindow.Move(new(-20000, -20000)); window.AppWindow.Show(false); }
    else window.Activate();
  }

  private void SaveSettingsTheme(ElementTheme theme)
  {
    if (settingsAppearance is null) throw new InvalidOperationException("Settings is not ready yet.");
    settingsAppearance.Save(new(theme switch { ElementTheme.Light => "light", ElementTheme.Dark => "dark", _ => "system" }));
    Root.RequestedTheme = theme;
    if (settingsWindowRoot is not null) settingsWindowRoot.RequestedTheme = theme;
    if (settingsPanel is not null) settingsPanel.RequestedTheme = theme;
  }

  private static ElementTheme ParseSettingsTheme(string theme) => theme switch
  { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, "system" => ElementTheme.Default, _ => throw new ArgumentException("Choose system, light or dark appearance.") };
}

public sealed record SettingsAppearance(string Theme);

public sealed record SettingsNavigationState(string Section);
