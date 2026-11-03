using System.Security.Cryptography;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Windowing;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels.Servers;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Servers;
using TerminalDeck.Core.Storage;
using Windows.Graphics;

namespace TerminalDeck.App.Views.Servers;

internal interface IServerSettingsWindowHost
{
  AppDataRoot SettingsStateRoot { get; }
  void OwnServerSettingsWindow(Window window, FrameworkElement root);
}

internal static class ServerSettingsWindow
{
  private sealed record Entry(Window Window, ServersViewModel Model, TaskCompletionSource Closed);
  private static readonly Dictionary<(IServers, string), Entry> open = [];
  private static bool Proof => Environment.GetEnvironmentVariable("TD_PARITY_PROOF") is not null || Environment.GetEnvironmentVariable("TD_W13_PROOF") is not null || Environment.GetEnvironmentVariable("TD_W12_OFFSCREEN") == "1";
  public static Task ShowAsync(XamlRoot owner, ServersViewModel source, IServerPageHost host, string id, string section)
  {
    var key = (source.Servers, id);
    if (open.TryGetValue(key, out var existing))
    {
      existing.Model.Tab(section);
      if (!Proof) { if (existing.Window.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore(); existing.Window.Activate(); }
      return existing.Closed.Task;
    }
    var server = source.Servers.Get(id, ServerCaller.Person); var model = new ServersViewModel(source.Servers); model.Select(id); model.Tab(section);
    var window = new Window { Title = server.Name + " — Server settings" }; var page = new ServersPage(model, host, settingsWindow: true);
    var root = new Grid { RequestedTheme = owner.Content is FrameworkElement element ? element.ActualTheme : ElementTheme.Default };
    var drag = new Grid { Height = 32, VerticalAlignment = VerticalAlignment.Top, Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent) }; root.Children.Add(page); root.Children.Add(drag); window.Content = root;
    window.ExtendsContentIntoTitleBar = true; window.SetTitleBar(drag);
    WindowMaterials.Attach(window, root);
    var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); open[key] = new(window, model, closed);
    JsonStateStore<SettingsWindowPlacement>? store = host is IServerSettingsWindowHost stateHost ? new(stateHost.SettingsStateRoot, "server-window-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(id)))[..24]) : null;
    var scale = Math.Max(1, owner.RasterizationScale); SettingsWindowPlacement? placement = null;
    if (!Proof && store is not null) try { placement = store.Load(); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.Json.JsonException) { }
    if (placement is not null && (!double.IsFinite(placement.Scale) || placement.Scale <= 0 || placement.Width <= 0 || placement.Height <= 0)) placement = null;
    var requested = placement ?? new SettingsWindowPlacement(80, 80, (int)Math.Round(560 * scale), (int)Math.Round(520 * scale), scale);
    var work = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
    var fitted = requested.Fit(new(work.X, work.Y, work.Width, work.Height), scale, 520, 440);
    window.AppWindow.MoveAndResize(new RectInt32(fitted.X, fitted.Y, fitted.Width, fitted.Height));
    if (window.AppWindow.Presenter is OverlappedPresenter native) { native.IsResizable = true; native.IsMinimizable = true; native.IsMaximizable = false; }
    if (host is IServerSettingsWindowHost ownerHost) ownerHost.OwnServerSettingsWindow(window, root);
    void Save()
    {
      if (Proof || store is null || window.AppWindow.Position.X < -10000 || window.AppWindow.Presenter is OverlappedPresenter { State: not OverlappedPresenterState.Restored }) return;
      try { store.Save(new(window.AppWindow.Position.X, window.AppWindow.Position.Y, window.AppWindow.Size.Width, window.AppWindow.Size.Height, root.XamlRoot?.RasterizationScale ?? scale)); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }
    var ownerElement = owner.Content as FrameworkElement;
    void Theme(FrameworkElement sender, object args) => root.RequestedTheme = sender.ActualTheme;
    if (ownerElement is not null) ownerElement.ActualThemeChanged += Theme;
    Action changed = () => window.DispatcherQueue.TryEnqueueHandled(() => { if (model.Selected is { } current) window.Title = current.Name + " — Server settings"; }); model.Changed += changed;
    window.AppWindow.Changed += (_, args) => { if (args.DidPositionChange || args.DidSizeChange) Save(); };
    window.AppWindow.Closing += (_, _) => Save();
    window.Closed += (_, _) => { if (ownerElement is not null) ownerElement.ActualThemeChanged -= Theme; model.Changed -= changed; root.Children.Clear(); window.Content = null; open.Remove(key); source.Refresh(); closed.TrySetResult(); };
    if (Proof) { window.AppWindow.Move(new PointInt32(-20000, -20000)); window.AppWindow.Show(false); } else window.Activate();
    _ = model.LoadSettingsAsync();
    return closed.Task;
  }
}
