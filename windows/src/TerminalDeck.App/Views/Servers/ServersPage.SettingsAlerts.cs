using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Servers;
using static TerminalDeck.App.Views.Servers.ServerUi;

namespace TerminalDeck.App.Views.Servers;

public sealed partial class ServersPage
{
  private sealed record AlertChannelForm(FrameworkElement Root, Func<ServerAlertChannel> Read);
  private void ServerAlertsSettings(StackPanel body, SavedServer server)
  {
    if (Model.Settings is not { } snapshot) { MissingServerSettings(body, "Server alerts could not be read."); return; }
    if (!snapshot.Hosting.Observed || snapshot.AlertsProblem is not null) { MissingServerSettings(body, snapshot.AlertsProblem ?? snapshot.Hosting.Problem ?? "Server alerts could not be read."); return; }
    if (!snapshot.Hosting.Installed) { body.Children.Add(Words("Set up this server first. The server then sends alerts itself, even when this PC is off.", 12, true)); return; }
    var saved = snapshot.Alerts with { Channels = snapshot.Alerts.Channels ?? [], WatchContainers = snapshot.Alerts.WatchContainers ?? [] };
    body.Children.Add(Words("The server warns you when an app stops or keeps restarting, the disk or memory runs low, a backup or deploy fails, or a certificate is not renewing.", 12, true));
    var enabled = new ToggleSwitch { Header = "Send alerts", IsOn = saved.Enabled }; body.Children.Add(enabled);
    var channelForms = new List<AlertChannelForm>(); var channels = Stack(8); body.Children.Add(channels);
    var addMenu = new MenuFlyout(); var add = new Button { Content = "Add a channel", Flyout = addMenu, MinHeight = 28 }; body.Children.Add(add);
    var disk = new NumberBox { Header = "Disk fuller than (%)", Minimum = 50, Maximum = 99, Value = saved.DiskPercent };
    var memory = new NumberBox { Header = "Memory pressure above (%)", Minimum = 1, Maximum = 100, Value = saved.MemoryPressure };
    ToolTipService.SetToolTip(memory, "How much of the last 10 seconds the server spent waiting for memory.");
    var certificates = new NumberBox { Header = "Certificate expires within (days)", Minimum = 1, Maximum = 60, Value = saved.CertDays };
    var reminder = new NumberBox { Header = "Remind again after (minutes)", Minimum = 10, Maximum = 10080, Value = saved.RemindMinutes };
    ToolTipService.SetToolTip(reminder, "While a problem lasts.");
    var watch = Field("Also watch", string.Join(", ", saved.WatchContainers ?? [])); watch.PlaceholderText = "my-proxy, my-database";
    ToolTipService.SetToolTip(watch, "Other running services on this server, by name, separated by commas. Terminal Deck's own apps are always watched.");
    foreach (var field in new UIElement[] { disk, memory, certificates, reminder, watch }) body.Children.Add(field);
    int Number(NumberBox box, int fallback) => double.IsFinite(box.Value) ? (int)Math.Round(box.Value) : fallback;
    ServerAlertSettings Read() => new(enabled.IsOn, channelForms.Select(form => form.Read()).ToArray(), Number(disk, saved.DiskPercent), Number(memory, saved.MemoryPressure), Number(certificates, saved.CertDays), Number(reminder, saved.RemindMinutes), watch.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
    var save = Button("Save", async () =>
    {
      var draft = Read();
      if (await Model.RunAsync(async () => { ServerSettingsRules.Alerts(draft); await Model.Servers.SaveAlertsAsync(server.Id, draft, ServerCaller.Person); }, "Waiting for approval…", "Server alerts saved.")) { settingsSnapshot = null; await Model.LoadSettingsAsync(); }
    }, true);
    var undo = Button("Undo changes", () => { settingsSnapshot = null; RenderServerSettings(); return Task.CompletedTask; });
    var test = Button("Send a test alert", () => Model.RunAsync(async () =>
    {
      var outcomes = await Model.Servers.TestAlertsAsync(server.Id, ServerCaller.Person);
      var failed = outcomes.Where(result => !result.Ok).Select(result => result.Id).ToArray();
      if (outcomes.Length == 0) throw new ServerRefusal("No alert channel is on.");
      if (failed.Length > 0) throw new ServerRefusal("Test alert was not delivered to " + string.Join(", ", failed) + ". Check those channels and try again.");
    }, "Waiting for approval…", "Test alert delivered to every enabled channel."));
    void RefreshActions()
    {
      var dirty = JsonSerializer.Serialize(Read()) != JsonSerializer.Serialize(saved);
      save.IsEnabled = dirty && !server.Access.LookOnly && !Model.IsBusy; undo.Visibility = dirty ? Visibility.Visible : Visibility.Collapsed;
      test.IsEnabled = !dirty && saved.Enabled && (saved.Channels ?? []).Any(channel => channel.Enabled) && !server.Access.LookOnly && !Model.IsBusy;
      ToolTipService.SetToolTip(test, dirty ? "Save your changes first." : "Sends a short test message to every channel that is on."); add.IsEnabled = channelForms.Count < 10 && !server.Access.LookOnly;
    }
    void AddChannel(ServerAlertChannel channel, bool expanded)
    {
      var form = Stack(8); var name = Field("Name", channel.Name); var on = new CheckBox { Content = "Channel on", IsChecked = channel.Enabled }; form.Children.Add(name); form.Children.Add(on);
      var expander = new Expander { Header = channel.Name, Content = form, IsExpanded = expanded, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
      string? Optional(string value) => value.Length == 0 ? null : value;
      TextBox Text(string label, string? value)
      {
        var field = Field(label, value ?? ""); field.TextChanged += (_, _) => RefreshActions(); form.Children.Add(field); return field;
      }
      PasswordBox Secret(string label, string? value)
      {
        var field = new PasswordBox { Header = label, Password = value ?? "", MaxLength = 2048 }; field.PasswordChanged += (_, _) => RefreshActions(); field.Unloaded += (_, _) => field.Password = ""; form.Children.Add(field); return field;
      }
      Func<ServerAlertChannel> read;
      if (channel.Kind == "telegram")
      {
        var token = Secret("Bot token", channel.BotToken); var chat = Text("Chat ID", channel.ChatId);
        read = () => channel with { Name = name.Text, Enabled = on.IsChecked == true, BotToken = Optional(token.Password), ChatId = Optional(chat.Text) };
      }
      else if (channel.Kind == "email")
      {
        var smtp = Text("SMTP server", channel.SmtpUrl); var user = Text("Username", channel.Username); var password = Secret("Password", channel.Password); var from = Text("From", channel.From); var to = Text("To · comma separated", string.Join(", ", channel.To));
        read = () => channel with { Name = name.Text, Enabled = on.IsChecked == true, SmtpUrl = Optional(smtp.Text), Username = Optional(user.Text), Password = Optional(password.Password), From = Optional(from.Text), To = to.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries) };
      }
      else
      {
        var url = Text("HTTPS address", channel.Url); var secret = Secret(channel.Kind == "receiver" ? "Receiver token" : "Signing secret", channel.Kind == "receiver" ? channel.Token : channel.Secret);
        read = () => channel with { Name = name.Text, Enabled = on.IsChecked == true, Url = Optional(url.Text), Secret = channel.Kind == "webhook" ? Optional(secret.Password) : channel.Secret, Token = channel.Kind == "receiver" ? Optional(secret.Password) : channel.Token };
      }
      var entry = new AlertChannelForm(expander, read); channelForms.Add(entry); channels.Children.Add(expander);
      form.Children.Add(Button("Remove channel", () => { channelForms.Remove(entry); channels.Children.Remove(expander); RefreshActions(); return Task.CompletedTask; }));
      name.TextChanged += (_, _) => { expander.Header = name.Text; RefreshActions(); }; on.Click += (_, _) => RefreshActions();
    }
    foreach (var channel in saved.Channels ?? []) AddChannel(channel, false);
    foreach (var (kind, title) in new[] { ("telegram", "Telegram"), ("email", "Email"), ("webhook", "Webhook"), ("receiver", "Receiver") })
    {
      var item = new MenuFlyoutItem { Text = title }; item.Click += (_, _) => { if (channelForms.Count < 10) AddChannel(new(Guid.NewGuid().ToString("N"), kind, title), true); RefreshActions(); }; addMenu.Items.Add(item);
    }
    enabled.Toggled += (_, _) => RefreshActions(); watch.TextChanged += (_, _) => RefreshActions();
    foreach (var number in new[] { disk, memory, certificates, reminder }) number.ValueChanged += (_, _) => RefreshActions();
    var buttons = Horizontal(save, undo, test); body.Children.Add(buttons); RefreshActions();
    if (snapshot.History.Length > 0)
    {
      var history = Stack(8); var heading = Words("Recent alerts", 15); heading.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; history.Children.Add(heading);
      foreach (var alert in snapshot.History.Take(10))
      {
        var row = Stack(3); row.Children.Add(Words(alert.Title, 12)); if (alert.Message.Length > 0) row.Children.Add(Words(ServerText.Mask(alert.Message), 11, true));
        var reached = alert.Delivered.Where(outcome => outcome.Ok).Select(outcome => outcome.Id).ToArray(); var failed = alert.Delivered.Where(outcome => !outcome.Ok).Select(outcome => outcome.Id).ToArray();
        row.Children.Add(Words(alert.At.LocalDateTime.ToString("g") + " · " + (reached.Length > 0 ? "Sent to " + string.Join(", ", reached) : "Not delivered") + (failed.Length > 0 ? " · Failed: " + string.Join(", ", failed) : ""), 11, true)); history.Children.Add(row);
      }
      body.Children.Add(Card(history));
    }
    else body.Children.Add(Words("No alerts sent yet.", 12, true));
  }
}
