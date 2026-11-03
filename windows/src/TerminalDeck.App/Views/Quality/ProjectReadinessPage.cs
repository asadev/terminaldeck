using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Quality;
using static TerminalDeck.App.Views.Servers.ServerUi;

namespace TerminalDeck.App.Views.Quality;

public sealed class ProjectReadinessPage : Grid
{
  private readonly ProjectReadiness service;
  private readonly string folder;
  private readonly ReadinessDismissals? dismissals;
  private readonly Func<string, Task>? aiFix;
  private readonly Action<string>? openFile;
  private readonly TerminalDeck.Core.Code.ICodeProcessRunner? runner;
  private readonly StackPanel body = Stack(28);
  private string? provider;
  private ProjectReadinessReport? last;
  private string? lastApplied;
  private ProviderUpdate[] updates = [];
  private bool scanning;
  private bool showHidden;
  public ProjectReadinessPage(ProjectReadiness service, string folder, ReadinessDismissals? dismissals = null, Func<string, Task>? aiFix = null, Action<string>? openFile = null, TerminalDeck.Core.Code.ICodeProcessRunner? runner = null)
  {
    this.service = service; this.folder = folder; this.dismissals = dismissals; this.aiFix = aiFix; this.openFile = openFile; this.runner = runner;
    Style = Canvas(); body.Margin = new Thickness(24, 20, 24, 32); body.MaxWidth = 760; body.HorizontalAlignment = HorizontalAlignment.Center; Children.Add(Scroll(body)); Loaded += async (_, _) => await ScanAsync();
  }
  private async Task ScanAsync()
  {
    if (scanning) return; scanning = true; Render();
    try { last = await service.ScanAsync(folder, provider, runner); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { body.Children.Clear(); body.Children.Add(Words(ex.Message)); }
    finally { scanning = false; if (last is not null) Render(); }
  }
  private void Render()
  {
    body.Children.Clear(); var title = Words("Readiness", 20); title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; body.Children.Add(title);
    var controls = Horizontal();
    var picker = new ComboBox { Header = "Coding AI", ItemsSource = new[] { "All agents", "Claude", "Codex", "Gemini" }, SelectedIndex = provider switch { "claude" => 1, "codex" => 2, "gemini" => 3, _ => 0 }, IsEnabled = !scanning };
    picker.SelectionChanged += async (_, _) => { provider = picker.SelectedIndex switch { 1 => "claude", 2 => "codex", 3 => "gemini", _ => null }; await ScanAsync(); }; controls.Children.Add(picker);
    var refresh = Button("Check again", ScanAsync); refresh.IsEnabled = !scanning; controls.Children.Add(refresh);
    if (aiFix is not null) { var fix = Button("Fix with AI…", async () => await aiFix(provider ?? "codex"), true); fix.IsEnabled = !scanning; controls.Children.Add(fix); }
    var updateButton = Button("Check AI updates", async () =>
    {
      if (last is null || scanning) return; scanning = true; Render();
      try { using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) }; updates = await ReadinessProviderUpdates.CheckAsync(last, http); }
      catch (Exception error) when (error is not OutOfMemoryException) { await Dialog(XamlRoot, "Could not check AI updates", Words(error.Message), "Done").ShowAsync(); }
      finally { scanning = false; Render(); }
    }); updateButton.IsEnabled = !scanning && last is not null; controls.Children.Add(updateButton);

    if (scanning) { body.Children.Add(new ProgressBar { IsIndeterminate = true }); if (last is null) foreach (var width in new[] { .8, .6, .9 }) body.Children.Add(new Border { Height = 28, Opacity = width, Style = (Style)Application.Current.Resources["SurfaceCardStyle"] }); }
    if (last is not { } report) { body.Children.Add(controls); return; }
    var score = Stack(4); var summary = new Grid { ColumnSpacing = 18 };
    summary.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); summary.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    var ring = new Grid { Width = 64, Height = 64 };
    ring.Children.Add(new ProgressRing { Width = 64, Height = 64, IsIndeterminate = false, Minimum = 0, Maximum = Math.Max(1, report.Applicable), Value = report.Passing, Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["DeckProjectGreenBrush"] });
    ring.Children.Add(new TextBlock { Text = report.Passing + "/" + report.Applicable, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
    summary.Children.Add(ring); Grid.SetColumn(score, 1); summary.Children.Add(score);
    var status = Words(report.Band + " · " + report.Score + "/100", 15); status.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; score.Children.Add(status);
    score.Children.Add(Words(report.Passing + " of " + report.Applicable + " checks passing · " + (report.Applicable - report.Passing) + " to finish", muted: true));
    if (report.CappedBy is not null) score.Children.Add(Words("Score limited by " + report.CappedBy));
    score.Children.Add(Words("Checked " + report.ScannedAt.LocalDateTime.ToString("g") + ". Declared commands have not been run by this scan.", 12, true)); score.Children.Add(new ScrollViewer { Content = controls, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled }); body.Children.Add(Card(summary));
    if (lastApplied is { } token) body.Children.Add(Button("Undo last file fix…", async () =>
    {
      if (await Dialog(XamlRoot, "Undo file fix?", Words("This restores the reviewed original only if the file still matches the applied fix."), "Undo").ShowAsync() != ContentDialogResult.Primary) return;
      try { service.RollbackChange(folder, token); lastApplied = null; await ScanAsync(); }
      catch (Exception ex) when (ex is IOException or InvalidOperationException) { await Dialog(XamlRoot, "Could not undo", Words(ex.Message), "Done").ShowAsync(); }
    }));
    foreach (var update in updates)
    {
      var scope = "*machine*"; var id = "update-" + update.Provider; var dismissed = dismissals?.Hidden(scope).Contains(id) == true;
      if (dismissed && !showHidden) continue;
      var row = Stack(6); row.Children.Add(Words(update.Provider + " · Installed " + (update.Installed ?? "not found") + " · Latest " + (update.Latest ?? "not checked"), 16)); row.Children.Add(Words(update.Detail, muted: true));
      if (dismissals is not null && update.Status != "pass") row.Children.Add(Button(dismissed ? "Restore update" : "Hide update", () => { dismissals.Set(scope, id, !dismissed); Render(); return Task.CompletedTask; })); body.Children.Add(row);
    }
    var hidden = (dismissals?.Hidden(folder) ?? []).Concat(dismissals?.Hidden("*machine*") ?? []).ToArray();
    if (hidden.Length > 0) body.Children.Add(Button(showHidden ? "Hide dismissed checks" : hidden.Length + " checks hidden · Show", () => { showHidden = !showHidden; Render(); return Task.CompletedTask; }));
    StackPanel? sectionRows = null; string? sectionName = null;
    foreach (var check in report.Checks.OrderBy(c => c.Gate && c.Status != "pass" ? -1 : c.Status == "fail" ? 0 : c.Status == "warn" ? 1 : c.Status == "pass" ? 3 : 2).ThenByDescending(c => c.Weight))
    {
      if (!showHidden && hidden.Contains(check.Id)) continue;
      var nextSection = check.Status == "pass" ? "Done" : "To finish";
      if (nextSection != sectionName) { sectionName = nextSection; var section = Stack(12); var heading = Words(nextSection, 15); heading.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; section.Children.Add(heading); sectionRows = Stack(0); section.Children.Add(Card(sectionRows)); body.Children.Add(section); }
      var labels = Stack(4); labels.Children.Add(Words((check.Status == "pass" ? "✓ " : check.Status == "fail" ? "× " : check.Status == "warn" ? "! " : "– ") + check.Title, 13)); labels.Children.Add(Words(check.Detail, 12, true));
      var actions = Horizontal();
      if (check.Fix is not null) { var fix = Button("Review fix…", () => FixAsync(check.Fix)); fix.IsEnabled = !scanning; actions.Children.Add(fix); }
      if (check.File is not null && openFile is not null) actions.Children.Add(Button("Open file", () => { openFile(check.File); return Task.CompletedTask; }));
      if (dismissals is not null && check.Status != "pass") actions.Children.Add(Button(hidden.Contains(check.Id) ? "Restore" : "Hide", () => { dismissals.Set(folder, check.Id, !hidden.Contains(check.Id)); Render(); return Task.CompletedTask; }));
      var row = Stack(8); row.Children.Add(labels); row.Children.Add(actions); row.Margin = new Thickness(16, 14, 16, 14); sectionRows!.Children.Add(row);
    }
  }
  private async Task FixAsync(string fix)
  {
    try
    {
      if (fix is "git-init" or "create-lockfile" or "untrack-secrets")
      {
        var command = await service.PreviewCommandAsync(folder, fix, runner);
        var review = Stack(12); review.Children.Add(Words(command.Summary)); review.Children.Add(Words(command.Executable + " " + string.Join(" ", command.Arguments))); review.Children.Add(Words("Touches: " + string.Join(", ", command.Touches), muted: true));
        if (await Dialog(XamlRoot, "Review project command", review, "Run reviewed command").ShowAsync() == ContentDialogResult.Primary) { await service.ApplyCommandAsync(folder, command.Token, runner); await ScanAsync(); }
        return;
      }
      var preview = service.PreviewChange(folder, fix); var content = Stack(12);
      content.Children.Add(Words(preview.File + (preview.Before is null ? " will be created." : " will be updated only if it still matches this review.")));
      foreach (var (label, text) in new[] { ("Before", preview.Before ?? "File does not exist"), ("After", preview.After) }) content.Children.Add(new Expander { Header = label, IsExpanded = label == "After", Content = new TextBox { Text = text, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 240, FontFamily = DeckFonts.Mono }, HorizontalAlignment = HorizontalAlignment.Stretch });
      if (await Dialog(XamlRoot, "Review " + preview.File, new ScrollViewer { Content = content, MaxHeight = 520 }, "Apply fix").ShowAsync() != ContentDialogResult.Primary) return;
      service.ApplyChange(folder, preview.Token); lastApplied = preview.Token; await ScanAsync();
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { await Dialog(XamlRoot, "Could not apply fix", Words(ex.Message), "Done").ShowAsync(); }
  }
}
