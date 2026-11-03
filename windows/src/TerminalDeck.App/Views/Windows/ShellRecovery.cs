using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage;
using Windows.System;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private bool shellRecoveryRequired;

  private void InitializeRecoveryActions()
  {
    var actions = new Button { Content = "Recovery" };
    shellRecoveryAction = actions;
    var menu = new MenuFlyout();
    var retry = new MenuFlyoutItem { Text = "Retry connection" };
    retry.Click += async (_, _) =>
    {
      retry.IsEnabled = false;
      try { await RetryShellConnectionAsync(); } finally { retry.IsEnabled = true; }
    };
    var log = new MenuFlyoutItem { Text = "Show log" };
    log.Click += async (_, _) =>
    {
      await OpenShellLogAsync();
    };
    menu.Items.Add(retry); menu.Items.Add(log); actions.Flyout = menu;
  }
  private async Task RetryShellConnectionAsync()
  {
    Model.Notice = "Reconnecting to the session service…";
    try { await Runtime.ReconnectAsync(); await Runtime.RefreshSessionsAsync(); shellRecoveryRequired = false; Model.Notice = Ready.IsCompletedSuccessfully ? "Connected. Your running sessions were kept." : "Session connection restored. Reopen the app to finish loading its pages. Your sessions stay running."; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { shellRecoveryRequired = true; UiRecovery.Log("Shell reconnect", ex); Model.Notice = "The session service is still unavailable. Existing terminals were left alone. Use Show log for details."; }
  }
  private async Task OpenShellLogAsync()
  {
    try
    {
      var folder = Path.Combine(dataRoot.DirectoryPath, "logs"); Directory.CreateDirectory(folder);
      if (!await Launcher.LaunchFolderAsync(await StorageFolder.GetFolderFromPathAsync(folder))) Model.Notice = "Explorer could not open the log folder.";
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Model.Notice = "The log folder could not open. It is under logs in this app’s data folder."; }
  }

}
