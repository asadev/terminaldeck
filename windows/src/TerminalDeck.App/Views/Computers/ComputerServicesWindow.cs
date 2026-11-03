using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Integration;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Computers;

namespace TerminalDeck.App.Views.Computers;

public sealed class ComputerServicesWindow
{
  private static readonly Dictionary<string, ComputerServicesWindow> windows = [];
  private readonly Window window = new();
  private readonly OtherComputersService service;
  private readonly string computer;
  private readonly StackPanel sessions = new() { Spacing = 8 };
  private readonly TextBlock result = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
  private readonly List<RemoteSessionPane> terminals = [];
  public static void Open(OtherComputersService service, ComputerConnection computer, ElementTheme theme)
  {
    if (windows.TryGetValue(computer.Id, out var existing)) { existing.window.Activate(); return; }
    var created = new ComputerServicesWindow(service, computer, theme); windows[computer.Id] = created; created.window.Activate();
  }
  private ComputerServicesWindow(OtherComputersService service, ComputerConnection computer, ElementTheme theme)
  {
    this.service = service; this.computer = computer.Id; window.Title = computer.Name;
    var root = new StackPanel { RequestedTheme = theme, Spacing = 12, Padding = new(16) };
    root.SetResourceReference(StackPanel.BackgroundProperty, "DeckCanvasBrush");
    root.Children.Add(new TextBlock { Text = computer.Name + " · Sessions and services", FontSize = 20 });
    root.Children.Add(new TextBlock { Text = "Actions run on this computer using its current grants. Connection recovery never grants new access.", TextWrapping = TextWrapping.Wrap });
    var folder = new ComboBox { Header = "Folder", IsEditable = true, HorizontalAlignment = HorizontalAlignment.Stretch };
    foreach (var item in service.Services(this.computer).Folders) folder.Items.Add(item);
    var provider = new ComboBox { Header = "Agent", ItemsSource = new[] { "claude", "codex", "gemini", "shell" }, SelectedIndex = 0 };
    root.Children.Add(folder); root.Children.Add(provider);
    Add(root, "Start session", "create", async () => { var fields = new JsonObject { ["provider"] = provider.SelectedItem?.ToString() ?? "shell" }; if (!string.IsNullOrWhiteSpace(folder.Text)) fields["cwd"] = folder.Text; var created = await service.CreateSessionAsync(this.computer, fields); result.Text = "Started " + OtherComputersService.Text(created, "title", OtherComputersService.Text(created, "id", "session")); });
    root.Children.Add(sessions);
    var details = new StackPanel { Spacing = 8 };
    var login = new ComboBox { Header = "Agent login", PlaceholderText = "Read agent logins, then choose", HorizontalAlignment = HorizontalAlignment.Stretch };
    foreach (var pair in new[] { ("Agent logins", "logins"), ("Host status", "host-read"), ("GitHub status", "github-read"), ("Restart host", "host-restart"), ("Stop host", "host-stop"), ("Connect GitHub", "github-connect"), ("Cancel GitHub connection", "github-cancel"), ("Disconnect GitHub", "github-disconnect") })
    {
      var operation = ComputerOperations.All[pair.Item2];
      Add(details, pair.Item1, operation.Capability, async () => { var reading = await service.OperateAsync(this.computer, pair.Item2, new()); result.Text = ComputerServiceReading.Describe(reading); if (pair.Item2 == "logins") ComputerServiceReading.Accounts(login, reading); });
    }
    details.Children.Add(login);
    Add(details, "Sign in", "logins", async () => result.Text = ComputerServiceReading.Describe(await service.OperateAsync(this.computer, "sign-in", new() { ["accountId"] = ComputerServiceReading.Account(login) })));
    Add(details, "Sign out", "logins", async () => result.Text = ComputerServiceReading.Describe(await service.OperateAsync(this.computer, "sign-out", new() { ["accountId"] = ComputerServiceReading.Account(login) })));
    root.Children.Add(new Expander { Header = "Host, logins and GitHub", Content = details, HorizontalAlignment = HorizontalAlignment.Stretch });
    var hoot = new StackPanel { Spacing = 8 }; var say = new TextBox { Header = "Message to Hoot", AcceptsReturn = true, MaxLength = 16000 }; hoot.Children.Add(say);
    foreach (var (label, tag) in new[] { ("Read Hoot", "hoot.attach"), ("Start Hoot", "hoot.start"), ("Refresh Hoot", "hoot.state"), ("Send message", "hoot.say"), ("Stop following Hoot", "hoot.detach") })
      Add(hoot, label, "hoot", async () => { await service.HootAsync(this.computer, tag, tag == "hoot.say" ? say.Text : null); result.Text = "Sent. Waiting for Hoot on " + computer.Name + "…"; });
    root.Children.Add(new Expander { Header = "Hoot", Content = hoot, HorizontalAlignment = HorizontalAlignment.Stretch });
    var network = new StackPanel { Spacing = 8 };
    Add(network, "Refresh ports", "localhost", async () => { await service.SendAsync(this.computer, new { t = "ports" }); result.Text = "Asking for current ports…"; });
    var port = new NumberBox { Header = "Remote port", Minimum = 1, Maximum = 65535, Value = 3000 }; network.Children.Add(port);
    Add(network, "Open here", "localhost", async () => { var address = await service.OpenPortAsync(this.computer, (int)port.Value, CancellationToken.None); result.Text = address; await Windows.System.Launcher.LaunchUriAsync(new Uri(address)); });
    Add(network, "Close here", "localhost", async () => { await service.ClosePortAsync(this.computer, (int)port.Value); result.Text = "Tunnel closed."; });
    var url = new TextBox { Header = "URL to open there", PlaceholderText = "https://…" }; network.Children.Add(url);
    Add(network, "Open there", "web", async () => { if (!Uri.TryCreate(url.Text, UriKind.Absolute, out var parsed) || parsed.Scheme is not ("http" or "https")) throw new ArgumentException("Enter an http or https address."); await service.SendAsync(this.computer, new { t = "web.open", url = url.Text }); });
    root.Children.Add(new Expander { Header = "Local web servers", Content = network, HorizontalAlignment = HorizontalAlignment.Stretch });
    var upload = new StackPanel { Spacing = 8 }; var source = new TextBox { Header = "File on this PC", PlaceholderText = "Full file path" }; var destination = new TextBox { Header = "Folder there", PlaceholderText = "Leave empty for Downloads" }; upload.Children.Add(source); upload.Children.Add(destination);
    Add(upload, "Send file", "upload", async () => result.Text = ComputerServiceReading.Describe(await service.UploadAsync(this.computer, source.Text, destination.Text, CancellationToken.None)));
    Add(upload, "Cancel upload", "upload", () => { service.CancelUpload(this.computer); return Task.CompletedTask; });
    root.Children.Add(new Expander { Header = "Send a file", Content = upload, HorizontalAlignment = HorizontalAlignment.Stretch });
    root.Children.Add(result); window.Content = new ScrollViewer { Content = root, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    service.Changed += Changed; service.Frame += Frame;
    window.Closed += async (_, _) => { windows.Remove(this.computer); service.Changed -= Changed; service.Frame -= Frame; foreach (var terminal in terminals) await terminal.DisposeAsync(); };
    Render();
  }
  private void Add(StackPanel panel, string label, string capability, Func<Task> action)
  {
    var button = new Button { Content = label, IsEnabled = service.List().Any(c => c.Id == computer && c.State == "Online" && c.Capabilities.Contains(capability)) };
    button.Click += async (_, _) =>
    {
      button.IsEnabled = false; result.Text = label + "…";
      try { service.RequireCapability(computer, capability); await action(); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { result.Text = ex.Message; }
      finally { button.IsEnabled = service.List().Any(c => c.Id == computer && c.State == "Online" && c.Capabilities.Contains(capability)); }
    };
    panel.Children.Add(button);
  }
  private void Changed() => window.DispatcherQueue.TryEnqueue(Render);
  private void Frame(string id, JsonElement frame)
  {
    if (id != computer) return;
    if (OtherComputersService.Text(frame, "t", "") is "hoot.state" or "hoot.chat" or "ports" or "github.changed" or "error") window.DispatcherQueue.TryEnqueue(() => result.Text = ComputerServiceReading.Describe(frame));
  }
  private void Render()
  {
    sessions.Children.Clear();
    foreach (var session in service.Services(computer).Sessions)
    {
      var id = OtherComputersService.Text(session, "id", ""); if (id.Length == 0) continue;
      var row = new StackPanel { Spacing = 6 }; row.Children.Add(new TextBlock { Text = OtherComputersService.Text(session, "title", id) + " · " + OtherComputersService.Text(session, "status", ""), TextWrapping = TextWrapping.Wrap });
      var open = new Button { Content = "Open session" };
      open.Click += (_, _) =>
      {
        var terminal = new RemoteSessionPane(service, computer, id); terminals.Add(terminal);
        var child = new Window { Title = OtherComputersService.Text(session, "title", id), Content = terminal };
        child.Closed += async (_, _) => { terminals.Remove(terminal); await terminal.DisposeAsync(); }; child.Activate();
      };
      row.Children.Add(open);
      var title = new TextBox { Header = "Title", Text = OtherComputersService.Text(session, "title", "") }; row.Children.Add(title);
      Add(row, "Rename", "rename", () => service.SendAsync(computer, new { t = "rename", id, title = title.Text }));
      Add(row, "Stop session", "close", () => service.SendAsync(computer, new { t = "close", id }));
      Add(row, "Model and effort options", "controls", async () => result.Text = ComputerServiceReading.Describe(await service.OperateAsync(computer, "controls-read", new() { ["id"] = id })));
      var control = new ComboBox { Header = "Control", ItemsSource = new[] { "model", "effort", "fast", "permission" }, SelectedIndex = 0 }; var value = new TextBox { Header = "Value from the options above" }; row.Children.Add(control); row.Children.Add(value);
      Add(row, "Apply control", "controls", async () => result.Text = ComputerServiceReading.Describe(await service.OperateAsync(computer, "controls-set", new() { ["id"] = id, ["control"] = control.SelectedItem?.ToString(), ["value"] = value.Text })));
      foreach (var want in new[] { "plan", "context", "refresh" }) Add(row, "Usage: " + want, "usage", async () => result.Text = ComputerServiceReading.Describe(await service.OperateAsync(computer, "usage", new() { ["id"] = id, ["want"] = want })));
      var account = new ComboBox { Header = "Account", PlaceholderText = "Read account choices, then choose", HorizontalAlignment = HorizontalAlignment.Stretch };
      Add(row, "Account choices", "account", async () => { var reading = await service.OperateAsync(computer, "account-read", new() { ["id"] = id }); result.Text = ComputerServiceReading.Describe(reading); ComputerServiceReading.Accounts(account, reading); });
      row.Children.Add(account);
      Add(row, "Switch account", "account", async () => result.Text = ComputerServiceReading.Describe(await service.OperateAsync(computer, "account-switch", new() { ["id"] = id, ["accountId"] = ComputerServiceReading.Account(account) })));
      sessions.Children.Add(new Expander { Header = OtherComputersService.Text(session, "title", id), Content = row, HorizontalAlignment = HorizontalAlignment.Stretch });
    }
  }
}
