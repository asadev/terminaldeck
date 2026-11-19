using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Cloud;
using TerminalDeck.App.Shell;
using Windows.System;

namespace TerminalDeck.App.Views.Settings;

// Older local pairings use their existing trust owner; account devices use the Cloud owner. The page shows one list.
public sealed record ProfileDeviceActions(Func<IReadOnlyList<CloudDeviceRow>> Rows, Func<string, string, Task> Rename,
  Func<string, Task> Remove, Action<string>? Open = null);

public sealed partial class ProfilePage
{
  private readonly HashSet<string> sentRemovals = new(StringComparer.Ordinal);

  private IReadOnlyList<CloudDeviceRow> DeviceRows() => account.Snapshot.DeviceRows
    .Concat(deviceActions?.Rows() ?? []).DistinctBy(d => d.DeviceId)
    .OrderByDescending(d => d.ThisDevice).ThenByDescending(d => d.LastSeen ?? DateTimeOffset.MinValue).ToArray();

  private FrameworkElement DeviceRow(CloudDeviceRow device)
  {
    var pending = pendingRemovals.ContainsKey(device.DeviceId);
    var row = new Grid { ColumnSpacing = 12, MinHeight = 52, Padding = new(12, 4, 12, 4) };
    row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
    row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    row.Children.Add(AccountPages.DeviceGlyph(device));
    var words = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
    var line = pending ? "Signing out…" : deviceProblems.GetValueOrDefault(device.DeviceId) ?? DeviceDescription(device);
    if (editingDevice == device.DeviceId)
    {
      var field = new TextBox { Text = device.Name, MaxLength = 128, MinHeight = 24, Padding = new(6, 1, 6, 1), FontSize = 13, CornerRadius = new(6), BorderThickness = new(0) };
      field.SetResourceReference(Control.BackgroundProperty, "DeckHoverBrush");
      AutomationProperties.SetAutomationId(field, "settings.profile.device.rename");
      AutomationProperties.SetName(field, "Device name");
      var done = false;
      async Task SaveAsync()
      {
        if (done) return;
        done = true; editingDevice = null;
        var name = field.Text.Trim();
        if (name == device.Name) { Render(); return; }
        deviceProblems.Remove(device.DeviceId);
        try
        {
          if (!account.Snapshot.Subscription.Offers(CloudPaidPlace.Devices)) throw new CloudProfileRefusal(CloudSubscriptionPageText.Subscribe);
          if (account.Snapshot.DeviceRows.Any(d => d.DeviceId == device.DeviceId)) await account.RenameDeviceAsync(device.DeviceId, name);
          else if (deviceActions is not null) await deviceActions.Rename(device.DeviceId, name);
          savedDevice = device.DeviceId; Render();
          await Task.Delay(1600);
          if (savedDevice == device.DeviceId) { savedDevice = null; Render(); }
        }
        catch (Exception error) when (error is not OutOfMemoryException) { deviceProblems[device.DeviceId] = "Could not rename"; Render(); }
      }
      field.KeyDown += async (_, args) =>
      {
        if (args.Key == VirtualKey.Escape) { done = true; editingDevice = null; Render(); args.Handled = true; }
        else if (args.Key == VirtualKey.Enter) { args.Handled = true; await SaveAsync(); }
      };
      field.LostFocus += async (_, _) => await SaveAsync();
      field.Loaded += (_, _) => { field.Focus(FocusState.Programmatic); field.SelectAll(); };
      words.Children.Add(field);
    }
    else
    {
      var title = new Grid { ColumnSpacing = 6 };
      title.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); title.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      title.Children.Add(new TextBlock { Text = device.Name, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis });
      if (savedDevice == device.DeviceId) { var check = SettingsPanel.StateText("✓", "DeckProjectGreenBrush"); Grid.SetColumn(check, 1); title.Children.Add(check); }
      words.Children.Add(title);
    }
    var detail = SettingsPanel.StateText(line); detail.FontSize = 11; words.Children.Add(detail);
    if (editingDevice == device.DeviceId) { Grid.SetColumn(words, 1); row.Children.Add(words); }
    else
    {
      var visit = new Button { Content = words, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new(0), BorderThickness = new(0), MinHeight = 44 };
      visit.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
      AutomationProperties.SetAutomationId(visit, "settings.profile.device.open");
      AutomationProperties.SetName(visit, device.Name);
      visit.Click += (_, _) =>
      {
        if (account.Snapshot.DeviceRows.Any(d => d.DeviceId == device.DeviceId)) open(SettingsNavigation.DevicePrefix + device.DeviceId);
        else deviceActions?.Open?.Invoke(device.DeviceId);
      };
      Grid.SetColumn(visit, 1); row.Children.Add(visit);
    }
    var manage = QuietButton(pending ? "Undo" : "…");
    manage.MinWidth = 28; manage.Padding = new(4); manage.IsEnabled = !sentRemovals.Contains(device.DeviceId);
    AutomationProperties.SetAutomationId(manage, pending ? "settings.profile.device.undo" : "settings.profile.device.menu");
    AutomationProperties.SetName(manage, pending ? "Undo sign out of " + device.Name : "Manage " + device.Name);
    if (pending) manage.Click += (_, _) => CancelRemoval([device]);
    else
    {
      var menu = DeckMenu.CreateFor(this);
      var rename = new MenuFlyoutItem { Text = "Rename" };
      rename.Click += (_, _) => { editingDevice = device.DeviceId; Render(); };
      menu.Items.Add(rename);
      if (device.Trust is { CanBeTrusted: true })
      {
        var trust = new MenuFlyoutItem { Text = "Trust…" };
        trust.Click += (_, _) => open(SettingsNavigation.DevicePrefix + device.DeviceId);
        menu.Items.Add(trust);
      }
      if (!device.ThisDevice)
      {
        var remove = new MenuFlyoutItem { Text = account.Snapshot.DeviceRows.Any(d => d.DeviceId == device.DeviceId) ? "Sign out" : "Remove" };
        remove.Click += (_, _) => QueueRemoval([device]);
        menu.Items.Add(remove);
      }
      manage.Flyout = menu;
    }
    Grid.SetColumn(manage, 2); row.Children.Add(manage);
    return row;
  }

  private static string DeviceDescription(CloudDeviceRow device)
  {
    var line = AccountPages.DeviceLine(device);
    if (device.ThisDevice) return line;
    var kind = DevicePicture.KindName(device.Platform, device.Name, device.ReportedModel);
    return device.Name.Contains(kind, StringComparison.OrdinalIgnoreCase) || kind == "Computer" ? line : kind + " · " + line;
  }

  private void QueueRemoval(IReadOnlyList<CloudDeviceRow> devices)
  {
    var selected = devices.Where(d => !d.ThisDevice && !pendingRemovals.ContainsKey(d.DeviceId)).ToArray();
    if (selected.Length == 0) return;
    var cancel = new CancellationTokenSource();
    foreach (var device in selected) { pendingRemovals[device.DeviceId] = cancel; deviceProblems.Remove(device.DeviceId); }
    Render();
    _ = RemoveAfterUndoAsync(selected, cancel);
  }

  private void CancelRemoval(IReadOnlyList<CloudDeviceRow> devices)
  {
    foreach (var token in devices.Where(d => !sentRemovals.Contains(d.DeviceId)).Select(d => pendingRemovals.GetValueOrDefault(d.DeviceId)).OfType<CancellationTokenSource>().Distinct()) token.Cancel();
    foreach (var id in pendingRemovals.Where(p => p.Value.IsCancellationRequested).Select(p => p.Key).ToArray()) pendingRemovals.Remove(id);
    Render();
  }

  private async Task RemoveAfterUndoAsync(CloudDeviceRow[] devices, CancellationTokenSource cancel)
  {
    try
    {
      await Task.Delay(TimeSpan.FromSeconds(5), cancel.Token);
      foreach (var device in devices) sentRemovals.Add(device.DeviceId);
      Render();
      foreach (var device in devices)
      {
        try
        {
          if (!account.Snapshot.Subscription.Offers(CloudPaidPlace.Devices)) throw new CloudProfileRefusal(CloudSubscriptionPageText.Subscribe);
          if (account.Snapshot.DeviceRows.Any(d => d.DeviceId == device.DeviceId))
          {
            await account.SignOutDeviceAsync(device.DeviceId);
            if (alsoRemove is not null) await alsoRemove(device.DeviceId);
          }
          else if (deviceActions is not null) await deviceActions.Remove(device.DeviceId);
        }
        catch (Exception error) when (error is not OutOfMemoryException) { deviceProblems[device.DeviceId] = error is CloudProfileRefusal refusal ? refusal.Words : "Could not sign it out"; }
        finally { pendingRemovals.Remove(device.DeviceId); sentRemovals.Remove(device.DeviceId); }
      }
    }
    catch (OperationCanceledException) { }
    finally { cancel.Dispose(); Render(); }
  }

  internal static Button QuietButton(string words)
  {
    var button = new Button { Content = words, FontSize = 13, Padding = new(0), MinHeight = 28, BorderThickness = new(0) };
    button.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
    button.SetResourceReference(Control.ForegroundProperty, "DeckSecondaryInkBrush");
    return button;
  }
}
