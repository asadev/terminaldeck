using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Remote;
using Windows.ApplicationModel.DataTransfer;

namespace TerminalDeck.App.Views;

public sealed partial class SettingsPane
{
  private string? pairingNotice;
  private void AddDeviceRows(StackPanel stack)
  {
    var approved = runtime.Remote.Trust.List();
    if (pairingNotice is not null) stack.Children.Add(Description(pairingNotice));
    stack.Children.Add(Description(approved.Count + (approved.Count == 1 ? " paired device · Relay: " : " paired devices · Relay: ") + runtime.Remote.State));
    stack.Children.Add(Card("Pair a device", "Show a one-use code for your phone or computer. Only let in the device you’re holding.", "Show code", ShowPairingAsync));
    stack.Children.Add(Card("Web version", "Open this PC in your browser. The browser becomes a paired Web device with the usual access controls.", "Open web version", async () =>
    {
      try { await runtime.Remote.OpenWebAsync(); }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or UnauthorizedAccessException) { pairingNotice = "Could not open the web version. Try again."; await RenderAsync(); }
    }));
    AddPhoneScreenRows(stack);
    stack.Children.Add(new Computers.OtherComputersCard(runtime.OtherComputers));
    foreach (var device in runtime.Remote.Trust.Pending())
      stack.Children.Add(Card(device.Name, device.Platform + " · Waiting for approval. Only let in the device you’re holding.", "Review access", () => ShowPhoneWorkspaceAsync(device)));
    foreach (var device in approved)
    {
      var actions = new MenuFlyout();
      var access = new MenuFlyoutItem { Text = "Device access…" }; access.Click += async (_, _) => await ShowPhoneWorkspaceAsync(device); actions.Items.Add(access);
      var rename = new MenuFlyoutItem { Text = "Rename…" }; rename.Click += async (_, _) => await RenameDeviceAsync(device); actions.Items.Add(rename);
      var revoke = new MenuFlyoutItem { Text = "Revoke…" }; revoke.Click += async (_, _) => await RevokeDeviceAsync(device); actions.Items.Add(revoke);
      var card = Card(device.Name, (device.Platform == "web" ? "Web" : device.Platform) + " · Approved · " + device.Access + "\n" + DevicePresence(device), "Device access…", () => ShowPhoneWorkspaceAsync(device));
      card.ContextFlyout = actions;
      AddCardMenu(card, actions, "Device actions"); stack.Children.Add(card);
    }
    if (approved.Count + runtime.Remote.Trust.Pending().Count == 0) stack.Children.Add(Description("No devices yet"));
  }

  // The one switch for This PC on the phone (the Mac's "Phones may view and control this Mac's screen"), and who is
  // watching or controlling it right now, with Stop.
  private void AddPhoneScreenRows(StackPanel stack)
  {
    var toggle = new ToggleSwitch { IsOn = runtime.PhoneScreenAllowed, OnContent = "", OffContent = "", MinWidth = 40 };
    var note = new Notices.CompactNotice();
    toggle.Toggled += async (_, _) =>
    {
      try { await runtime.SetPhoneScreenAllowedAsync(toggle.IsOn); }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { note.Text = "The choice could not be saved. Try again."; }
    };
    stack.Children.Add(TerminalDeck.App.Views.Settings.SettingsPanel.SettingRow(TerminalDeck.App.Integration.AppRuntime.PhoneScreenTitle,
      "Off: a phone that tries is told why. Watching needs Work or Full control; clicking and typing need Full control.", toggle));
    stack.Children.Add(note);
    var viewers = runtime.PhoneScreens?.Viewers() ?? [];
    if (viewers.Count == 0) return;
    var who = string.Join(" · ", viewers.Select(v => (v.Controlling ? "Controlled from " : "Watched from ") + v.Phone + " (" + v.Display + ")"));
    stack.Children.Add(Card("This PC's screen is on a phone", who, "Stop", async () =>
    {
      if (runtime.PhoneScreens is { } screens) await screens.StopAllAsync("Stopped on the PC.");
      await RenderAsync();
    }));
  }

  private static string DevicePresence(ApprovedDevice device)
  {
    var paired = "Pair date not reported";
    if (device.PairedAt is { } date)
    {
      var age = DateTimeOffset.UtcNow - date;
      paired = age < TimeSpan.Zero ? "Paired " + date.ToLocalTime().ToString("g") : age.TotalMinutes < 1 ? "Paired just now" : age.TotalHours < 1 ? "Paired " + (int)age.TotalMinutes + " minutes ago" : age.TotalDays < 1 ? "Paired " + (int)age.TotalHours + " hours ago" : "Paired " + (int)age.TotalDays + " days ago";
    }
    return paired + " · " + (device.Connected ? "Connected" : device.LastSeen is { } seen ? "Last seen " + seen.ToLocalTime().ToString("g") : "Not connected · Last seen not reported");
  }

  private async Task RenameDeviceAsync(ApprovedDevice device)
  {
    var input = new TextBox { Header = "Device name", Text = device.Name, MaxLength = 128 };
    var note = Description("");
    var form = new StackPanel { Spacing = 12 }; form.Children.Add(input); form.Children.Add(note);
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Rename device", Content = form, PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
    input.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(input.Text);
    dialog.PrimaryButtonClick += (_, args) =>
    {
      try { runtime.Remote.Trust.Rename(device.Id, input.Text.Trim()); }
      catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException or ProtocolException) { args.Cancel = true; note.Text = "The name could not be saved. Use 1–128 characters and try again."; }
    };
    if (await dialog.ShowAsync() == ContentDialogResult.Primary) await RenderAsync();
  }

  private async Task RevokeDeviceAsync(ApprovedDevice device)
  {
    var note = Description("Revoke " + device.Name + "? Its access stops immediately. It will need to pair again before it can reconnect.");
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Revoke device", Content = note, PrimaryButtonText = "Revoke", CloseButtonText = "Keep it", DefaultButton = ContentDialogButton.Close };
    dialog.PrimaryButtonClick += (_, args) =>
    {
      try { runtime.Remote.Trust.Revoke(device.Id); }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ProtocolException) { args.Cancel = true; note.Text = "Access could not be revoked. Try again."; }
    };
    if (await dialog.ShowAsync() == ContentDialogResult.Primary) await RenderAsync();
  }

  private async Task ShowPairingAsync()
  {
    pairingNotice = null;
    var code = new TextBlock { FontSize = 28, IsTextSelectionEnabled = true };
    var state = Description("Making a code…");
    var request = Description("Waiting for the device…");
    var access = new ComboBox { Header = "Device access", ItemsSource = new[] { "Full control", "Work", "Hoot only", "Look only" }, SelectedIndex = 0, Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Stretch };
    var copy = new Button { Content = "Copy code", IsEnabled = false };
    var refresh = new Button { Content = "Make a new code", IsEnabled = false };
    var form = new StackPanel { Spacing = 16 }; form.Children.Add(Description("This computer shows a code. Type it on your phone or computer. Only let in the device you’re holding."));
    foreach (var child in new UIElement[] { code, state, copy, refresh, request, access }) form.Children.Add(child);
    form.Children.Add(Description("Task projects and Hoot stay unshared until you choose them in Device access."));
    PairingOffer? offer = null; string? reviewing = null; string? problem = null; var closed = false; var submitting = false;
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Pair a device", Content = form, PrimaryButtonText = "Let it in", IsPrimaryButtonEnabled = false, CloseButtonText = "Cancel" };
    void Update()
    {
      if (closed) return;
      var pending = runtime.Remote.Trust.Pending();
      var device = pending.FirstOrDefault(d => d.Id == reviewing) ?? pending.FirstOrDefault();
      if (device?.Id != reviewing)
      {
        reviewing = device?.Id; problem = null;
        access.SelectedIndex = device?.Access switch { PhoneAccess.Look => 3, PhoneAccess.Hoot => 2, PhoneAccess.Work => 1, _ => 0 };
      }
      request.Text = device is null ? "Waiting for the device…" : device.Name + " wants to connect. Only let in the device you’re holding.";
      access.Visibility = device is null ? Visibility.Collapsed : Visibility.Visible;
      dialog.IsPrimaryButtonEnabled = device is not null && !submitting; dialog.PrimaryButtonText = submitting ? "Letting it in…" : "Let it in"; dialog.CloseButtonText = device is null ? "Cancel" : "Not now";
      if (offer is null) return;
      var seconds = Math.Max(0, (int)Math.Ceiling((offer.ExpiresAt - DateTimeOffset.UtcNow).TotalSeconds));
      var open = seconds > 0 && runtime.Remote.Trust.Pairing.IsCurrent(offer.Code);
      code.Text = open ? offer.Code : "Code expired or used";
      state.Text = open ? "Works once · " + seconds + " seconds left" : device is null ? "Make a new code to pair another device." : "Review this request before letting it in.";
      if (problem is not null) state.Text = problem;
      copy.IsEnabled = open; refresh.IsEnabled = !open && device is null;
    }
    async Task MakeCodeAsync()
    {
      problem = null; refresh.IsEnabled = false; state.Text = "Making a code…";
      try
      {
        offer = await runtime.Remote.ShowCodeAsync();
        if (closed) { runtime.Remote.Trust.Pairing.Cancel(offer.Code); return; }
        ActiveCode = offer.Code; Update();
      }
      catch (Exception ex) when (ex is IOException or InvalidOperationException) { problem = state.Text = "Couldn’t make a pairing code. Try again."; refresh.IsEnabled = true; }
    }
    copy.Click += (_, _) =>
    {
      if (offer is null || !runtime.Remote.Trust.Pairing.IsCurrent(offer.Code)) return;
      try { var data = new DataPackage(); data.SetText(offer.Code); Clipboard.SetContent(data); state.Text = "Code copied"; }
      catch (Exception ex) when (ex is not OutOfMemoryException) { problem = state.Text = "Couldn’t copy the code. You can select it above."; }
    };
    refresh.Click += async (_, _) => await MakeCodeAsync();
    dialog.PrimaryButtonClick += async (_, args) =>
    {
      var deferral = args.GetDeferral(); submitting = true; problem = null; Update(); await Task.Yield();
      try
      {
        if (reviewing is null || !runtime.Remote.Trust.Pending().Any(d => d.Id == reviewing)) throw new InvalidOperationException("That request changed. Review the current device before letting it in.");
        runtime.SetPhoneWorkspace(reviewing, [], false, access.SelectedIndex switch { 1 => PhoneAccess.Work, 2 => PhoneAccess.Hoot, 3 => PhoneAccess.Look, _ => PhoneAccess.Full });
      }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException or UnauthorizedAccessException or ProtocolException)
      { args.Cancel = true; problem = state.Text = "Couldn’t let this device in. It still needs approval. Try again."; }
      finally { submitting = false; Update(); deferral.Complete(); }
    };
    // Only the visible countdown uses a timer; device requests arrive as events.
    var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) }; timer.Tick += (_, _) => Update();
    void RequestsChanged() => DispatcherQueue.TryEnqueue(Update);
    runtime.Remote.Changed += RequestsChanged;
    dialog.Opened += async (_, _) => { timer.Start(); Update(); if (reviewing is null) await MakeCodeAsync(); };
    var result = ContentDialogResult.None;
    try { result = await dialog.ShowAsync(); }
    finally
    {
      closed = true; timer.Stop(); runtime.Remote.Changed -= RequestsChanged;
      if (offer is not null) { runtime.Remote.Trust.Pairing.Cancel(offer.Code); if (ActiveCode == offer.Code) ActiveCode = null; }
      if (result != ContentDialogResult.Primary && reviewing is not null && runtime.Remote.Trust.Pending().Any(d => d.Id == reviewing))
      {
        try { runtime.Remote.Trust.DenyPending(reviewing); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { pairingNotice = "Couldn’t deny the request. This device still needs approval; try Not now again."; }
      }
    }
    await RenderAsync();
  }
}
