using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.ViewModels.Servers;
using TerminalDeck.App.Views.Servers;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Servers;
using TerminalDeck.Core.Storage;
using Windows.Graphics;

namespace TerminalDeck.Servers.Proof;

public partial class App : Application
{
  private Window? window;
  public App() => InitializeComponent();
  protected override void OnLaunched(LaunchActivatedEventArgs args)
  {
    var root = AppDataRoot.FromArguments(Environment.GetCommandLineArgs().Skip(1).ToArray());
    if (!root.DirectoryPath.StartsWith(@"C:\TD\out\", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Use a scratch proof root under C:\\TD\\out.");
    var proof = Path.Combine(root.DirectoryPath, "proof"); Directory.CreateDirectory(proof);
    window = new Window { Title = "Servers · sample data · isolated preview" };
    var frame = new Grid { RequestedTheme = ElementTheme.Light };
    frame.RowDefinitions.Add(new() { Height = GridLength.Auto }); frame.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    frame.Children.Add(new TextBlock { Text = "SAMPLE DATA · isolated Windows servers preview", Margin = new Thickness(32, 10, 32, 0), Opacity = 0.6 });
    var content = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    Grid.SetRow(content, 1); frame.Children.Add(content); window.Content = frame; window.Activate(); window.AppWindow.MoveAndResize(new RectInt32(40, 20, 1100, 850));
    UnhandledException += (_, e) =>
    {
      e.Handled = true;
      File.WriteAllText(Path.Combine(proof, "result.json"), JsonSerializer.Serialize(new { passed = 0, failed = 1, errorType = e.Exception.GetType().Name, code = e.Exception.HResult.ToString("X8"), stack = new System.Diagnostics.StackTrace(e.Exception, true).GetFrames().Where(f => f.GetMethod()?.DeclaringType?.Namespace?.StartsWith("TerminalDeck", StringComparison.Ordinal) == true).Select(f => new { method = f.GetMethod()?.Name, line = f.GetFileLineNumber() }) }));
    };
    frame.DispatcherQueue.TryEnqueue(async () => await WalkAsync(root, proof, frame, content, window));
  }
  private static async Task WalkAsync(AppDataRoot root, string proof, Grid frame, ContentControl content, Window window)
  {
    var passed = new List<string>(); var failed = new List<string>();
    void Check(string name, bool result) => (result ? passed : failed).Add(name);
    try
    {
      var store = new ServerStore(root, new MemorySecrets()); var runtime = new FakeSsh(); var approves = new Approval();
      var service = new ServerService(store, runtime, approves);
      var server = await service.AddAsync(new("Preview Linux", "linux.example.test", 22, "deck", ServerAuthentication.Password), null, "sample"u8.ToArray());
      await store.SetAccessAsync(server.Id, new(true, ["/srv/td-test"], ["example-ai"]), default);
      var model = new ServersViewModel(service); var page = new ServersPage(model, new Host(window)); content.Content = page;
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        frame.RequestedTheme = theme; var suffix = theme.ToString().ToLowerInvariant();
        model.Select(null); await SnapshotAsync(proof, "01-servers-" + suffix);
        model.Select(server.Id); await model.LoadFilesAsync(); await SnapshotAsync(proof, "02-files-" + suffix);
        model.Tab("Apps"); await model.LoadAppsAsync(); await SnapshotAsync(proof, "03-apps-" + suffix);
        model.Tab("Access"); await SnapshotAsync(proof, "04-access-" + suffix);
        model.Tab("Connection"); await SnapshotAsync(proof, "05-connection-" + suffix);
      }
      model.Select(null); frame.RequestedTheme = ElementTheme.Light; await Task.Delay(150);
      var authorizer = new ServerDialogAuthorizer(() => page.XamlRoot, frame.DispatcherQueue);
      var approval = authorizer.ApproveAsync(ServerCaller.Person, new(server.Id, server.Name, "Restart app", "td-test-web"), default).AsTask();
      await SnapshotAsync(proof, "07-approval-light");
      foreach (var popup in Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(page.XamlRoot))
        Find<ContentDialog>(popup.Child)?.Hide();
      Check("approval-cancel-denies-change", !await approval);
      Check("directory-model", model.Rows.Length == 1);
      model.Select(server.Id); model.Tab("Apps"); await model.LoadAppsAsync();
      Check("docker-container-list", model.Apps?.Single().Name == "td-test-web");
      var before = approves.Count;
      await model.RunAsync(async () => await service.ControlAsync(server.Id, FakeSsh.Id, "restart", ServerCaller.Person));
      Check("look-only-refuses-before-approval", model.IsError && approves.Count == before);
      await store.SetAccessAsync(server.Id, new(false, ["/srv/td-test"], ["example-ai"]), default); model.Refresh();
      await service.ControlAsync(server.Id, FakeSsh.Id, "restart", ServerCaller.Person);
      Check("approved-exact-container-control", approves.Count == before + 1 && runtime.Restarted);
      model.Select(server.Id); await model.LoadFilesAsync(); await model.ReadAsync(model.Files!.Entries.Single(f => f.Kind == "file"));
      Check("file-preview", model.Preview == "Sample server readme.\n");
      Check("no-horizontal-page-drift", page.ActualWidth <= frame.ActualWidth);
      frame.RequestedTheme = ElementTheme.Light; window.AppWindow.MoveAndResize(new RectInt32(40, 20, 560, 780));
      model.Tab("Access"); await SnapshotAsync(proof, "06-access-narrow");
      Check("narrow-page-width", page.ActualWidth <= frame.ActualWidth);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { failed.Add("proof-exception:" + ex.GetType().Name); }
    File.WriteAllText(Path.Combine(proof, "result.json"), JsonSerializer.Serialize(new { utc = DateTimeOffset.UtcNow, passed = passed.Count, failed = failed.Count, checksPassed = passed, checksFailed = failed }));
  }
  private static T? Find<T>(DependencyObject? node) where T : DependencyObject
  {
    if (node is null) return null; if (node is T found) return found;
    for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(node); i++)
      if (Find<T>(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(node, i)) is { } child) return child;
    return null;
  }
  private static async Task SnapshotAsync(string proof, string name)
  {
    await Task.Delay(300); File.WriteAllText(Path.Combine(proof, "stage.json"), JsonSerializer.Serialize(new { name }));
    using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(25));
    while (!File.Exists(Path.Combine(proof, name + ".ack"))) await Task.Delay(100, limit.Token);
  }
  private sealed class Host(Window window) : IServerPageHost
  {
    public nint WindowHandle => WinRT.Interop.WindowNative.GetWindowHandle(window);
    public IReadOnlyList<ServerAiAppChoice> AiApps => [new("example-ai", "Example connected AI")];
    public void OpenSession(string id) => throw new InvalidOperationException("No real session is opened by this proof.");
  }
  private sealed class MemorySecrets : ISecretStore
  {
    public ValueTask<byte[]?> ReadAsync(string name, CancellationToken cancellationToken = default) => ValueTask.FromResult<byte[]?>(null);
    public ValueTask WriteAsync(string name, ReadOnlyMemory<byte> value, CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
    public ValueTask DeleteAsync(string name, CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
  }
  private sealed class Approval : IServerAuthorizer
  {
    public int Count { get; private set; }
    public ValueTask<bool> ApproveAsync(ServerCaller caller, ServerAction action, CancellationToken ct) { Count++; return ValueTask.FromResult(true); }
  }
  private sealed class FakeSsh : IServerRuntime
  {
    public const string Id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    public bool Restarted { get; private set; }
    public ValueTask<ServerOutput> RunAsync(SavedServer server, ServerCommand command, CancellationToken ct)
    {
      string output;
      if (command.Script.StartsWith("docker ps", StringComparison.Ordinal)) output = JsonSerializer.Serialize(new { ID = Id, Names = "td-test-web", Image = "example/web:1", State = "running", Status = "Up 4 minutes", Ports = "127.0.0.1:18080 → 80/tcp" });
      else if (command.Script.StartsWith("docker restart", StringComparison.Ordinal)) { Restarted = true; output = Id; }
      else if (command.Input is { } input)
      {
        using var doc = JsonDocument.Parse(input); var q = doc.RootElement;
        output = q.GetProperty("op").GetString() == "list" ? JsonSerializer.Serialize(new { path = "/srv/td-test", entries = new[] { new { name = "readme.txt", path = "/srv/td-test/readme.txt", kind = "file", size = 22, modified = 0.0 }, new { name = "uploads", path = "/srv/td-test/uploads", kind = "folder", size = 0, modified = 0.0 } }, more = false }) : JsonSerializer.Serialize(new { path = "/srv/td-test/readme.txt", base64 = Convert.ToBase64String("Sample server readme.\n"u8), truncated = false });
      }
      else output = "Connected\nLinux\nFiles ready\nDocker available\n";
      return ValueTask.FromResult(new ServerOutput(0, output));
    }
    public ValueTask ImportKeyAsync(string serverId, string explicitlyPickedFile, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask RemoveKeyAsync(string serverId, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<string> ScanHostKeyAsync(SavedServer server, CancellationToken ct) => ValueTask.FromResult("ssh-ed25519 " + Convert.ToBase64String(new byte[64]));
    public ValueTask TrustHostKeyAsync(SavedServer server, string key, CancellationToken ct) => ValueTask.CompletedTask;
  }
}
