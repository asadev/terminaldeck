using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Views;
using TerminalDeck.Core;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App;

public partial class App : Application
{
  private Window? window;
  private Services.TaskCoordinatorHost? taskCoordinatorHost;
  public App()
  {
    UnhandledException += (_, args) =>
    {
      if (!RecoveryContext.Recoverable(args.Exception)) return;
      UiRecovery.Report("App.UnhandledException: " + args.Message, args.Exception);
      args.Handled = true;
    };
    TaskScheduler.UnobservedTaskException += (_, args) =>
    {
      UiRecovery.Log("TaskScheduler.UnobservedTaskException", args.Exception);
      args.SetObserved();
    };
    AppDomain.CurrentDomain.UnhandledException += (_, args) =>
    {
      if (args.ExceptionObject is Exception error) UiRecovery.Log("AppDomain.UnhandledException", error);
    };
    InitializeComponent();
  }
  private static bool DevelopmentRun => Environment.GetEnvironmentVariable("TD_DEV") == "1" || Environment.GetEnvironmentVariable("TD_TEST") == "1";

  private void PrepareRecovery(AppDataRoot root)
  {
    var production = Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TerminalDeck"));
    if (DevelopmentRun && (string.Equals(root.DirectoryPath, StableChannel.Root(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)).DirectoryPath, StringComparison.OrdinalIgnoreCase) || string.Equals(root.DirectoryPath, production, StringComparison.OrdinalIgnoreCase) || root.DirectoryPath.StartsWith(production + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)))
      throw new ArgumentException("Choose a separate scratch folder.");
    UiRecovery.Initialize(root.DirectoryPath, message =>
    {
      if (window is ShellWindow shell) shell.ShowRecoveryError(message);
      else
      {
        window ??= new Window { Title = Brand.Name };
        window.Content = new TextBlock { Text = message, Margin = new Thickness(24), TextWrapping = TextWrapping.Wrap };
        window.Activate();
      }
    });
  }

  protected override async void OnLaunched(LaunchActivatedEventArgs args)
  {
    try
    {
      var command = Environment.GetCommandLineArgs().Skip(1).Where(a => a != "--start-minimized").ToArray();
      if (command.Length > 0) PrepareRecovery(AppDataRoot.FromArguments(command, DevelopmentRun));
      var activation = Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().GetActivatedEventArgs();
      // Shares use the same root previously selected by an explicit launch.
      var root = DevelopmentRun && activation.Kind == Microsoft.Windows.AppLifecycle.ExtendedActivationKind.ShareTarget && !command.Any(a => a.StartsWith("--user-data-dir", StringComparison.Ordinal))
        ? TerminalDeck.Platform.Windows.Integration.PreviewShareRoot.Resolve()
        : AppDataRoot.FromArguments(command, DevelopmentRun);
      PrepareRecovery(root);
      if (Environment.GetEnvironmentVariable("TD_CRASH_DIAGNOSTICS") == "1")
      {
        var count = 0;
        AppDomain.CurrentDomain.FirstChanceException += (_, error) =>
        {
          if (Interlocked.Increment(ref count) <= 100)
            UiRecovery.Log("FirstChance", error.Exception);
        };
      }
      var instance = Microsoft.Windows.AppLifecycle.AppInstance.FindOrRegisterForKey("terminaldeck-preview-" + root.NamespaceId);
      if (!instance.IsCurrent) { await instance.RedirectActivationToAsync(activation); Exit(); return; }
      TerminalDeck.Platform.Windows.Integration.PreviewShareRoot.Remember(root);
      taskCoordinatorHost = Services.TaskCoordinatorHost.Register(root);
      var shell = new ShellWindow(root); window = shell;
      shell.Closed += (_, _) => taskCoordinatorHost?.Dispose();
      instance.Activated += (_, incoming) => { shell.QueueReceiverActivation(incoming); shell.DispatcherQueue.TryEnqueue(() => _ = shell.CheckForUpdateOnOpenAsync()); };
      shell.QueueReceiverActivation(activation);
    }
    catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException)
    {
      UiRecovery.Log("Launch validation or IO", ex);
      window = new Window { Title = Brand.Name, Content = new TextBlock { Text = DevelopmentRun ? "This development run needs --user-data-dir with a separate scratch folder. No data was opened." : "Your saved data could not be opened. " + ex.Message, Margin = new Thickness(32), TextWrapping = TextWrapping.Wrap } };
    }
    catch (Exception error) when (RecoveryContext.Recoverable(error))
    {
      UiRecovery.Report("Launch", error);
    }
    if (Environment.GetCommandLineArgs().Contains("--start-minimized"))
    {
      // Never take the active window from the person: show without activating, then minimise without activating.
      window?.AppWindow.Show(false);
      if (window?.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter) presenter.Minimize(false);
    }
    else if (new[] { "TD_W12_SHELL_PROOF", "TD_SETTINGS_PROOF", "TD_W13_PROOF" }.Any(key => Environment.GetEnvironmentVariable(key) is not null)) window?.AppWindow.Show(false);
    else window?.Activate();
  }
}
