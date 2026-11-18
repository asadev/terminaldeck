using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views.Settings;

/// Profile → Cloud (Mac, 15 Nov). Group 1: one row with a state dot and "Up to date" (or the one plain problem) and
/// "Sync now", then "Use Cloud on this PC"; then how this PC trusts your other devices. Every explanation sits behind
/// an info button. Every word comes from `CloudPageText` (tested in Core); this file only draws it and forwards the
/// person's own presses. Sign in starts here or from Profile, or from a terminaldeck://cloud/signin link after the
/// person says yes; never from a tool. The browser comes back on terminaldeck://cloud/return/… and the sign-in
/// finishes by itself (ShellWindow.Cloud.cs); nothing here asks again.
/// Not drawn (the Windows app has no such switch yet): one switch per kind of data.
public sealed partial class CloudPage : UserControl
{
  private readonly CloudAccountClient account;
  private readonly CloudSyncBridge? sync;
  private readonly Action<CloudSnapshot> changed;
  private readonly Action<CloudSyncState?> syncChanged;
  private bool syncing;
  private bool working;
  /// The plain words of the last trust press that changed nothing (a refusal), until the next press.
  private string? pressProblem;
  private Microsoft.UI.Xaml.Shapes.Ellipse? syncDot;
  private TextBlock? syncLine;
  private Button? syncNow;
  private Button? detailsToggle;
  private StackPanel? details;
  private TextBlock? detailsLine;
  private TextBlock? detailsChevron;
  private bool detailsOpen;
  /// "Manage files ›": opens the Your Cloud page in the main window (null in hosts without one).
  private readonly Action? manageFiles;
  private readonly Action? reviewDevices;

  public CloudPage(CloudAccountClient account, CloudSyncBridge? sync = null, Action? manageFiles = null, Action? reviewDevices = null)
  {
    this.account = account;
    this.sync = sync;
    this.manageFiles = manageFiles; this.reviewDevices = reviewDevices;
    InitializeComponent();
    Content = null; Content = SettingsPanel.Scroll(Body);
    changed = _ => DispatcherQueue.TryEnqueueHandled(Render);
    syncChanged = _ => DispatcherQueue.TryEnqueueHandled(UpdateSync);
    Loaded += (_, _) =>
    {
      account.Changed += changed; if (sync is not null) sync.StatusChanged += syncChanged; Render();
      if (account.Snapshot.Phase is CloudPhase.SignedIn or CloudPhase.Paused) _ = AccountPages.RefreshQuietlyAsync(account);
    };
    Unloaded += (_, _) => { account.Changed -= changed; if (sync is not null) sync.StatusChanged -= syncChanged; };
    ActualThemeChanged += (_, _) => UpdateSync();
    Render();
  }

  private void Render()
  {
    Body.Children.Clear(); syncDot = null; syncLine = null; syncNow = null; details = null; detailsLine = null; detailsToggle = null;
    var snapshot = account.Snapshot;
    if (!snapshot.Subscription.AllowsCloudServices) return;
    var summary = CloudPageText.Account(snapshot);
    var page = CloudPageText.For(snapshot);
    if (summary.Button is not null)
    {
      // Signed out or signing in: one line and a modest Sign in (or Cancel).
      var press = new Button { Content = page.Button ?? CloudPageText.SignIn, IsEnabled = !working, VerticalAlignment = VerticalAlignment.Center };
      press.Click += async (_, _) => await AccountPressAsync(press.Content as string);
      Body.Children.Add(SettingsPanel.GroupRows([SettingsPanel.SettingRow(page.Line, "", press)]));
    }
    else
    {
      syncDot = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center };
      syncLine = new TextBlock { FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
      AutomationProperties.SetAutomationId(syncLine, "settings.cloud.sync");
      syncNow = new Button { Content = CloudPageText.SyncNow, VerticalAlignment = VerticalAlignment.Center };
      syncNow.Click += async (_, _) => { if (!account.Snapshot.UseCloud) await UseCloudAsync(true); else await SyncNowAsync(); };
      AutomationProperties.SetAutomationId(syncNow, "settings.cloud.syncNow");
      var state = new Grid { ColumnSpacing = 10, MinHeight = 24 };
      state.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); state.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); state.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      detailsToggle = ProfilePage.QuietButton("");
      var statusWords = new Grid { ColumnSpacing = 5 };
      statusWords.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); statusWords.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      statusWords.Children.Add(syncLine);
      detailsChevron = SettingsPanel.StateText("⌄"); detailsChevron.FontSize = 10; Grid.SetColumn(detailsChevron, 1); statusWords.Children.Add(detailsChevron);
      detailsToggle.Content = statusWords; detailsToggle.HorizontalContentAlignment = HorizontalAlignment.Stretch;
      AutomationProperties.SetAutomationId(detailsToggle, "settings.cloud.status.details");
      detailsToggle.Click += (_, _) => { detailsOpen = !detailsOpen; UpdateSync(); };
      state.Children.Add(syncDot); Grid.SetColumn(detailsToggle, 1); state.Children.Add(detailsToggle); Grid.SetColumn(syncNow, 2); state.Children.Add(syncNow);
      details = new StackPanel { Spacing = 8, Margin = new(20, 4, 0, 6) };
      detailsLine = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap };
      detailsLine.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
      details.Children.Add(detailsLine);
      foreach (var notice in (page.Notices ?? []).Where(n => n.Action == CloudNoticeAction.TrustAgain))
      {
        var button = new Button { Content = notice.Button, IsEnabled = !working };
        button.Click += async (_, _) => await PressAsync(() => notice.Action == CloudNoticeAction.TrustAgain ? account.TrustAgainAsync(notice.DeviceId) : account.RemoveJoinedDeviceAsync(notice.DeviceId));
        details.Children.Add(SettingsPanel.SettingRow(notice.Text, "", button));
      }
      if ((page.Notices?.Count(n => n.Action == CloudNoticeAction.TrustAgain) ?? 0) > 0) detailsOpen = true;
      var waitingDevices = snapshot.DeviceRows.Count(d => !d.ThisDevice && d.Trust is { CanBeTrusted: true });
      if (waitingDevices > 0 && reviewDevices is not null)
      {
        var review = new Button { Content = "Review" }; review.Click += (_, _) => reviewDevices();
        AutomationProperties.SetAutomationId(review, "settings.cloud.reviewDevices");
        details.Children.Add(review); detailsOpen = true;
      }
      var statusGroup = new StackPanel(); statusGroup.Children.Add(state); statusGroup.Children.Add(details);
      Body.Children.Add(SettingsPanel.GroupRows([new Border { Child = statusGroup }]));
      var rows = new List<FrameworkElement>();
      if (page.UseCloud is { } on)
      {
        var toggle = new ToggleSwitch { IsOn = on, OnContent = "", OffContent = "", MinWidth = 40, IsEnabled = !working };
        toggle.Toggled += async (_, _) => await UseCloudAsync(toggle.IsOn);
        rows.Add(SettingsPanel.SettingRow(CloudPageText.UseCloudToggle, CloudPageText.UseCloudState(on), toggle));
      }
      if (rows.Count > 0) { Body.Children.Add(SettingsPanel.GroupTitle("Keep in sync on this PC")); Body.Children.Add(SettingsPanel.GroupRows(rows)); }
      if (page.TrustMode is { } mode)
      {
        var choice = new ToggleSwitch { IsOn = mode == CloudTrustMode.Ask, OnContent = "", OffContent = "", MinWidth = 40, IsEnabled = !working };
        AutomationProperties.SetAutomationId(choice, "settings.cloud.askForDevices");
        choice.Toggled += async (_, _) =>
        {
          var chosen = choice.IsOn ? CloudTrustMode.Ask : CloudTrustMode.Account;
          if (chosen != account.Snapshot.TrustMode) await PressAsync(() => account.SetTrustModeAsync(chosen));
        };
        Body.Children.Add(SettingsPanel.GroupRows([SettingsPanel.SettingRow("Ask me for each new device", CloudPageText.TrustModeNote(mode), choice)]));
      }
      UpdateSync();
      // The one way in to Your Cloud (DESIGN-WINDOWS-CLOUD.md 1): the page's last row.
      if (manageFiles is not null)
        Body.Children.Add(SettingsPanel.GroupRows([SettingsPanel.LinkRow(CloudContentsWords.OpenButton, null, null, null, manageFiles)]));
    }
    if ((pressProblem ?? (summary.Button is not null ? page.Problem ?? summary.Problem : null)) is { } problem) Body.Children.Add(AccountPages.Problem(problem));
  }

  // The state row: green "Up to date", blue while sending or receiving, orange with the one plain problem.
  private void UpdateSync()
  {
    if (syncDot is null || syncLine is null || syncNow is null) return;
    var snapshot = account.Snapshot;
    var state = snapshot.UseCloud ? sync?.Status : null;
    var (words, brush) = snapshot.Phase == CloudPhase.NotAllowed ? ("Not open for this account yet", "DeckProjectOrangeBrush")
      : !snapshot.UseCloud ? ("Off on this PC", "DeckSecondaryInkBrush")
      : state?.Phase switch
      {
        CloudSyncPhase.Level => ("Up to date", "DeckProjectGreenBrush"),
        CloudSyncPhase.Sending or CloudSyncPhase.Receiving => (state!.Line, "DeckSecondaryInkBrush"),
        CloudSyncPhase.Waiting => (state!.Line, "DeckProjectOrangeBrush"),
        CloudSyncPhase.Idle => ("Nothing to sync yet", "DeckSecondaryInkBrush"),
        _ => ("On", "DeckSecondaryInkBrush")
      };
    var notices = CloudPageText.For(snapshot).Notices?.Where(n => n.Action == CloudNoticeAction.TrustAgain).ToArray();
    var waitingDevices = snapshot.DeviceRows.Count(d => !d.ThisDevice && d.Trust is { CanBeTrusted: true });
    var explanation = snapshot.Problem ?? snapshot.TrustNotice ?? (state?.Phase == CloudSyncPhase.Waiting ? state.Line : null);
    if ((notices?.Length ?? 0) > 0) words = "A device needs a look";
    else if (waitingDevices > 0) words = waitingDevices == 1 ? "A new device needs a look" : $"{waitingDevices} new devices need a look";
    else if (explanation is not null) words = CloudCalmWords.Summary(explanation);
    syncLine.Text = words;
    syncLine.SetResourceReference(TextBlock.ForegroundProperty, "DeckInkBrush");
    if (detailsLine is not null) { detailsLine.Text = explanation ?? ""; detailsLine.Visibility = explanation is null ? Visibility.Collapsed : Visibility.Visible; }
    var hasDetails = explanation is not null || (notices?.Length ?? 0) > 0 || waitingDevices > 0 && reviewDevices is not null;
    if (detailsToggle is not null) { detailsToggle.IsHitTestVisible = hasDetails; detailsToggle.IsTabStop = hasDetails; ToolTipService.SetToolTip(detailsToggle, hasDetails ? "Show details" : null); }
    if (detailsChevron is not null) { detailsChevron.Text = detailsOpen ? "⌃" : "⌄"; detailsChevron.Visibility = hasDetails ? Visibility.Visible : Visibility.Collapsed; }
    if (details is not null) details.Visibility = hasDetails && detailsOpen ? Visibility.Visible : Visibility.Collapsed;
    if (hasDetails) brush = "DeckProjectOrangeBrush";
    syncDot.Fill = (Brush)ShellTheme.Resource(syncDot, brush);
    syncNow.Content = snapshot.UseCloud ? CloudPageText.SyncNow : "Resume";
    syncNow.Visibility = Visibility.Visible;
    syncNow.IsEnabled = !working && !syncing && (sync is not null || !snapshot.UseCloud);
  }

  private async Task AccountPressAsync(string? label)
  {
    if (working) return;
    working = true; Render();
    try
    {
      if (label == CloudPageText.SignIn) await account.BeginSignInAsync();
      else if (label == CloudPageText.Cancel) account.CancelSignIn();
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { pressProblem = "Could not finish that change. Check your connection."; }
    finally { working = false; Render(); }
  }

  private async Task UseCloudAsync(bool on)
  {
    if (working || !account.Snapshot.Subscription.AllowsCloudServices) return;
    working = true; Render();
    try { await account.SetUseCloudAsync(on); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { pressProblem = "Could not finish that change. Check your connection."; }
    finally { working = false; Render(); }
  }

  /// "Sync now": one round at once; the line follows the engine's own state.
  private async Task SyncNowAsync()
  {
    if (sync is null || syncing || !account.Snapshot.Subscription.AllowsCloudServices) return;
    syncing = true; UpdateSync();
    try { await sync.SyncNowAsync(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { pressProblem = "Could not finish that change. Check your connection."; }
    finally { syncing = false; Render(); }
  }

  /// A trust press: one at a time, its refusal said in plain words on the page.
  private async Task PressAsync(Func<Task> press)
  {
    if (working || !account.Snapshot.Subscription.AllowsCloudServices) return;
    working = true; pressProblem = null; Render();
    try { await press(); }
    catch (CloudTrustRefusal refusal) { pressProblem = refusal.Words; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { pressProblem = "Could not finish that change. Nothing was changed."; }
    finally { working = false; Render(); }
  }
}
