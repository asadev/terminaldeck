using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace TerminalDeck.App.Views;

// Opening the app looks for an update on the public GitHub releases (release 27: the signed release manifest the
// Mac app reads too). A newer version shows as a card in the side panel just above Settings: "Update available ·
// 0.21.0", Restart to update, What's new, and × to hide it until a newer version. Terminal Deck restarts to update
// by itself only while nobody is at this PC (or typing into a session) and no coding AI is mid-turn, in a chat or
// in a terminal; the keeper then hands its sessions over and Windows reopens Terminal Deck on the new version.
// Otherwise the person keeps the button, and the app looks again each minute until it is free (or they click).
// When Windows already applied the update by itself (the app was closed, its keeper ran on), there is nothing to
// install but the sessions still run on an older build's keeper: they move to this build's keeper the same way, when
// free. A newer build's keeper is never moved onto this one.
public sealed partial class ShellWindow
{
  private int updateCheckRunning;
  private DispatcherQueueTimer? updateRetry;
  private bool updateWaitShown;
  private bool updateEventsHooked;
  private DispatcherQueueTimer? updatePoll;
  // What the card says while something is under way or went wrong (null: the plain offer).
  private string? updateCardDetail;
  private bool updateCardBusy;
  private string UpdateDismissFile => Path.Combine(Runtime.Root.DirectoryPath, "updates", "dismissed-version");
  internal async Task CheckForUpdateOnOpenAsync()
  {
    if (!updateEventsHooked)
    {
      updateEventsHooked = true;
      Services.WindowsUpdateStatus.Changed += () => DispatcherQueue.TryEnqueue(RenderUpdateCard);
      // A release published while the app stays open shows within six hours, not only at the next open.
      updatePoll = DispatcherQueue.CreateTimer(); updatePoll.Interval = TimeSpan.FromHours(6); updatePoll.IsRepeating = true;
      updatePoll.Tick += (_, _) => { if (!Services.WindowsUpdateStatus.Available) _ = CheckForUpdateOnOpenAsync(); };
      updatePoll.Start();
    }
    if (Interlocked.Exchange(ref updateCheckRunning, 1) == 1) return;
    try
    {
      var update = Services.WindowsUpdateStatus.HasUpdateSource() && await Services.WindowsUpdateStatus.IsUpdateAvailableAsync();
      if (!update && !Runtime.KeeperFromOlderBuild()) return;
      await RestartWhenFreeAsync();
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { UiRecovery.Log("Update check on open", ex); }
    finally { Interlocked.Exchange(ref updateCheckRunning, 0); }
  }
  private async Task RestartWhenFreeAsync()
  {
    // Look at the PC, download (~270 MB, minutes), look AGAIN right before the restart (Reviewer #9, 4 Nov). A busy
    // answer waits for the next quiet moment; the checked download is kept and reused then.
    try
    {
      await TerminalDeck.Core.Platform.UpdateReadiness.RestartWhenFreeAsync(Runtime.UpdateWaitReasonAsync, Services.WindowsUpdateStatus.Available,
        Runtime.PrepareUpdateAsync, RestartToUpdateAsync, _ =>
        {
          if (!updateWaitShown) { updateWaitShown = true; ShowUpdateNotice(Services.WindowsUpdateStatus.UpdateWaitingText); }
          StartUpdateRetry();
        });
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      UiRecovery.Log("Download the update", ex);
      ShowUpdateNotice("The update could not be downloaded. Nothing was changed. " + ex.Message);
    }
  }
  private void StartUpdateRetry()
  {
    if (updateRetry is not null) return;
    updateRetry = DispatcherQueue.CreateTimer(); updateRetry.Interval = TimeSpan.FromMinutes(1); updateRetry.IsRepeating = true;
    updateRetry.Tick += async (_, _) =>
    {
      if (Interlocked.Exchange(ref updateCheckRunning, 1) == 1) return;
      try { if (Services.WindowsUpdateStatus.Available || Runtime.KeeperFromOlderBuild()) await RestartWhenFreeAsync(); else StopUpdateRetry(); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { UiRecovery.Log("Update retry", ex); }
      finally { Interlocked.Exchange(ref updateCheckRunning, 0); }
    };
    updateRetry.Start();
  }
  private void StopUpdateRetry() { updateRetry?.Stop(); updateRetry = null; updateWaitShown = false; }
  private int restartRunning;
  private async Task RestartToUpdateAsync()
  {
    // One handover at a time (the button and the minute check can meet).
    if (Interlocked.Exchange(ref restartRunning, 1) == 1) return;
    StopUpdateRetry();
    // Nothing to install but the sessions still run on an older build's keeper: move them (Reviewer #9 merge condition b).
    var move = !Services.WindowsUpdateStatus.Available && Runtime.KeeperFromOlderBuild();
    ShowUpdateNotice(move ? "Moving your sessions to this version. They reopen in a moment." : "Downloading and checking the update. Your sessions are saved and reopen after the update.", action: false, busy: true);
    try
    {
      Model.Notice = move ? await Runtime.MoveSessionsToThisBuildAsync() : await Runtime.RestartToUpdateAsync();
      ShowUpdateNotice(null);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      UiRecovery.Log("Restart to update", ex);
      ShowUpdateNotice("The update could not be applied. Your sessions were kept. " + ex.Message);
    }
    finally { Interlocked.Exchange(ref restartRunning, 0); }
  }
  private void ShowUpdateNotice(string? message, bool action = true, bool busy = false)
  {
    updateCardDetail = message; updateCardBusy = busy || !action;
    RenderUpdateCard();
  }
  private string? DismissedUpdate()
  {
    try { return File.Exists(UpdateDismissFile) ? File.ReadAllText(UpdateDismissFile).Trim() : null; }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
  }
  private void DismissUpdate(string version)
  {
    try { Directory.CreateDirectory(Path.GetDirectoryName(UpdateDismissFile)!); File.WriteAllText(UpdateDismissFile, version); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { UiRecovery.Log("Hide update", ex); }
    updateCardDetail = null;
    RenderUpdateCard();
  }
  // The card above Settings: only real state from WindowsUpdateStatus; nothing restarts from here but the button.
  private void RenderUpdateCard()
  {
    var offered = Services.WindowsUpdateStatus.Offered;
    var percent = Services.WindowsUpdateStatus.DownloadPercent;
    // Windows applied the update by itself: no offer, but the sessions still run on the previous build's keeper.
    var moving = offered is null && Runtime.KeeperFromOlderBuild();
    var dismissed = offered is not null && !updateCardBusy && percent is null && DismissedUpdate() == offered.Version;
    if (offered is null && !moving && updateCardDetail is null || dismissed) { UpdateCard.Visibility = Visibility.Collapsed; UpdateCard.Child = null; return; }
    var accent = Application.Current.Resources.TryGetValue("AccentFillColorDefaultBrush", out var brush) && brush is SolidColorBrush solid ? solid.Color : Microsoft.UI.Colors.DodgerBlue;
    UpdateCard.Background = new SolidColorBrush(accent) { Opacity = 0.12 };
    var stack = new StackPanel { Spacing = 6 };
    var head = new Grid { ColumnSpacing = 6 };
    head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
    head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
    head.Children.Add(new TextBlock
    {
      Text = moving ? "Finish the update" : offered is null ? "The update did not go through" : percent is { } p ? "Downloading " + Services.WindowsUpdateStatus.ShortVersion(offered.Version) + " · " + p + "%" : Services.WindowsUpdateStatus.AvailableText(offered.Version),
      FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap
    });
    if (offered is not null && !updateCardBusy && percent is null)
    {
      var close = new Button { Content = new FontIcon { Glyph = "", FontSize = 10 }, Padding = new Thickness(4), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
      ToolTipService.SetToolTip(close, "Hide this until a newer version comes out. Settings › General › Check for updates brings it back.");
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(close, "Hide this update");
      var version = offered.Version;
      close.Click += (_, _) => DismissUpdate(version);
      Grid.SetColumn(close, 1); head.Children.Add(close);
    }
    stack.Children.Add(head);
    if (percent is { } progress) stack.Children.Add(new ProgressBar { Minimum = 0, Maximum = 100, Value = progress });
    else if (updateCardBusy) stack.Children.Add(new ProgressBar { IsIndeterminate = true });
    stack.Children.Add(new TextBlock
    {
      Text = updateCardDetail ?? (moving ? "Your sessions still run on the previous version. They move to this one when no AI is working and nobody is using this PC, or click Restart to update." : Services.WindowsUpdateStatus.UpdateAvailableText), TextWrapping = TextWrapping.Wrap,
      Style = Application.Current.Resources["CaptionTextBlockStyle"] as Style, Foreground = Application.Current.Resources["TextFillColorSecondaryBrush"] as Brush
    });
    var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
    if ((offered is not null || moving) && !updateCardBusy && percent is null)
    {
      var restart = new Button { Content = Services.WindowsUpdateStatus.RestartLabel, Style = Application.Current.Resources["AccentButtonStyle"] as Style };
      restart.Click += async (_, _) => { restart.IsEnabled = false; try { await RestartToUpdateAsync(); } finally { restart.IsEnabled = true; } };
      row.Children.Add(restart);
    }
    if (offered?.NotesUrl is { } notes) row.Children.Add(new HyperlinkButton { Content = "What’s new", NavigateUri = notes, Padding = new Thickness(0) });
    if (offered is null && !moving)
    {
      var hide = new HyperlinkButton { Content = "Hide", Padding = new Thickness(0) };
      hide.Click += (_, _) => { updateCardDetail = null; RenderUpdateCard(); };
      row.Children.Add(hide);
    }
    if (row.Children.Count > 0) stack.Children.Add(row);
    UpdateCard.Child = stack;
    UpdateCard.Visibility = Visibility.Visible;
  }
}
