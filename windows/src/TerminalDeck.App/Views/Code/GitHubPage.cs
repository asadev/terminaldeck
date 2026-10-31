using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Code;

namespace TerminalDeck.App.Views.Code;

// GitHub, read-only: sign-in through the gh CLI (no secret stored here), each
// open project's pull requests, issues and checks, and your repositories.
public sealed class GitHubPage : CodePage
{
  private readonly GitHubClient github;
  private GitHubAuthState? auth;
  private readonly Dictionary<string, (GitHubRepoRef? Repo, GitHubFailure? Failure)> repos = [];
  private IReadOnlyList<GitHubRepoSummary>? mine;
  private GitHubFailure? mineFailure;
  private string tab = "Pull requests";
  private readonly Dictionary<string, object> lists = [];
  private string repoQuery = "";

  public GitHubPage(ICodePageHost host, GitHubClient github) : base(host, "GitHub", 340) { this.github = github; }

  protected override async Task OnShownAsync()
  {
    auth = await github.AuthAsync();
    ShowSignIn(); ShowDetail();
    foreach (var root in RootList.ToArray()) await RepoAsync(root);
  }
  private void ShowSignIn()
  {
    ClearProblem();
    if (auth is null) return;
    if (auth.Connected)
    {
      var who = auth.Login is { } login ? "Connected as " + login + (auth.Name is { Length: > 0 } name ? " (" + name + ")" : "") : "Connected";
      var bar = new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Success, Title = who, Message = GitHubRules.SourceSentence(auth.Source, auth.Host) };
      Messages.Children.Add(bar); return;
    }
    var failure = auth.Failure ?? new GitHubFailure("not-authenticated", "This computer is not signed in to GitHub.", GitHubRules.LoginCommand);
    var info = new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Title = GitHubRules.FailureTitle(failure.Kind), Message = GitHubRules.Explanation(failure) };
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    if (failure.Kind == "gh-missing") actions.Children.Add(CodeUi.Action("Install GitHub CLI", () => Host.OpenInBrowserAsync(GitHubRules.InstallUrl)));
    else
    {
      // Signing in is gh's own browser flow; this app never sees or stores the token.
      actions.Children.Add(CodeUi.Action("Sign in with GitHub CLI", async () =>
      {
        CodeUi.Copy(GitHubRules.LoginCommand);
        if (Active is { } root) await Host.OpenTerminalAsync(root, root.Folder);
        Host.Notice("Paste gh auth login into the terminal and follow it, then refresh GitHub.");
      }, primary: true));
      actions.Children.Add(CodeUi.Action("Copy command", () => { CodeUi.Copy(GitHubRules.LoginCommand); Host.Notice("gh auth login copied."); return Task.CompletedTask; }));
    }
    actions.Children.Add(CodeUi.Action("Check again", () => RefreshAllAsync()));
    info.Content = actions; Messages.Children.Add(info);
  }
  private async Task RepoAsync(CodeRoot root)
  {
    try { repos[root.Key] = (await github.RepoAsync(root.Folder), null); }
    catch (GitHubException ex) { repos[root.Key] = (null, ex.Failure); }
    UpdateSummary(root);
  }
  protected override UIElement GroupSummary(CodeRoot root)
  {
    if (!repos.TryGetValue(root.Key, out var state)) return new TextBlock();
    var text = state.Repo?.NameWithOwner ?? GitHubRules.FailureTitle(state.Failure?.Kind ?? "error");
    var words = CodeUi.Words(text, 11, true, wrap: false); words.MaxWidth = 160; ToolTipService.SetToolTip(words, state.Repo?.Url ?? state.Failure?.Message); return words;
  }

  protected override async Task FillAsync(CodeRoot root, StackPanel content)
  {
    if (!repos.ContainsKey(root.Key)) await RepoAsync(root);
    content.Children.Clear();
    var (repo, failure) = repos[root.Key];
    if (repo is null)
    {
      var f = failure ?? new GitHubFailure("error", "GitHub could not read this folder.");
      var title = CodeUi.Words(GitHubRules.FailureTitle(f.Kind), 12); title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
      content.Children.Add(title); content.Children.Add(CodeUi.Words(GitHubRules.Explanation(f), 12, true));
      return;
    }
    foreach (var section in new[] { "Pull requests", "Issues", "Checks" })
    {
      var row = CodeUi.Row(CodeUi.Columns((CodeUi.Icon(section switch { "Pull requests" => "", "Issues" => "", _ => "" }, 12), CodeUi.Auto), (CodeUi.Words(section, 13), CodeUi.Star)),
        section + " in " + repo.NameWithOwner, Active?.Key == root.Key && tab == section);
      row.Click += (_, _) => { tab = section; MakeActive(root); RefreshHeads(); };
      content.Children.Add(row);
    }
    var open = CodeUi.Row(CodeUi.Columns((CodeUi.Icon("", 12), CodeUi.Auto), (CodeUi.Words("Open on GitHub", 13), CodeUi.Star)), "Open " + repo.NameWithOwner + " in Terminal Deck’s browser", false);
    open.Click += async (_, _) => { open.IsChecked = false; await GuardAsync(() => Host.OpenInBrowserAsync(repo.Url)); };
    content.Children.Add(open);
    if (Active?.Key == root.Key) await LoadAsync(root);
  }
  private void RefreshHeads() { foreach (var root in RootList) RefillGroup(root); }

  private async Task LoadAsync(CodeRoot root)
  {
    var key = root.Key + "|" + tab;
    ShowDetail();
    if (repos.GetValueOrDefault(root.Key).Repo is null) return;
    try
    {
      object result = tab switch
      {
        "Issues" => await github.IssuesAsync(root.Folder),
        "Checks" => await github.ChecksAsync(root.Folder, null),
        _ => await github.PullsAsync(root.Folder)
      };
      lists[key] = result;
    }
    catch (GitHubException ex) { lists[key] = ex.Failure; }
    if (Active?.Key == root.Key) ShowDetail();
  }

  protected override void ShowDetail()
  {
    var stack = CodeUi.Stack(10);
    if (Active is { } root && repos.GetValueOrDefault(root.Key).Repo is { } repo)
    {
      var picture = Host.Picture(root, 20);
      var name = CodeUi.Words(repo.NameWithOwner, 15, wrap: false); name.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
      var openRepo = CodeUi.Action("Open on GitHub", () => Host.OpenInBrowserAsync(repo.Url), glyph: "");
      stack.Children.Add(CodeUi.Columns((picture, CodeUi.Auto), (name, CodeUi.Star), (openRepo, CodeUi.Auto)));
      var heading = CodeUi.Words(tab, 13, true); stack.Children.Add(heading);
      stack.Children.Add(ListView(lists.GetValueOrDefault(root.Key + "|" + tab)));
    }
    else if (Active is { } other)
      stack.Children.Add(CodeUi.Card(CodeUi.Words(repos.TryGetValue(other.Key, out var state) && state.Failure is { } f ? GitHubRules.Explanation(f) : "Reading " + other.Name + "…", muted: true)));
    stack.Children.Add(MyRepos());
    Detail.Child = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
  }
  private FrameworkElement ListView(object? data)
  {
    var list = CodeUi.Stack(2);
    switch (data)
    {
      case null: list.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 3 }); break;
      case GitHubFailure failure:
        list.Children.Add(CodeUi.Words(GitHubRules.FailureTitle(failure.Kind) + " — " + GitHubRules.Explanation(failure), 12, true));
        if (GitHubRules.OffersRetry(failure) && Active is { } root) list.Children.Add(CodeUi.Action("Try again", () => LoadAsync(root)));
        break;
      case IReadOnlyList<GitHubPull> pulls:
        if (pulls.Count == 0) list.Children.Add(CodeUi.Words("No open pull requests.", 12, true));
        foreach (var pull in pulls)
        {
          var meta = new List<string> { "#" + pull.Number };
          if (pull.Author is { } a) meta.Add(a);
          if (GitHubRules.FormatAge(pull.UpdatedAt, DateTimeOffset.UtcNow) is { Length: > 0 } age) meta.Add(age);
          if (GitHubRules.ReviewLabel(pull.Review) is { } review) meta.Add(review);
          if (pull.Badge == "draft") meta.Add("Draft");
          if (pull.FromFork) meta.Add("from a fork");
          list.Children.Add(ItemRow(pull.Title, string.Join(" · ", meta), pull.Url, ChecksMark(pull.Checks), pull.Labels));
        }
        if (pulls.Count >= GitHubClient.ListLimit) list.Children.Add(CodeUi.Words("Showing the newest " + GitHubClient.ListLimit + ".", 11, true));
        break;
      case IReadOnlyList<GitHubIssue> issues:
        if (issues.Count == 0) list.Children.Add(CodeUi.Words("No open issues.", 12, true));
        foreach (var issue in issues)
        {
          var meta = new List<string> { "#" + issue.Number };
          if (issue.Author is { } a) meta.Add(a);
          if (GitHubRules.FormatAge(issue.UpdatedAt, DateTimeOffset.UtcNow) is { Length: > 0 } age) meta.Add(age);
          if (issue.Assignees.Count > 0) meta.Add("→ " + string.Join(", ", issue.Assignees));
          list.Children.Add(ItemRow(issue.Title, string.Join(" · ", meta), issue.Url, null, issue.Labels));
        }
        break;
      case IReadOnlyList<GitHubRun> runs:
        if (runs.Count == 0) list.Children.Add(CodeUi.Words("No recent checks.", 12, true));
        foreach (var run in runs)
          list.Children.Add(ItemRow(run.Name, GitHubRules.RunWord(run) + " · " + run.Branch + (GitHubRules.FormatAge(run.CreatedAt, DateTimeOffset.UtcNow) is { Length: > 0 } age ? " · " + age : ""), run.Url,
            ChecksMark(run.Status != "completed" ? "pending" : run.Conclusion == "success" ? "passing" : run.Conclusion is "skipped" or "neutral" ? "" : "failing"), []));
        break;
    }
    return CodeUi.Card(list, 10);
  }
  private static UIElement? ChecksMark(string checks) => checks switch
  {
    "passing" => Mark("", 0x2E, 0xA0, 0x43, "Checks passing"), "failing" => Mark("", 0xD1, 0x24, 0x2F, "Checks failing"),
    "pending" => Mark("", 0xBF, 0x87, 0x00, "Checks running"), _ => null
  };
  private static FontIcon Mark(string glyph, byte r, byte g, byte b, string tip) { var icon = CodeUi.Icon(glyph, 12); icon.Foreground = CodeUi.Brush(r, g, b); ToolTipService.SetToolTip(icon, tip); return icon; }
  private FrameworkElement ItemRow(string title, string meta, string url, UIElement? mark, IReadOnlyList<GitHubLabel> labels)
  {
    var words = CodeUi.Stack(1); words.Children.Add(CodeUi.Words(title, 13, wrap: false));
    var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 }; line.Children.Add(CodeUi.Words(meta, 11, true, wrap: false));
    foreach (var label in labels.Take(4)) line.Children.Add(LabelChip(label));
    words.Children.Add(line);
    var cells = mark is null ? CodeUi.Columns((words, CodeUi.Star)) : CodeUi.Columns((mark, CodeUi.Auto), (words, CodeUi.Star));
    var row = CodeUi.Row(cells, title, false);
    row.Click += async (_, _) => { row.IsChecked = false; if (GitHubRules.SafeWebUrl(url)) await GuardAsync(() => Host.OpenInBrowserAsync(url)); };
    var menu = new MenuFlyout();
    var inApp = new MenuFlyoutItem { Text = "Open in Terminal Deck’s browser" }; inApp.Click += async (_, _) => { if (GitHubRules.SafeWebUrl(url)) await GuardAsync(() => Host.OpenInBrowserAsync(url)); }; menu.Items.Add(inApp);
    var system = new MenuFlyoutItem { Text = "Open in System Browser" }; system.Click += async (_, _) => { if (GitHubRules.SafeWebUrl(url)) await Windows.System.Launcher.LaunchUriAsync(new Uri(url)); }; menu.Items.Add(system);
    var copy = new MenuFlyoutItem { Text = "Copy Link" }; copy.Click += (_, _) => { CodeUi.Copy(url); Host.Notice("Link copied."); }; menu.Items.Add(copy);
    row.ContextFlyout = menu;
    return row;
  }
  private static Border LabelChip(GitHubLabel label)
  {
    var hex = label.Color.TrimStart('#');
    byte Part(int at) => hex.Length == 6 && byte.TryParse(hex.AsSpan(at, 2), System.Globalization.NumberStyles.HexNumber, null, out var v) ? v : (byte)0x88;
    return new Border { Child = new TextBlock { Text = label.Name, FontSize = 10 }, Padding = new Thickness(6, 0, 6, 1), CornerRadius = new CornerRadius(8), Background = CodeUi.Brush(Part(0), Part(2), Part(4), 0x40), VerticalAlignment = VerticalAlignment.Center };
  }
  private FrameworkElement MyRepos()
  {
    var stack = CodeUi.Stack(6);
    var title = CodeUi.Words("Your repositories", 13); title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
    var filter = new TextBox { PlaceholderText = "Filter repositories", Text = repoQuery, MaxWidth = 280, HorizontalAlignment = HorizontalAlignment.Left };
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(filter, "Filter repositories");
    var rows = CodeUi.Stack(2);
    void Fill()
    {
      rows.Children.Clear();
      if (mineFailure is { } f) { rows.Children.Add(CodeUi.Words(GitHubRules.Explanation(f), 12, true)); return; }
      if (mine is null) { rows.Children.Add(CodeUi.Action("Show my repositories", async () => { await LoadMineAsync(); ShowDetail(); })); return; }
      var shown = GitHubRules.FilterRepos(mine, repoQuery);
      rows.Children.Add(CodeUi.Words(GitHubRules.RepoCountLine(mine.Count, GitHubClient.RepoLimit), 11, true));
      foreach (var repo in shown)
      {
        var meta = string.Join(" · ", new[] { repo.IsPrivate ? "Private" : "Public", repo.Fork ? "Fork" : null, repo.Archived ? "Archived" : null, repo.Language, repo.PushedAt is { } p ? GitHubRules.FormatAge(p, DateTimeOffset.UtcNow) : null }.Where(x => !string.IsNullOrEmpty(x)));
        rows.Children.Add(ItemRow(repo.NameWithOwner, meta + (repo.Description is { } d ? " — " + d : ""), repo.Url, null, []));
      }
    }
    filter.TextChanged += (_, _) => { repoQuery = filter.Text; Fill(); };
    Fill();
    stack.Children.Add(CodeUi.Columns((title, CodeUi.Star), (filter, CodeUi.Auto))); stack.Children.Add(rows);
    return CodeUi.Card(stack, 12);
  }
  private async Task LoadMineAsync()
  {
    try { mine = await github.ReposAsync(); mineFailure = null; }
    catch (GitHubException ex) { mineFailure = ex.Failure; }
  }
}
