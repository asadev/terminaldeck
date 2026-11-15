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

  public CloudPage(CloudAccountClient account, CloudSyncBridge? sync = null)
  {
    this.account = account;
    this.sync = sync;
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
    Body.Children.Clear(); syncDot = null; syncLine = null; syncNow = null;
    var snapshot = account.Snapshot;
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
      syncLine = new TextBlock { FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
      AutomationProperties.SetAutomationId(syncLine, "settings.cloud.sync");
      syncNow = new Button { Content = CloudPageText.SyncNow, VerticalAlignment = VerticalAlignment.Center };
      syncNow.Click += async (_, _) => await SyncNowAsync();
      var state = new Grid { ColumnSpacing = 10, MinHeight = 24 };
      state.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); state.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); state.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      state.Children.Add(syncDot); Grid.SetColumn(syncLine, 1); state.Children.Add(syncLine); Grid.SetColumn(syncNow, 2); state.Children.Add(syncNow);
      var rows = new List<FrameworkElement> { new Border { Child = state } };
      if (page.UseCloud is { } on)
      {
        var toggle = new ToggleSwitch { IsOn = on, OnContent = "", OffContent = "", MinWidth = 40, IsEnabled = !working };
        toggle.Toggled += async (_, _) => await UseCloudAsync(toggle.IsOn);
        rows.Add(SettingsPanel.SettingRow(CloudPageText.UseCloudToggle, CloudPageText.UseCloudState(on), toggle));
      }
      Body.Children.Add(SettingsPanel.GroupRows(rows));
      if (page.TrustMode is { } mode)
      {
        var choice = new ComboBox { ItemsSource = new[] { CloudPageText.TrustModeLabel(CloudTrustMode.Account), CloudPageText.TrustModeLabel(CloudTrustMode.Ask) },
          SelectedIndex = mode == CloudTrustMode.Ask ? 1 : 0, IsEnabled = !working, MinWidth = 220 };
        choice.SelectionChanged += async (_, _) =>
        {
          if (choice.SelectedIndex < 0) return;
          var chosen = choice.SelectedIndex == 1 ? CloudTrustMode.Ask : CloudTrustMode.Account;
          if (chosen == account.Snapshot.TrustMode) return;
          await PressAsync(() => account.SetTrustModeAsync(chosen));
        };
        Body.Children.Add(SettingsPanel.GroupRows([SettingsPanel.SettingRow(CloudPageText.TrustModeTitle, CloudPageText.TrustModeNote(mode), choice)]));
      }
      UpdateSync();
    }
    if ((pressProblem ?? page.Problem ?? summary.Problem) is { } problem) Body.Children.Add(AccountPages.Problem(problem));
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
        CloudSyncPhase.Sending or CloudSyncPhase.Receiving => (state!.Line, "AccentFillColorDefaultBrush"),
        CloudSyncPhase.Waiting => (state!.Line, "DeckProjectOrangeBrush"),
        CloudSyncPhase.Idle => ("Nothing to sync yet", "DeckSecondaryInkBrush"),
        _ => ("On", "DeckSecondaryInkBrush")
      };
    syncLine.Text = words;
    syncDot.Fill = (Brush)ShellTheme.Resource(syncDot, brush);
    syncNow.Visibility = CloudPageText.CanSyncNow(state) ? Visibility.Visible : Visibility.Collapsed;
    syncNow.IsEnabled = !working && !syncing;
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
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
    finally { working = false; Render(); }
  }

  private async Task UseCloudAsync(bool on)
  {
    if (working) return;
    working = true; Render();
    try { await account.SetUseCloudAsync(on); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
    finally { working = false; Render(); }
  }

  /// "Sync now": one round at once; the line follows the engine's own state.
  private async Task SyncNowAsync()
  {
    if (sync is null || syncing) return;
    syncing = true; UpdateSync();
    try { await sync.SyncNowAsync(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
    finally { syncing = false; UpdateSync(); }
  }

  /// A trust press: one at a time, its refusal said in plain words on the page.
  private async Task PressAsync(Func<Task> press)
  {
    if (working) return;
    working = true; pressProblem = null; Render();
    try { await press(); }
    catch (CloudTrustRefusal refusal) { pressProblem = refusal.Words; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { pressProblem = "Could not finish that change. Nothing was changed."; }
    finally { working = false; Render(); }
  }
}
