using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Integration;
using TerminalDeck.App.Shell;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Computers;

namespace TerminalDeck.App.Views.Computers;

internal sealed class RemoteSessionHeader : Grid
{
  private readonly OtherComputersService service;
  private readonly string computer, session;
  private readonly bool chat;
  private readonly Action<string> notice;
  private readonly TextBlock title = ChatBar.Title(""), path = new() { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 200, VerticalAlignment = VerticalAlignment.Center };
  private readonly Button account = ChatBar.AccountChip(""), model = new(), effort = new(), usage = new();
  private JsonElement controls, accounts;
  private bool refreshing;
  private readonly TextBlock provider = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
  internal RemoteSessionHeader(OtherComputersService service, string computer, string session, bool chat, Action<string> notice)
  {
    this.service = service; this.computer = computer; this.session = session; this.chat = chat; this.notice = notice;
    var bar = ChatBar.Frame(false); bar.SetResourceReference(BackgroundProperty, "DeckHeaderBrush");
    var identity = ChatBar.Identity(); identity.Children.Add(title);
    identity.SizeChanged += (_, _) => identity.Clip = new RectangleGeometry { Rect = new(0, 0, identity.ActualWidth, identity.ActualHeight) };
    var line = ChatBar.Line(); path.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    line.Children.Add(new DeckIcon { Glyph = "folder", FontSize = 11, VerticalAlignment = VerticalAlignment.Center }); line.Children.Add(path);
    var machine = service.List().FirstOrDefault(c => c.Id == computer);
    var device = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
    device.Children.Add(new DeckIcon { Glyph = DeviceKinds.Glyph(DeviceKinds.Of(machine?.Platform, machine?.Name)), FontSize = 12 });
    var name = new TextBlock { Text = machine?.Name ?? "Another computer", FontSize = 12, MaxWidth = 160, TextTrimming = TextTrimming.CharacterEllipsis }; name.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush"); device.Children.Add(name);
    line.Children.Add(ChatBar.Dot()); line.Children.Add(device); line.Children.Add(ChatBar.Dot()); line.Children.Add(provider); line.Children.Add(account); identity.Children.Add(line); bar.Children.Add(identity);
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
    DeckMenu.Pill(model); DeckMenu.Pill(effort); actions.Children.Add(usage); actions.Children.Add(model); actions.Children.Add(effort);
    var ring = Usage.MeterRing.Create(); Usage.MeterRing.Draw(ring, null, "AccentFillColorDefaultBrush"); Usage.MeterRing.Host(usage, ring); usage.Width = usage.Height = 26;
    AutomationProperties.SetName(usage, "Usage on " + (machine?.Name ?? "the other computer")); ToolTipService.SetToolTip(usage, "Session usage");
    var more = new Button(); ChatAppearance.IconButton(more, "\uE712", "Session actions");
    more.Click += (_, _) =>
    {
      var menu = DeckMenu.CreateFor(this);
      if (Has("rename"))
      {
        var rename = new MenuFlyoutItem { Text = "Rename…" }; rename.Click += async (_, _) =>
        {
          var input = new TextBox { Text = title.Text, MaxLength = 120, PlaceholderText = "Session name" };
          var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Rename session", Content = input, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
          if (await dialog.ShowAsync() == ContentDialogResult.Primary) await Run(async () => await service.SendAsync(computer, new { t = "rename", id = session, title = input.Text }));
        }; menu.Items.Add(rename);
      }
      if (Has("close")) { var stop = new MenuFlyoutItem { Text = "Stop session" }; stop.Click += async (_, _) => await Run(async () => await service.SendAsync(computer, new { t = "close", id = session })); menu.Items.Add(stop); }
      menu.ShowAt(more);
    };
    more.Visibility = Has("rename") || Has("close") ? Visibility.Visible : Visibility.Collapsed;
    actions.Children.Add(more); SetColumn(actions, 1); bar.Children.Add(actions); Children.Add(bar);
    account.Click += async (_, _) => await AccountMenuAsync(); model.Click += async (_, _) => await ControlMenuAsync("model", model); effort.Click += async (_, _) => await ControlMenuAsync("effort", effort); usage.Click += async (_, _) => await UsageMenuAsync();
    Loaded += async (_, _) => { service.Changed -= Changed; service.Changed += Changed; Render(); await ReadAsync(); }; Unloaded += (_, _) => service.Changed -= Changed;
    SizeChanged += (_, _) => { var narrow = ActualWidth < 600; path.MaxWidth = narrow ? 100 : 200; name.MaxWidth = narrow ? 100 : 160; };
    Render();
  }
  private bool Has(string capability) => service.List().Any(c => c.Id == computer && c.State == "Online" && c.Capabilities.Contains(capability));
  private void Changed() => DispatcherQueue.TryEnqueue(Render);
  private void Render()
  {
    var row = service.Services(computer).Sessions.FirstOrDefault(s => OtherComputersService.Text(s, "id", "") == session);
    var known = OtherComputersService.Text(row, "title", ""); if (known.Length > 0) title.Text = known;
    path.Text = OtherComputersService.Text(row, "cwd", path.Text); ToolTipService.SetToolTip(path, path.Text);
    var ai = OtherComputersService.Text(row, "provider", ""); provider.Text = ai switch { "claude" => "✳", "codex" => "◎", "gemini" => "✦", _ => "" };
    ToolTipService.SetToolTip(provider, ai); AutomationProperties.SetName(provider, ai);
    var sessionLive = RemoteSessionReading.Field(row, "exitCode").ValueKind != JsonValueKind.Number && OtherComputersService.Text(row, "status", "") is not ("exited" or "ended");
    account.IsEnabled = Has("account") && sessionLive;
    account.Visibility = Has("account") ? Visibility.Visible : Visibility.Collapsed;
    usage.Visibility = Has("usage") ? Visibility.Visible : Visibility.Collapsed;
    var available = Has(chat ? "chats" : "controls"); model.Visibility = effort.Visibility = available ? Visibility.Visible : Visibility.Collapsed;
    model.Content = RemoteSessionReading.ControlLabel(controls, "model"); effort.Content = RemoteSessionReading.ControlLabel(controls, "effort");
    if (controls.ValueKind != JsonValueKind.Undefined)
    {
      if (RemoteSessionReading.ControlLabel(controls, "model") == "Model" && RemoteSessionReading.Choices(controls, "model").Count == 0) model.Visibility = Visibility.Collapsed;
      if (RemoteSessionReading.ControlLabel(controls, "effort") == "Effort" && RemoteSessionReading.Choices(controls, "effort").Count == 0) effort.Visibility = Visibility.Collapsed;
    }
    model.IsEnabled = sessionLive && available && RemoteSessionReading.Choices(controls, "model").Count > 0;
    effort.IsEnabled = sessionLive && available && RemoteSessionReading.Choices(controls, "effort").Count > 0;
    var current = RemoteSessionReading.Field(accounts, "current");
    account.Content = current.ValueKind == JsonValueKind.Object ? RemoteSessionReading.AccountName(current) : "Account";
  }
  private async Task Run(Func<Task> action)
  {
    try { await action(); } catch (Exception ex) when (ex is not OutOfMemoryException) { notice(ex.Message); }
  }
  private async Task ReadAsync()
  {
    if (refreshing) return; refreshing = true;
    try
    {
      if (Has(chat ? "chats" : "controls")) controls = chat ? await service.ChatOptionsAsync(computer, session) : await service.OperateAsync(computer, "controls-read", new() { ["id"] = session });
      if (Has("account")) accounts = await service.OperateAsync(computer, "account-read", new() { ["id"] = session });
      Render();
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { notice(ex.Message); }
    finally { refreshing = false; }
  }
  private async Task ControlMenuAsync(string control, Button anchor)
  {
    var menu = DeckMenu.CreateFor(this);
    foreach (var choice in RemoteSessionReading.Choices(controls, control))
    {
      var item = new ToggleMenuFlyoutItem { Text = choice.Name, IsChecked = RemoteSessionReading.ControlLabel(controls, control) == choice.Id || RemoteSessionReading.ControlLabel(controls, control) == choice.Name };
      item.Click += async (_, _) => await Run(async () =>
      {
        notice("Changing " + control + "…");
        if (chat) controls = await service.ChatOptionsAsync(computer, session, new() { [control] = choice.Id });
        else await service.OperateAsync(computer, "controls-set", new() { ["id"] = session, ["control"] = control, ["value"] = choice.Id });
        await ReadAsync(); notice("");
      }); menu.Items.Add(item);
    }
    if (menu.Items.Count > 0) menu.ShowAt(anchor);
  }
  private async Task AccountMenuAsync()
  {
    var menu = DeckMenu.CreateFor(this); menu.Items.Add(new MenuFlyoutItem { Text = "Reading accounts…", IsEnabled = false }); menu.ShowAt(account);
    try { accounts = await service.OperateAsync(computer, "account-read", new() { ["id"] = session }); Render(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { menu.Items.Clear(); menu.Items.Add(new MenuFlyoutItem { Text = "Accounts unavailable", IsEnabled = false }); notice(ex.Message); return; }
    menu.Items.Clear(); var current = RemoteSessionReading.Text(RemoteSessionReading.Field(accounts, "current"), "id");
    foreach (var choice in RemoteSessionReading.Rows(accounts, "accounts"))
    {
      var id = RemoteSessionReading.Text(choice, "id"); if (id.Length == 0) continue;
      var item = new ToggleMenuFlyoutItem { Text = RemoteSessionReading.AccountName(choice), IsChecked = id == current };
      item.Click += async (_, _) => await Run(async () => { notice("Switching account…"); await service.OperateAsync(computer, "account-switch", new() { ["id"] = session, ["accountId"] = id }); await ReadAsync(); notice(""); }); menu.Items.Add(item);
    }
    if (menu.Items.Count == 0) menu.Items.Add(new MenuFlyoutItem { Text = "No account choices available", IsEnabled = false }); DeckMenu.CompactRows(menu.Items);
  }
  private async Task UsageMenuAsync()
  {
    var body = new StackPanel { Width = 252, Spacing = 8 }; var popup = DeckMenu.Create(body); DeckMenu.Apply(popup, ActualTheme);
    var loading = new TextBlock { Text = "Checking…", FontSize = 12 }; body.Children.Add(loading); popup.ShowAt(usage);
    await Run(async () =>
    {
      var response = await service.OperateAsync(computer, "usage", new() { ["id"] = session, ["want"] = "plan" });
      var reading = RemoteSessionReading.Field(RemoteSessionReading.Field(response, "answer"), "reading");
      body.Children.Clear();
      foreach (var window in RemoteSessionReading.Rows(reading, "readings"))
      {
        var row = new StackPanel { Spacing = 3 }; var used = RemoteSessionReading.Field(RemoteSessionReading.Field(window, "used"), "fraction");
        var percent = used.ValueKind == JsonValueKind.Number ? Math.Clamp(used.GetDouble() * 100, 0, 100) : (double?)null;
        row.Children.Add(new TextBlock { Text = RemoteSessionReading.Text(window, "label", "Plan limit") + "  ·  " + (percent is { } p ? p.ToString("0") + "% used" : "No reading yet"), FontSize = 12 });
        if (percent is { } amount)
        {
          var bar = new ProgressBar { Minimum = 0, Maximum = 100, Value = amount, Height = 4 };
          bar.SetResourceReference(Control.ForegroundProperty, amount >= 90 ? "DeckStatusFailedBrush" : amount >= 70 ? "DeckProjectOrangeBrush" : "AccentFillColorDefaultBrush"); row.Children.Add(bar);
        }
        body.Children.Add(row);
      }
      if (body.Children.Count == 0) body.Children.Add(new TextBlock { Text = "No reading yet", FontSize = 12 });
      var refresh = new Button { Content = "Refresh", MinHeight = 30 }; refresh.Click += async (_, _) => { refresh.IsEnabled = false; await Run(async () => { await service.OperateAsync(computer, "usage", new() { ["id"] = session, ["want"] = "refresh", ["force"] = true }); popup.Hide(); await UsageMenuAsync(); }); refresh.IsEnabled = true; }; body.Children.Add(refresh);
    });
  }
}
