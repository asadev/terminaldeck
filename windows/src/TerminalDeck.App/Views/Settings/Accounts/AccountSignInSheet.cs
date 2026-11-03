using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Windowing;
using TerminalDeck.App.Integration;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Platform;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Views;

internal static class AccountSignInSheet
{
  private sealed record OpenFlow(Window Window, Func<AccountSignInFlow> Read, Func<Task> Retry, Task Closed);
  private static readonly Dictionary<string, OpenFlow> active = [];
  private static readonly Dictionary<string, (AccountSignInState State, string Message)> previous = [];
  internal static async Task<JsonElement> ControlAsync(string accountId, string action)
  {
    if (action is not ("state" or "cancel")) throw new ArgumentException("Choose state or cancel.");
    if (active.TryGetValue(accountId, out var open) && action == "cancel") { open.Read().Cancel(); open.Window.Close(); await open.Closed; }
    var state = active.TryGetValue(accountId, out open) ? (open.Read().State, open.Read().Message) : previous.GetValueOrDefault(accountId);
    return JsonSerializer.SerializeToElement(new { accountId, state = state.Item2 is null ? "idle" : state.Item1.ToString().ToLowerInvariant(), message = state.Item2 ?? "No sign-in is open.", isOpen = active.ContainsKey(accountId), checkedAt = DateTimeOffset.UtcNow });
  }
  internal static Func<Window, CliTerminalView, Task>? PresentedForProof { get; set; }
  // An owned app window permits sign-in from Settings, an account switch, or
  // the new-session dialog while retaining all of the requesting view's state.
  public static async Task ShowAsync(AppRuntime runtime, AccountProfile account, string home, nint owner, FrameworkElement? themeOwner = null)
  {
    if (active.TryGetValue(account.Id, out var existing))
    {
      existing.Window.Activate();
      if (existing.Read().State == AccountSignInState.Failed) await existing.Retry();
      await existing.Closed;
      if (existing.Read().State != AccountSignInState.Succeeded) throw new SignInCancelledException();
      return;
    }
    var name = TerminalDeck.Core.Agents.AgentSeats.ProviderName(account.Provider);
    var window = new Window { Title = "Sign in to " + name };
    SetOwner(window, owner);
    var content = new Grid { Padding = new Thickness(24), RowSpacing = 16, RequestedTheme = themeOwner?.ActualTheme ?? ElementTheme.Default };
    content.SetResourceReference(Grid.BackgroundProperty, "DeckCanvasBrush");
    void ThemeChanged(FrameworkElement sender, object args) => content.RequestedTheme = sender.ActualTheme;
    if (themeOwner is not null) themeOwner.ActualThemeChanged += ThemeChanged;
    window.Closed += (_, _) => { if (themeOwner is not null) themeOwner.ActualThemeChanged -= ThemeChanged; };
    content.RowDefinitions.Add(new() { Height = GridLength.Auto });
    content.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    content.RowDefinitions.Add(new() { Height = GridLength.Auto });
    var words = new TextBlock { TextWrapping = TextWrapping.Wrap };
    var progress = new ProgressBar { IsIndeterminate = true };
    var heading = new StackPanel { Spacing = 12, Children = { new TextBlock { Text = "Sign in to " + name, FontSize = 22, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }, words, progress } };
    content.Children.Add(heading);
    var terminalHost = new Grid(); Grid.SetRow(terminalHost, 1); content.Children.Add(terminalHost);
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, HorizontalAlignment = HorizontalAlignment.Right };
    var retry = new Button { Content = "Try again", Visibility = Visibility.Collapsed };
    var cancel = new Button { Content = "Cancel" }; actions.Children.Add(retry); actions.Children.Add(cancel); Grid.SetRow(actions, 2); content.Children.Add(actions);
    window.Content = content; window.AppWindow.Resize(new(840, 620));
    AccountSignInFlow flow = new(); CliTerminalView? terminal = null;
    using var lifetime = new CancellationTokenSource();
    var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var checking = false;
    async Task VerifyAsync(bool exited = false, int? exitCode = null)
    {
      if (closed.Task.IsCompleted || checking && !exited) return;
      checking = true;
      try { await flow.CheckAsync(async ct => (await runtime.Accounts.RefreshAsync(account.Id, ct)).SignedIn, exited, lifetime.Token, exitCode); }
      catch (OperationCanceledException) { }
      finally { checking = false; }
    }
    void Update() => content.DispatcherQueue.TryEnqueueHandled(() =>
    {
      if (closed.Task.IsCompleted) return;
      words.Text = flow.Message;
      progress.Visibility = flow.State is AccountSignInState.Starting or AccountSignInState.Waiting ? Visibility.Visible : Visibility.Collapsed;
      retry.Visibility = flow.State == AccountSignInState.Failed ? Visibility.Visible : Visibility.Collapsed;
      cancel.Content = flow.State == AccountSignInState.Failed ? "Close" : "Cancel";
      if (flow.State == AccountSignInState.Succeeded) window.Close();
    });
    async Task StartAsync()
    {
      if (terminal is not null) await terminal.DisposeAsync(); terminalHost.Children.Clear();
      flow = new(); flow.Changed += Update; Update();
      try
      {
        var planner = new WindowsProviderLaunchPlanner(runtime.Root, WindowsProviderLaunchPlanner.BundledToolsDirectory);
        var launch = planner.Plan(new(new(Guid.NewGuid().ToString(), account.Provider, home, "Sign in", account.Id, account.HomeId, Purpose: "sign-in"), "sign-in", TerminalDeck.Core.Sessions.SessionState.Starting), false);
        if (Environment.GetEnvironmentVariable("TD_SIGNIN_PROOF") is not null && File.Exists(Path.Combine(runtime.Root.DirectoryPath, ".signin-proof")))
        {
          var proofEnvironment = new Dictionary<string, string>(launch.Environment, StringComparer.OrdinalIgnoreCase) { ["BROWSER"] = Path.Combine(runtime.Root.DirectoryPath, "proof-browser.cmd") };
          launch = launch with { Environment = proofEnvironment };
        }
        terminal = new(launch, runtime.Root); terminalHost.Children.Add(terminal); flow.Started();
        var thisFlow = flow; var thisTerminal = terminal;
        _ = ObserveExitAsync();
        if (PresentedForProof is { } proof) _ = proof(window, thisTerminal);
        async Task ObserveExitAsync()
        {
          try { var code = await thisTerminal.Exited; if (thisFlow == flow) await VerifyAsync(true, code); }
          catch (OperationCanceledException) { }
          catch (IOException) { if (thisFlow == flow) thisFlow.Fail("The AI’s sign-in could not open. Check Coding AIs and try again."); }
        }
      }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException)
      { flow.Fail(ex is ProviderUnavailableException ? ex.Message : "The AI’s sign-in could not open. Try again."); }
    }
    void AccountChanged() => content.DispatcherQueue.TryEnqueueHandled(async () => await VerifyAsync());
    runtime.Accounts.Changed += AccountChanged;
    retry.Click += async (_, _) => await StartAsync();
    cancel.Click += (_, _) => { flow.Cancel(); window.Close(); };
    window.Closed += (_, _) => { flow.Cancel(); lifetime.Cancel(); previous[account.Id] = (flow.State, flow.Message); active.Remove(account.Id); closed.TrySetResult(); };
    active[account.Id] = new(window, () => flow, StartAsync, closed.Task);
    window.Activate(); await StartAsync(); await closed.Task;
    previous[account.Id] = (flow.State, flow.Message); active.Remove(account.Id);
    runtime.Accounts.Changed -= AccountChanged;
    if (terminal is not null) await terminal.DisposeAsync();
    if (flow.State != AccountSignInState.Succeeded) throw new SignInCancelledException();
  }
  internal static void SetOwner(Window window, nint owner)
  {
    if (owner != 0) SetWindowLongPtr(WinRT.Interop.WindowNative.GetWindowHandle(window), -8, owner);
    var presenter = OverlappedPresenter.CreateForDialog(); presenter.IsResizable = true;
    window.AppWindow.SetPresenter(presenter);
  }
  [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
  private static extern nint SetWindowLongPtr(nint window, int index, nint value);
}
