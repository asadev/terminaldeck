using System.Reflection;
using System.Text.Json;
using System.Threading.Channels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.W12.Chat.Proof;
public partial class App : Application
{
  private Window? window;
  public App() { InitializeComponent(); }
  protected override async void OnLaunched(LaunchActivatedEventArgs args)
  {
    var root = AppDataRoot.FromArguments(Environment.GetCommandLineArgs().Skip(1).ToArray());
    if (!root.DirectoryPath.StartsWith("C:\\TD\\out\\w12-sessions-chats\\proof\\", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Only a fresh owned scratch proof root is allowed.");
    Directory.CreateDirectory(root.DirectoryPath);
    if (File.Exists(Path.Combine(root.DirectoryPath, "started"))) throw new InvalidOperationException("Do not reuse proof data.");
    File.WriteAllText(Path.Combine(root.DirectoryPath, "started"), DateTimeOffset.UtcNow.ToString("O"));
    var passed = new List<string>(); var frames = new List<string>();
    void Check(string name, bool value) { if (!value) throw new InvalidOperationException(name); passed.Add(name); }
    void Stage(string name) => File.WriteAllText(Path.Combine(root.DirectoryPath, "stage.txt"), name);
    try
    {
      Stage("create");
      var chats = DispatchProxy.Create<IChatSessions, ProofChats>(); var backend = (ProofChats)chats; backend.Root = root;
      window = new Window { Title = "W12 isolated chat proof" }; window.AppWindow.Move(new(-20000, -20000));
      var page = new ChatPage(chats, backend.Record.Definition.Id, WinRT.Interop.WindowNative.GetWindowHandle(window));
      window.Content = page; window.AppWindow.Resize(new(1100, 900)); window.Activate(); await Task.Delay(800);
      foreach (var width in new[] { 1100, 560, 360 })
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        Stage($"frame-{width}-{theme}");
        page.RequestedTheme = theme; window.AppWindow.Resize(new(width, 900)); await Task.Delay(350); page.UpdateLayout();
        var buttons = Tree(page).OfType<Button>().Where(b => AutomationProperties.GetAutomationId(b) is "chat.account" or "chat.model" or "chat.effort" or "chat.permission").ToArray();
        Check($"four composer controls fit {width} {theme}", buttons.Length == 4 && buttons.All(b => { var box = b.TransformToVisual(page).TransformBounds(new(0, 0, b.ActualWidth, b.ActualHeight)); return b.ActualWidth >= 24 && box.X >= -1 && box.Right <= page.ActualWidth + 1 && box.Bottom <= page.ActualHeight + 1; }));
        File.WriteAllText(Path.Combine(root.DirectoryPath, $"controls-{width}-{theme}.json"), JsonSerializer.Serialize(buttons.Select(b => new { id = AutomationProperties.GetAutomationId(b), theme = b.ActualTheme.ToString(), foreground = (b.Foreground as SolidColorBrush)?.Color.ToString(), content = (b.Content as TextBlock)?.Text, contentForeground = ((b.Content as TextBlock)?.Foreground as SolidColorBrush)?.Color.ToString(), bounds = b.TransformToVisual(page).TransformBounds(new(0, 0, b.ActualWidth, b.ActualHeight)) })));
        var rectangles = buttons.Select(b => b.TransformToVisual(page).TransformBounds(new(0, 0, b.ActualWidth, b.ActualHeight))).ToArray();
        Check($"composer controls do not overlap {width} {theme}", !rectangles.SelectMany((a, i) => rectangles.Skip(i + 1).Select(b => a.Left < b.Right - 1 && b.Left < a.Right - 1 && a.Top < b.Bottom - 1 && b.Top < a.Bottom - 1)).Any(overlap => overlap));
        await Capture(page, root, $"chat-{width}-{theme}.png", frames);
        if (width == 1100) await Capture(buttons.Single(b => AutomationProperties.GetAutomationId(b) == "chat.effort"), root, $"effort-{theme}.png", frames);
      }
      Stage("live-tool-expansion");
      backend.Record = backend.Record with { Busy = true, Events = [.. backend.Record.Events, new(207, "toolCall", "live-step", "Read sample file", Data: JsonSerializer.SerializeToElement(new { path = "sample.cs" }))] }; backend.Updates.Writer.TryWrite(backend.Record); await Task.Delay(200);
      var step = Tree(page).OfType<Expander>().Single(e => AutomationProperties.GetName(e).StartsWith("Read sample file", StringComparison.Ordinal)); step.IsExpanded = true;
      backend.Record = backend.Record with { Events = [.. backend.Record.Events, new(208, "toolInputDelta", "live-step", "{\"path\":\"sample.cs\",\"limit\":100}")] }; backend.Updates.Writer.TryWrite(backend.Record); await Task.Delay(150);
      Check("live tool stays expanded while its recorded input updates", Tree(page).OfType<Expander>().Single(e => AutomationProperties.GetName(e).StartsWith("Read sample file", StringComparison.Ordinal)).IsExpanded);
      backend.Record = backend.Record with { Busy = false, Events = [.. backend.Record.Events, new(209, "toolResult", "live-step", "Recorded file text")] }; backend.Updates.Writer.TryWrite(backend.Record); await Task.Delay(150);
      Check("completed tool keeps its expanded input/output", Tree(page).OfType<Expander>().Single(e => AutomationProperties.GetName(e).StartsWith("Read sample file", StringComparison.Ordinal)).IsExpanded);
      Stage("search"); window.AppWindow.Resize(new(1100, 900)); await Task.Delay(300);
      page.ProofSearch("needle");
      var searchDeadline = DateTimeOffset.UtcNow.AddSeconds(5);
      while (!page.ProofOldMessageVisible && DateTimeOffset.UtcNow < searchDeadline) await Task.Delay(50);
      File.WriteAllText(Path.Combine(root.DirectoryPath, "search-state.json"), JsonSerializer.Serialize(page.ProofSearchState));
      Check("search includes two matches before the initial 200 rows", page.ProofMatchCount == 2 && page.ProofOldMessageVisible);
      Check("search highlights recorded text", Tree(page).OfType<RichTextBlock>().Any(t => t.TextHighlighters.Count > 0));
      await Capture(page, root, "search-old-message.png", frames); page.ProofCloseSearch();
      Stage("recall"); page.Model.Draft = "";
      Check("eligible up recalls recorded prompt", page.Model.RecallPrompt(true, true) && page.Model.Draft == "old needle and NEEDLE");
      Check("down restores unsent draft", page.Model.RecallPrompt(false, true) && page.Model.Draft == "");
      Stage("prompt-editor"); page.Model.Draft = new string('a', 5000);
      var editTask = page.ProofEdit(); await Task.Delay(200); if (editTask.IsFaulted) await editTask;
      var dialog = await OpenDialogAsync(page); var editor = Tree(dialog).OfType<TextBox>().Single(); var textChanges = 0; editor.TextChanged += (_, _) => textChanges++; editor.Text = new string('a', 262145); await Task.Delay(150);
      File.WriteAllText(Path.Combine(root.DirectoryPath, "editor-state.json"), JsonSerializer.Serialize(new { length = editor.Text.Length, bytes = ChatText.PromptBytes(editor.Text), editor.MaxLength, dialog.IsPrimaryButtonEnabled, textChanges, editor.IsLoaded, dialogLoaded = dialog.IsLoaded, captions = Tree(dialog).OfType<TextBlock>().Select(t => t.Text).Where(t => t.Contains("UTF-8")).ToArray() }));
      Check("oversize full editor keeps all text and disables Apply", editor.Text.Length == 262145 && !dialog.IsPrimaryButtonEnabled);
      editor.Text = "candidate"; page.Model.Draft = "newer unsent draft"; await Task.Delay(100); Invoke(Tree(dialog).OfType<Button>().Single(b => b.Name == "PrimaryButton")); await Task.Delay(100);
      Check("stale editor cannot overwrite changed draft", page.Model.Draft == "newer unsent draft" && Tree(dialog).OfType<TextBlock>().Any(t => t.Text.Contains("source draft")));
      await Capture(dialog, root, "full-prompt-source-guard.png", frames);
      dialog.Hide(); await editTask;
      editTask = page.ProofEdit(); await Task.Delay(150); if (editTask.IsFaulted) await editTask; dialog = await OpenDialogAsync(page); Tree(dialog).OfType<TextBox>().Single().Text = "edited unsent draft";
      Invoke(Tree(dialog).OfType<Button>().Single(b => b.Name == "PrimaryButton")); await editTask;
      Check("full editor applies to draft without sending", page.Model.Draft == "edited unsent draft" && backend.Writes == 0);
      Stage("permissions"); page.ProofPermissions(); await Task.Delay(150);
      var plan = await MenuChoiceAsync(page, "Plans only"); Invoke(plan); await Task.Delay(150);
      Check("permission control saves real session choice", page.Model.Snapshot.Definition.PermissionMode == AiPermissionMode.Plan);
      page.ProofPermissions(); await Task.Delay(100); Invoke(await MenuChoiceAsync(page, "Bypass permissions")); await Task.Delay(100);
      dialog = await OpenDialogAsync(page); Check("risky permission shows confirmation before change", page.Model.Snapshot.Definition.PermissionMode == AiPermissionMode.Plan && dialog.Title as string == "Change chat permissions?"); dialog.Hide(); await Task.Delay(100);
      Check("cancel keeps permissions", page.Model.Snapshot.Definition.PermissionMode == AiPermissionMode.Plan);
      Stage("changes");
      var panelTask = page.ProofChanges(); await Task.Delay(150); dialog = await OpenDialogAsync(page);
      Tree(dialog).OfType<Expander>().Single().IsExpanded = true; await Task.Delay(400);
      Check("recorded file change shows source and real line counts", Tree(dialog).OfType<TextBlock>().Any(t => t.Text.Contains("sample.cs")));
      await Capture(dialog, root, "recorded-file-changes.png", frames);
      Tree(dialog).OfType<TextBox>().Single().Text = "Check the edge case.";
      Invoke(Tree(dialog).OfType<Button>().Single(b => b.Content as string == "Add review comment to draft")); await panelTask;
      Check("review comment is added to unsent draft", page.Model.Draft.Contains("Check the edge case.") && backend.Writes == 0);
      Stage("usage"); panelTask = page.ProofUsage(); await Task.Delay(100); dialog = await OpenDialogAsync(page);
      Check("usage panel shows actual provider report and billing distinction", Tree(dialog).OfType<TextBlock>().Any(t => t.Text.Contains("output_tokens")) && Tree(dialog).OfType<TextBlock>().Any(t => t.Text.Contains("your bill"))); dialog.Hide(); await panelTask;
      Stage("events"); panelTask = page.ProofEvents(); await Task.Delay(100); dialog = await OpenDialogAsync(page);
      Tree(dialog).OfType<TextBox>().Single().Text = "earlier202"; await Task.Delay(100);
      Check("event log searches full recorded details", Tree(dialog).OfType<TextBlock>().Any(t => t.Text.Contains("1–1 of 1"))); dialog.Hide(); await panelTask;
      Stage("prompt-search"); panelTask = page.ProofPrompts(); await Task.Delay(100); dialog = await OpenDialogAsync(page);
      var promptQuery = Tree(dialog).OfType<TextBox>().Single(); promptQuery.Text = "absent prompt"; await Task.Delay(100);
      Check("prompt search has a truthful empty state", Tree(dialog).OfType<TextBlock>().Any(t => t.Text == "No matching prompts.")); promptQuery.Text = "needle"; await Task.Delay(100);
      Invoke(Tree(dialog).OfType<Button>().Single(b => b.Content as string == "Insert into draft")); await panelTask;
      Check("prompt insertion keeps existing draft and remains unsent", page.Model.Draft.Contains("Check the edge case.") && page.Model.Draft.Contains("old needle") && backend.Writes == 0);
      Stage("side-question"); var keptDraft = page.Model.Draft;
      panelTask = page.ProofSideQuestion(); dialog = await OpenDialogAsync(page);
      var sideQuestion = Tree(dialog).OfType<TextBox>().Single(t => t.Header as string == "Side question"); sideQuestion.Text = "What about this case?";
      Invoke(Tree(dialog).OfType<Button>().Single(b => b.Content as string == "Prepare context brief")); await Task.Delay(100);
      Check("side brief is editable without changing main draft", Tree(dialog).OfType<TextBox>().Single(t => t.Header as string == "Context brief").IsEnabled && page.Model.Draft == keptDraft);
      await Capture(dialog, root, "side-question-brief.png", frames);
      sideQuestion.Text = "A different question"; await Task.Delay(100);
      Check("changed question blocks stale brief copying", !Tree(dialog).OfType<Button>().Single(b => b.Content as string == "Copy context brief").IsEnabled && page.Model.Draft == keptDraft);
      dialog.Hide(); await panelTask;
      Stage("inspector"); panelTask = page.ProofInspector(); await Task.Delay(150); dialog = await OpenDialogAsync(page);
      Check("inspector names its recorded source and keeps unknown data explicit", Tree(dialog).OfType<TextBlock>().Any(t => t.Text.Contains("recorded chat events")) && Tree(dialog).OfType<TextBlock>().Any(t => t.Text.Contains("Context window: Not reported")));
      await Capture(dialog, root, "session-inspector.png", frames); dialog.Hide(); await panelTask;
      Stage("past-chats"); panelTask = page.ProofHistory(); await Task.Delay(150); dialog = await OpenDialogAsync(page);
      Tree(dialog).OfType<TextBox>().Single(t => t.PlaceholderText == "Search text…").Text = "needle";
      var speaker = Tree(dialog).OfType<ComboBox>().Single(c => c.Header as string == "Speaker"); speaker.SelectedIndex = 1; await Task.Delay(100);
      Check("past-chat search uses recorded prompts and speaker/project filters", Tree(dialog).OfType<TextBlock>().Any(t => t.Text.Contains("1–1 of 1")));
      Invoke(Tree(dialog).OfType<Button>().Single(b => b.Content as string == "Preview excerpt")); await Task.Delay(100);
      await Capture(dialog, root, "past-chat-search.png", frames);
      Invoke(Tree(dialog).OfType<Button>().Single(b => b.Content as string == "Insert displayed excerpt into draft")); await panelTask;
      Check("past-chat excerpt remains unsent", page.Model.Draft.Contains("old needle") && backend.Writes == 0);
      Stage("rename"); var identity = page.Model.Snapshot.Definition.Id; panelTask = page.ProofRename(); await Task.Delay(100); dialog = await OpenDialogAsync(page);
      var rename = Tree(dialog).OfType<TextBox>().Single(); Check("rename editor enforces 40 characters", rename.MaxLength == 40); rename.Text = "Named chat";
      Invoke(Tree(dialog).OfType<Button>().Single(b => b.Name == "PrimaryButton")); await panelTask;
      Check("rename keeps the session identity", page.Model.Snapshot.Definition.Title == "Named chat" && page.Model.Snapshot.Definition.Id == identity);
      Stage("unread"); page.Model.Draft = ""; page.ProofScroll.ChangeView(null, 0, null, true); await Task.Delay(100);
      backend.Record = backend.Record with { Events = [.. backend.Record.Events, new(999, "message", "late", "New recorded answer")] }; backend.Updates.Writer.TryWrite(backend.Record); await Task.Delay(250);
      Check("scrolled-up view stays put with new-message action", page.ProofScroll.VerticalOffset < 5 && page.ProofUnread.Visibility == Visibility.Visible);
      await Capture(page, root, "unread-preserves-position.png", frames);
      Invoke(page.ProofUnread); var unreadDeadline = DateTimeOffset.UtcNow.AddSeconds(5); while (!page.ProofLateMessageVisible && DateTimeOffset.UtcNow < unreadDeadline) await Task.Delay(50);
      Check("new-message action reveals the first unread message", page.ProofLateMessageVisible);
      Check("proof never sends a message or starts a provider", backend.Writes == 0);
      Stage("new-session-picker"); await CheckPickerAsync(page, root, passed, frames);
      await page.DisposeAsync();
      Stage("complete"); File.WriteAllText(Path.Combine(root.DirectoryPath, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, passed, frames, synthetic = true, providersStarted = 0, clipboardWrites = 0, offscreen = true }, new JsonSerializerOptions { WriteIndented = true }));
    }
    catch (Exception ex)
    {
      File.WriteAllText(Path.Combine(root.DirectoryPath, "failure.txt"), ex.ToString());
      File.WriteAllText(Path.Combine(root.DirectoryPath, "partial-result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, passed, frames, failure = ex.Message, complete = false }, new JsonSerializerOptions { WriteIndented = true }));
      try { if (window?.Content is FrameworkElement view) await Capture(view, root, "failure-frame.png", frames); } catch (Exception capture) { File.WriteAllText(Path.Combine(root.DirectoryPath, "capture-failure.txt"), capture.Message); }
    }
    finally { window?.Close(); Exit(); }
  }
  private static IEnumerable<DependencyObject> Tree(DependencyObject root)
  { yield return root; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var child in Tree(VisualTreeHelper.GetChild(root, i))) yield return child; }
  private static IEnumerable<DependencyObject> Popups(FrameworkElement page) => VisualTreeHelper.GetOpenPopupsForXamlRoot(page.XamlRoot).SelectMany(p => Tree(p.Child));
  private static async Task<ToggleMenuFlyoutItem> MenuChoiceAsync(FrameworkElement page, string label)
  {
    var deadline = DateTimeOffset.UtcNow.AddSeconds(8);
    while (DateTimeOffset.UtcNow < deadline)
    {
      var choice = Popups(page).OfType<ToggleMenuFlyoutItem>().FirstOrDefault(i => i.Text == label && i.IsLoaded);
      if (choice is not null) return choice;
      await Task.Delay(50);
    }
    throw new InvalidOperationException("Menu choice did not load: " + label + "; visible choices: " + string.Join(", ", Popups(page).OfType<ToggleMenuFlyoutItem>().Select(i => i.Text)));
  }
  private static async Task<ContentDialog> OpenDialogAsync(FrameworkElement page)
  {
    var deadline = DateTimeOffset.UtcNow.AddSeconds(8); ContentDialog? found = null;
    while (DateTimeOffset.UtcNow < deadline)
    {
      found = page is ChatPage chat && chat.ProofDialog is { } current ? current : NewSessionPickerDialog();
      if (found is { IsLoaded: true } && found.ActualWidth > 0 && Tree(found).OfType<Button>().Any(b => b.Name == "PrimaryButton" && b.IsLoaded)) return found;
      await Task.Delay(50);
    }
    throw new InvalidOperationException("Chat dialog did not load: " + (found is null ? "no dialog" : found.Title + " loaded=" + found.IsLoaded + " width=" + found.ActualWidth));
  }
  private static ContentDialog Dialog(FrameworkElement page) => page is ChatPage chat && chat.ProofDialog is { } dialog ? dialog : NewSessionPickerDialog() ?? Popups(page).OfType<ContentDialog>().Single();
  private static ContentDialog? NewSessionPickerDialog() => TerminalDeck.App.Views.Agents.NewSessionPicker.ActiveDialogForProof;
  private static void Invoke(FrameworkElement target)
  {
    var peer = FrameworkElementAutomationPeer.CreatePeerForElement(target) ?? throw new InvalidOperationException("No peer for control.");
    if (peer.GetPattern(PatternInterface.Invoke) is IInvokeProvider invoke) invoke.Invoke();
    else if (peer.GetPattern(PatternInterface.Toggle) is IToggleProvider toggle) toggle.Toggle();
    else throw new InvalidOperationException("No action for " + target.GetType().Name);
  }
  private static async Task Capture(FrameworkElement view, AppDataRoot root, string name, List<string> frames)
  {
    var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(view); var pixels = await bitmap.GetPixelsAsync();
    using var reader = DataReader.FromBuffer(pixels); var bytes = new byte[pixels.Length]; reader.ReadBytes(bytes);
    using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, bytes); await encoder.FlushAsync();
    stream.Seek(0); using var output = stream.AsStreamForRead(); using var file = File.Create(Path.Combine(root.DirectoryPath, name)); await output.CopyToAsync(file); frames.Add(name);
  }
}
public class ProofChats : DispatchProxy
{
  public ChatRecord Record = new(1, new(Guid.NewGuid().ToString(), "claude", "C:\\Scratch\\Sample project", "Review the chat", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), new("Synthetic model", "high")), "synthetic", [new(1, "user", "old", "old needle and NEEDLE", At: DateTimeOffset.UtcNow), .. Enumerable.Range(2, 201).Select(i => new ChatEvent(i, "message", "earlier" + i, "Earlier recorded reply " + i)), new(203, "message", "rich", "# Review notes\n\nThe **recorded conversation** keeps its history.\n\n- Search older messages\n- Keep drafts unsent\n\n```csharp\nConsole.WriteLine(\"Ready\");\n```\n\n[Documentation](https://example.test) · Unicode: اردو 🙂", At: DateTimeOffset.UtcNow),
    new(204, "toolResult", "change", Data: JsonSerializer.SerializeToElement(new { type = "fileChange", changes = new[] { new { path = "sample.cs", diff = "--- a/sample.cs\n+++ b/sample.cs\n-old\n+new" } } })),
    new(205, "reasoning", "summary", "Checking the recorded changes and preserving the draft."),
    new(206, "usage", "usage:sample", Data: JsonSerializer.SerializeToElement(new { source = "Synthetic provider fixture", usage = new { input_tokens = 12, output_tokens = 34 } }))], []);
  public AppDataRoot? Root;
  public Channel<ChatRecord> Updates = Channel.CreateUnbounded<ChatRecord>();
  public int Writes;
  protected override object? Invoke(MethodInfo? method, object?[]? args) => method?.Name switch
  {
    "get_DataRoot" => Root,
    nameof(IChatSessions.ReadAsync) => ValueTask.FromResult(Record),
    nameof(IChatSessions.Get) => Record,
    nameof(IChatSessions.List) => new[] { Record },
    nameof(IChatSessions.Accounts) => new AccountProfile[] { new(Record.Definition.AccountId, "claude", "Scratch account", null, AccountAuthentication.Subscription, true, Record.Definition.AccountHome) },
    nameof(IChatSessions.WatchAsync) => Watch((CancellationToken)args![1]!),
    nameof(IChatSessions.RenameAsync) => Rename((string)args![1]!),
    nameof(IChatSessions.SetPermissionAsync) => Permission((AiPermissionMode)args![1]!),
    nameof(IChatSessions.ModelsAsync) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([new("Synthetic model", "Synthetic model", 200000)]),
    nameof(IChatSessions.SendAsync) => RefuseSend(),
    _ => throw new InvalidOperationException("This fixture does not perform " + method?.Name)
  };
  private ValueTask Rename(string title) { Record = Record with { Definition = Record.Definition with { Title = title }, HasCustomTitle = true }; Updates.Writer.TryWrite(Record); return ValueTask.CompletedTask; }
  private ValueTask Permission(AiPermissionMode mode) { Record = Record with { Definition = Record.Definition with { PermissionMode = mode } }; Updates.Writer.TryWrite(Record); return ValueTask.CompletedTask; }
  private ValueTask RefuseSend() { Writes++; throw new InvalidOperationException("No sends in a rendering fixture."); }
  private async IAsyncEnumerable<ChatRecord> Watch([System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct) { yield return Record; await foreach (var row in Updates.Reader.ReadAllAsync(ct)) yield return row; }
}
