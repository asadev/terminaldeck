using System.Collections.Immutable;
using TerminalDeck.App.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.ViewModels.Tasks;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Tasks;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Tasks;

public sealed partial class TaskDetailPage : Grid
{
  private readonly TasksViewModel model;
  private readonly string taskId;
  private readonly ITasksNavigation navigation;
  private readonly Action? expand;
  private readonly Action<bool>? holdPresentation;
  private bool threadOpen { get => model.TaskThreadOpen; set => model.TaskThreadOpen = value; }
  private bool hideEmpty { get => model.HideEmptyFields; set => model.HideEmptyFields = value; }
  public TaskDetailPage(TasksViewModel model, string taskId, ITasksNavigation navigation, Action? expand = null, Action<bool>? holdPresentation = null)
  { this.holdPresentation = holdPresentation; this.expand = expand; this.model = model; this.taskId = taskId; this.navigation = navigation; Render(); }
  private DeckTask Task => model.Tasks.Get(taskId, includeTrash: true);
  private void Render()
  {
    var task = Task;
    var extras = TaskExtras.Of(task);
    var activityEvents = task.Activity.Where(a => a.Text != "Added a comment.").ToArray();
    RowDefinitions.Add(new() { Height = GridLength.Auto });
    RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    var header = new Grid { Padding = new Thickness(12, 6, 12, 6), ColumnSpacing = 8, MinHeight = 44, BorderThickness = new Thickness(0, 0, 0, 1) };
    header.SetResourceReference(Grid.BorderBrushProperty, "CardStrokeColorDefaultBrush");
    header.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var location = Stack(6); location.Orientation = Orientation.Horizontal;
    var siblings = model.Rows.Select(t => t.Id).ToList(); var at = siblings.IndexOf(taskId);
    var previous = TaskLayout.Icon("\uE70E", "Previous task", () => model.Select(siblings[at - 1])); previous.IsEnabled = at > 0;
    var next = TaskLayout.Icon("\uE70D", "Next task", () => model.Select(siblings[at + 1])); next.IsEnabled = at >= 0 && at < siblings.Count - 1;
    location.Children.Add(previous); location.Children.Add(next);
    location.Children.Add(new DeckIcon { Glyph = "\uE9D5", FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
    var boardName = TaskLayout.Cell(string.IsNullOrWhiteSpace(task.Board) ? "No board" : task.Board); boardName.VerticalAlignment = VerticalAlignment.Center; location.Children.Add(boardName); header.Children.Add(location);
    if (PersonalTask(task)) location.Children.Add(new DeckIcon { Glyph = "\uE72E", FontSize = 10, Opacity = 0.5, VerticalAlignment = VerticalAlignment.Center });
    var move = TaskLayout.Icon("\uE8DE", "Move task", () => { }); move.Flyout = BoardFlyout(); move.IsEnabled = task.DeletedAt is null; AutomationProperties.SetAutomationId(move, "tasks.move"); location.Children.Add(move);
    var topActions = Stack(8); topActions.Orientation = Orientation.Horizontal;
    var created = TaskLayout.Cell("Created " + task.CreatedAt.ToLocalTime().ToString("MMM d"), true); created.FontSize = 10; created.VerticalAlignment = VerticalAlignment.Center; topActions.Children.Add(created);
    var share = TaskLayout.Quiet("Share", () => { }); share.Flyout = ShareFlyout(); AutomationProperties.SetAutomationId(share, "tasks.share");
    var shareLabel = Stack(6); shareLabel.Orientation = Orientation.Horizontal; shareLabel.Children.Add(new DeckIcon { Glyph = "\uE716", FontSize = 14 }); shareLabel.Children.Add(TaskLayout.Cell("Share", true)); share.Content = shareLabel; topActions.Children.Add(share);
    var more = new MenuFlyout();
    void Action(string label, Func<System.Threading.Tasks.Task> action)
    {
      var item = new MenuFlyoutItem { Text = label }; item.Click += async (_, _) => await action(); more.Items.Add(item);
    }
    Action("Copy ID", () => model.RunAsync(() =>
    {
      var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(taskId); Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data);
      return System.Threading.Tasks.Task.CompletedTask;
    }, "Task ID copied."));
    if (task.DeletedAt is null)
    {
      Action("Duplicate", DuplicateAsync);
      Action("Edit task", EditAsync); Action("Assign / Start", AssignAsync);
      Action(task.Archived ? "Unarchive" : "Archive", () => model.RunAsync(() => { model.Tasks.Archive(taskId, !task.Archived, TaskActor.Owner); return System.Threading.Tasks.Task.CompletedTask; }, task.Archived ? "Task restored." : "Task archived."));
      Action("Move to Trash", DeleteAsync);
    }
    var menu = TaskLayout.Icon("\uE712", "More task actions", () => { }); menu.Flyout = more; topActions.Children.Add(menu);
    topActions.Children.Add(TaskLayout.Icon(extras.Starred ? "\uE735" : "\uE734", "Star task", async () => await DetailAsync("star")));
    topActions.Children.Add(TaskLayout.Icon("\uE740", "Expand or collapse task", () => expand?.Invoke()));
    topActions.Children.Add(TaskLayout.Icon("\uE711", "Close task", () => model.Select(null)));
    Grid.SetColumn(topActions, 1); header.Children.Add(topActions); Children.Add(header);
    var body = Stack(8); body.Margin = new Thickness(56, 20, 24, 24);
    var type = Choice("Task type", new[] { ("Task", "Task"), ("Milestone", "Milestone") }, task.Type); type.Header = null;
    type.HorizontalAlignment = HorizontalAlignment.Left; type.MinHeight = 26; type.Height = 26; type.CornerRadius = new CornerRadius(5); type.Padding = new Thickness(8, 0, 8, 0); type.FontSize = 12;
    type.SelectionChanged += async (_, _) => await SaveAsync(TaskService.Draft(Task) with { Type = Picked(type) });
    body.Children.Add(type);
    if (model.EditingTitle && task.DeletedAt is null)
    {
      var title = Field("Task name", model.TitleDraft, max: 240); title.IsEnabled = !model.Busy; title.Loaded += (_, _) => title.Focus(FocusState.Programmatic);
      title.BeforeTextChanging += (_, e) => model.TitleDraft = e.NewText; body.Children.Add(title);
      var actions = Stack(8); actions.Orientation = Orientation.Horizontal;
      actions.Children.Add(AsyncButton("Save name", async () => await model.RenameAsync(), true));
      actions.Children.Add(Button("Cancel", model.CancelRename)); body.Children.Add(actions);
    }
    else
    {
      var heading = Heading(task.Title, 26); AutomationProperties.SetAutomationId(heading, "tasks.detail.title");
      if (task.DeletedAt is null) body.Children.Add(Destination(heading, "Rename task", () => model.BeginRename(task))); else body.Children.Add(heading);
    }
    if (task.Archived) body.Children.Add(Words("This task is archived — it is out of the list.", 13, true));
    if (task.DeletedAt is not null)
    {
      body.Children.Add(AsyncButton("Restore from Trash", () => model.RunAsync(() => { model.Tasks.Restore(taskId, TaskActor.Owner); return System.Threading.Tasks.Task.CompletedTask; }, "Task restored."), true));
    }
    else
    {
      body.Children.Add(Properties(task));
    }
    var divider = new Grid { ColumnSpacing = 12 };
    divider.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    divider.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var dividerLine = new Border { Height = 1, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.25 };
    dividerLine.SetResourceReference(Border.BackgroundProperty, "TextFillColorSecondaryBrush"); divider.Children.Add(dividerLine);
    var collapse = TaskLayout.Quiet(hideEmpty ? "Show empty fields" : "Collapse empty fields", () => { hideEmpty = !hideEmpty; foreach (var row in emptyFields) row.Visibility = hideEmpty ? Visibility.Collapsed : Visibility.Visible; });
    collapse.Click += (_, _) => collapse.Content = hideEmpty ? "Show empty fields" : "Collapse empty fields";
    collapse.FontSize = 10; collapse.Opacity = 0.5; Grid.SetColumn(collapse, 1); divider.Children.Add(collapse); body.Children.Add(divider);
    var description = new TextBox { AcceptsReturn = true, Text = task.Details, PlaceholderText = "Add a description…",
      TextWrapping = TextWrapping.Wrap, FontSize = 13, BorderThickness = new Thickness(0), Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent), MinHeight = 40, MaxLength = 40000 };
    AutomationProperties.SetName(description, "Description");
    description.LostFocus += async (_, _) => { if (description.Text != Task.Details) await SaveAsync(TaskService.Draft(Task) with { Details = description.Text }); };
    // A live layout mirror gives the editor its content height without relying
    // on measuring a detached text element, which WinUI can report as zero.
    var descriptionSize = new TextBlock { Text = description.Text, FontSize = 13, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4), VerticalAlignment = VerticalAlignment.Top, Opacity = 0, IsHitTestVisible = false };
    AutomationProperties.SetAccessibilityView(descriptionSize, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
    description.Padding = new Thickness(4);
    descriptionSize.SizeChanged += (_, _) => description.Height = Math.Max(40, descriptionSize.ActualHeight + 8);
    description.TextChanged += (_, _) => descriptionSize.Text = description.Text.Length == 0 ? description.PlaceholderText : description.Text;
    var descriptionFrame = new Grid { MinHeight = 40 }; descriptionFrame.Children.Add(descriptionSize); descriptionFrame.Children.Add(description); body.Children.Add(descriptionFrame);
    body.Children.Add(DetailSections(task));
    foreach (var run in model.Tasks.Runs(taskId).Reverse())
    {
      var work = Stack(8); work.Children.Add(Heading("Agent session · " + RunWords(run.State), 18));
      if (run.Problem is not null) work.Children.Add(Words(run.Problem));
      if (run.SessionId is { } session) work.Children.Add(Button("Open session", () => navigation.OpenSession(session)));
      body.Children.Add(Card(work));
    }
    var threadPane = new Grid { Style = PageStyle(), BorderThickness = new Thickness(1, 0, 0, 0) };
    threadPane.SetResourceReference(Grid.BorderBrushProperty, "CardStrokeColorDefaultBrush");
    threadPane.RowDefinitions.Add(new() { Height = GridLength.Auto });
    threadPane.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    threadPane.RowDefinitions.Add(new() { Height = GridLength.Auto });
    var comments = Stack(12); comments.VerticalAlignment = VerticalAlignment.Bottom; comments.Margin = new Thickness(16);
    var composer = Stack(8); composer.Margin = new Thickness(12);
    var feed = Stack(12); var activityFeed = Stack(8);
    var tabs = Stack(0); tabs.Orientation = Orientation.Horizontal;
    var segments = new Border { Child = tabs, CornerRadius = new CornerRadius(5), Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Left };
    segments.SetResourceReference(Border.BackgroundProperty, "SubtleFillColorSecondaryBrush");
    var commentTab = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = $"Comments {task.Comments.Length}", IsChecked = model.ThreadPane == "Comments", MinHeight = 26, MinWidth = 100 };
    var activityTab = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = "Activity", IsChecked = model.ThreadPane == "Activity", MinHeight = 26, MinWidth = 100 };
    void SelectPane(string pane) { model.ThreadPane = pane; commentTab.IsChecked = pane == "Comments"; activityTab.IsChecked = pane == "Activity"; feed.Visibility = pane == "Comments" ? Visibility.Visible : Visibility.Collapsed; activityFeed.Visibility = pane == "Activity" ? Visibility.Visible : Visibility.Collapsed;
      foreach (var tab in new[] { commentTab, activityTab }) { tab.FontSize = 12; tab.BorderThickness = new Thickness(0); tab.CornerRadius = new CornerRadius(5); tab.SetResourceReference(Control.BackgroundProperty, tab.IsChecked == true ? "DeckSidebarSelectionBrush" : "DeckTransparentBrush"); tab.SetResourceReference(Control.ForegroundProperty, tab.IsChecked == true ? "DeckSidebarSelectionInkBrush" : "DeckInkBrush"); } }
    commentTab.Click += (_, _) => SelectPane("Comments"); activityTab.Click += (_, _) => SelectPane("Activity");
    tabs.Children.Add(commentTab); tabs.Children.Add(activityTab);
    var threadHeader = Stack(8); threadHeader.Margin = new Thickness(16, 8, 16, 0);
    var threadTools = Stack(2); threadTools.Orientation = Orientation.Horizontal;
    var threadTitle = TaskLayout.Cell("Task thread"); threadTitle.VerticalAlignment = VerticalAlignment.Center;
    var threadBar = new Grid { ColumnSpacing = 8, RowSpacing = 6 };
    threadBar.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); threadBar.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); threadBar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    threadBar.RowDefinitions.Add(new() { Height = GridLength.Auto }); threadBar.RowDefinitions.Add(new() { Height = GridLength.Auto });
    threadBar.Children.Add(threadTitle); Grid.SetColumn(segments, 1); threadBar.Children.Add(segments); Grid.SetColumn(threadTools, 2); threadBar.Children.Add(threadTools);
    threadHeader.Children.Add(threadBar);
    var threadHeaderFrame = new Border { Child = threadHeader, Padding = new Thickness(0, 0, 0, 8), BorderThickness = new Thickness(0, 0, 0, 1) };
    threadHeaderFrame.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush"); threadPane.Children.Add(threadHeaderFrame);
    threadPane.SizeChanged += (_, _) => { var narrow = threadPane.ActualWidth < 440; Grid.SetRow(segments, narrow ? 1 : 0); Grid.SetColumn(segments, narrow ? 0 : 1); Grid.SetColumnSpan(segments, narrow ? 3 : 1); };
    var threadSearch = new TextBox { PlaceholderText = "Search activity", Text = model.ThreadSearch, MinHeight = 28, Visibility = model.ThreadSearchOpen ? Visibility.Visible : Visibility.Collapsed };
    threadTools.Children.Add(TaskLayout.Icon("\uE721", "Search activity", () => { model.ThreadSearchOpen = !model.ThreadSearchOpen; threadSearch.Visibility = model.ThreadSearchOpen ? Visibility.Visible : Visibility.Collapsed; if (!model.ThreadSearchOpen) threadSearch.Text = ""; }));
    AutomationProperties.SetName(threadSearch, "Search task comments and activity"); threadHeader.Children.Add(threadSearch);
    foreach (var comment in task.Comments)
    {
      var card = CommentCard(comment); card.Tag = model.CommentText(comment.Text); feed.Children.Add(card);
    }
    foreach (var entry in activityEvents)
    {
      var row = ActivityLine(entry); row.Tag = entry.Text;
      var position = task.Comments.Count(c => c.At <= entry.At) + activityEvents.TakeWhile(a => a.Id != entry.Id).Count();
      feed.Children.Insert(Math.Min(position, feed.Children.Count), row);
    }
    var activityRows = activityEvents.Select(a => (a.By.Name, Text: a.Text, a.At, Kind: TaskActivityKinds.Of(a)))
      .Concat(task.Comments.Select(c => (c.Author.Name, Text: model.CommentText(c.Text), c.At, Kind: "comments"))).OrderBy(a => a.At);
    foreach (var entry in activityRows)
    {
      var line = ActivityLine(new TaskActivity("", entry.Text, new TaskActor("", entry.Name), entry.At));
      line.Tag = (entry.Text, entry.Kind); activityFeed.Children.Add(line);
    }
    var category = Choice("Activity filter", new[] { ("all", "All"), ("comments", "Comments only"), ("status", "Status"), ("assignees", "Assignees"), ("dates", "Dates"),
      ("priority", "Priority"), ("subtasks", "Subtasks"), ("checklists", "Checklists"), ("attachments", "Attachments"), ("relationships", "Relationships"), ("time", "Time tracking"), ("details", "Name, description, tags, type & moves") }, model.ActivityCategory);
    category.Visibility = Visibility.Collapsed; threadHeader.Children.Add(category);
    commentTab.Click += (_, _) => category.Visibility = Visibility.Collapsed;
    var follow = TaskLayout.Quiet("", async () => await DetailAsync("follow")); var followLabel = Stack(2); followLabel.Orientation = Orientation.Horizontal; followLabel.Children.Add(new DeckIcon { Glyph = "\uEA8F", FontSize = 12 }); followLabel.Children.Add(TaskLayout.Cell(extras.Following ? "1" : "0", true)); follow.Content = followLabel; AutomationProperties.SetName(follow, "Follow task"); threadTools.Children.Add(follow);
    threadTools.Children.Add(TaskLayout.Icon("\uE71C", "Filter activity", () => category.Visibility = category.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible));
    SelectPane(model.ThreadPane); comments.Children.Add(feed); comments.Children.Add(activityFeed);
    var thread = new ScrollViewer { Content = comments, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    thread.Loaded += (_, _) => DispatcherQueue.TryEnqueueHandled(() => thread.ChangeView(null, thread.ScrollableHeight, null, true));
    Grid.SetRow(thread, 1); threadPane.Children.Add(thread);
    var composerCard = TaskLayout.Surface(composer); composerCard.Padding = new Thickness(4); composerCard.Margin = new Thickness(12); composerCard.CornerRadius = new CornerRadius(22);
    composerCard.BorderThickness = new Thickness(1); composerCard.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
    composer.Margin = new Thickness(8); Grid.SetRow(composerCard, 2); threadPane.Children.Add(composerCard);
    void SearchThread()
    {
      model.ThreadSearch = threadSearch.Text;
      foreach (var panel in new[] { feed, activityFeed })
        foreach (var child in panel.Children.OfType<FrameworkElement>())
        {
          var text = child.Tag is ValueTuple<string, string> entry ? entry.Item1 : child.Tag as string ?? "";
          var kindMatches = child.Tag is not ValueTuple<string, string> tagged || model.ActivityCategory == "all" || tagged.Item2 == model.ActivityCategory;
          child.Visibility = kindMatches && text.Contains(threadSearch.Text, StringComparison.OrdinalIgnoreCase) ? Visibility.Visible : Visibility.Collapsed;
        }
    }
    category.SelectionChanged += (_, _) => { model.ActivityCategory = Picked(category); SearchThread(); };
    threadSearch.BeforeTextChanging += (_, e) => model.ThreadSearch = e.NewText;
    threadSearch.TextChanged += (_, _) => SearchThread(); SearchThread();
    if (task.DeletedAt is null)
    {
      if (model.ReplyTo is { } replying && task.Comments.FirstOrDefault(c => c.Id == replying) is { } parent)
        composer.Children.Add(TaskLayout.Quiet("Replying to " + parent.Author.Name + " · Cancel", () => { model.ReplyTo = null; model.PresentationChanged(); }));
      var draft = new TextBox { Text = model.CommentDraft, PlaceholderText = "Comment — You answers here. Type @ to ask another agent.", BorderThickness = new Thickness(0), Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 44, MaxHeight = 180, MaxLength = 40000 };
      AutomationProperties.SetName(draft, "Write a comment"); AutomationProperties.SetAutomationId(draft, "tasks.comment");
      draft.BeforeTextChanging += (_, e) => model.CommentDraft = e.NewText; composer.Children.Add(draft);
      var people = model.People();
      var suggestions = new ListView { MaxHeight = 160, Visibility = Visibility.Collapsed, SelectionMode = ListViewSelectionMode.Single, IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
      AutomationProperties.SetName(suggestions, "Mention an agent or session");
      void Suggest(bool keepSelection = false)
      {
        var selected = keepSelection && suggestions.SelectedItem is Button { Tag: TaskRecipient current } ? current.Id : null;
        var prefix = TaskMentionCompletion.Find(draft.Text, draft.SelectionStart);
        var matches = prefix is null ? [] : people.Where(p => p.Name.Contains(prefix.Query, StringComparison.OrdinalIgnoreCase)).Take(8).ToArray();
        suggestions.ItemsSource = matches.Select(person =>
        {
          var choice = TaskLayout.Quiet("", () => Insert(person)); choice.Content = TaskLayout.Cell(person.Name); choice.Tag = person; choice.MinHeight = 36;
          choice.HorizontalAlignment = HorizontalAlignment.Stretch; choice.HorizontalContentAlignment = HorizontalAlignment.Left;
          AutomationProperties.SetName(choice, "Mention " + person.Name); ToolTipService.SetToolTip(choice, person.Name); return choice;
        }).ToArray(); suggestions.Visibility = matches.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        suggestions.SelectedIndex = matches.Length == 0 ? -1 : selected is null ? 0 : Math.Max(0, Array.FindIndex(matches, p => p.Id == selected));
      }
      void Insert(TaskRecipient person)
      {
        if (TaskMentionCompletion.Find(draft.Text, draft.SelectionStart) is not { } prefix) return;
        var inserted = TaskMentionCompletion.Insert(draft.Text, prefix, person.Id);
        draft.Text = inserted.Text; draft.SelectionStart = inserted.Caret; suggestions.Visibility = Visibility.Collapsed; draft.Focus(FocusState.Programmatic);
      }
      draft.TextChanged += (_, _) => Suggest(); draft.SelectionChanged += (_, _) => Suggest();
      var enter = new ComposerEnter();
      draft.TextCompositionStarted += (_, _) => enter.CompositionStarted();
      draft.TextCompositionEnded += (_, _) => enter.CompositionEnded();
      draft.PreviewKeyDown += async (_, e) => // before the multi-line TextBox adds a new line
      {
        if (e.Key == Windows.System.VirtualKey.Escape && suggestions.Visibility == Visibility.Visible) { suggestions.Visibility = Visibility.Collapsed; e.Handled = true; return; }
        if (e.Key is not (Windows.System.VirtualKey.Up or Windows.System.VirtualKey.Down or Windows.System.VirtualKey.Enter)) return;
        Suggest(keepSelection: true);
        if (suggestions.Visibility != Visibility.Visible || suggestions.Items.Count == 0)
        {
          var shift = (Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0;
          switch (enter.Decide(e.Key == Windows.System.VirtualKey.Enter, shift, !model.Busy && !string.IsNullOrWhiteSpace(draft.Text)))
          {
            case ComposerEnterAction.Send: e.Handled = true; await model.CommentAsync(); break;
            case ComposerEnterAction.Swallow: e.Handled = true; break;
          }
          return;
        }
        e.Handled = true;
        if (e.Key == Windows.System.VirtualKey.Enter) { if (suggestions.SelectedItem is Button { Tag: TaskRecipient person }) Insert(person); }
        else suggestions.SelectedIndex = (suggestions.SelectedIndex + (e.Key == Windows.System.VirtualKey.Down ? 1 : suggestions.Items.Count - 1)) % suggestions.Items.Count;
      };
      composer.Children.Add(suggestions);
      var post = AsyncButton("↑", async () => { await model.CommentAsync(); }, true); post.IsEnabled = !model.Busy && !string.IsNullOrWhiteSpace(draft.Text);
      draft.TextChanged += (_, _) => post.IsEnabled = !model.Busy && !string.IsNullOrWhiteSpace(draft.Text);
      AutomationProperties.SetName(post, "Send comment"); post.CornerRadius = new CornerRadius(16); post.Width = 32; post.Height = 32; post.MinWidth = 32; post.MinHeight = 32; post.Padding = new Thickness(0);
      var composerActions = new Grid(); composerActions.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); composerActions.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      var attach = TaskLayout.Icon("\uE710", "Attach file", async () => await AttachAsync()); attach.HorizontalAlignment = HorizontalAlignment.Left; composerActions.Children.Add(attach);
      var sendActions = Stack(8); sendActions.Orientation = Orientation.Horizontal;
      sendActions.Children.Add(TaskLayout.Icon("\uE720", "Dictate with Windows voice typing", () => { if (!TerminalDeck.App.Shell.WindowsVoiceTyping.Start(draft)) { model.Notice("Click in the comment and press Win+H."); } }));
      sendActions.Children.Add(post); Grid.SetColumn(sendActions, 1); composerActions.Children.Add(sendActions); composer.Children.Add(composerActions);
      var pending = model.Tasks.Mentions(taskId).Where(m => !m.Delivered).ToArray();
      if (pending.Length > 0)
      {
        composer.Children.Add(Words($"{pending.Length} mention{(pending.Length == 1 ? "" : "s")} waiting. " + (pending[0].Problem ?? "Not delivered yet."), 13, true));
      }
    }
    if (hideEmpty) foreach (var row in emptyFields) row.Visibility = Visibility.Collapsed;
    threadPane.Visibility = threadOpen ? Visibility.Visible : Visibility.Collapsed;
    var content = new Grid();
    var breadcrumb = TaskLayout.Quiet("› " + (task.GoalId is { } goalId ? model.Tasks.Goals().FirstOrDefault(g => g.Id == goalId)?.Title ?? "Goal" : "Business decision") + " · " + (task.GoalId is null ? "Off" : "On"), async () => await ChooseGoalAsync());
    breadcrumb.HorizontalAlignment = HorizontalAlignment.Left; breadcrumb.FontSize = 12;
    RowDefinitions.Insert(1, new() { Height = GridLength.Auto }); Grid.SetRow(breadcrumb, 1); Children.Add(breadcrumb);
    content.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    content.ColumnDefinitions.Add(new() { Width = new GridLength(32) });
    content.ColumnDefinitions.Add(new() { Width = new GridLength(0.65, GridUnitType.Star) });
    var rail = Stack(8); rail.Margin = new Thickness(0, 20, 0, 0);
    var collapseGlyph = new TextBlock { FontSize = 20, Opacity = 0.6 };
    var railCollapse = TaskLayout.Icon("\uE970", "Collapse task thread", () => { }); railCollapse.Content = collapseGlyph; rail.Children.Add(railCollapse);
    var commentsRail = TaskLayout.Icon("\uE90A", "Comments", () => { }); commentsRail.CornerRadius = new CornerRadius(8); rail.Children.Add(commentsRail);
    AutomationProperties.SetAutomationId(commentsRail, "tasks.thread.comments"); AutomationProperties.SetAutomationId(railCollapse, "tasks.thread.collapse");
    void PresentThread(bool open)
    {
      threadOpen = open; threadPane.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
      content.ColumnDefinitions[2].Width = open ? new GridLength(Math.Clamp(content.ActualWidth * 0.39, 320, 560)) : new GridLength(0);
      collapseGlyph.Text = open ? "»" : "«";
      var label = open ? "Collapse task thread" : "Show task thread";
      AutomationProperties.SetName(railCollapse, label); ToolTipService.SetToolTip(railCollapse, label);
      if (open) commentsRail.SetResourceReference(Control.BackgroundProperty, "SubtleFillColorSecondaryBrush");
      else commentsRail.Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
    }
    railCollapse.Click += (_, _) => PresentThread(!threadOpen);
    // Like the Mac bubble, this reveals the current thread pane without resetting it.
    commentsRail.Click += (_, _) => PresentThread(true);
    PresentThread(threadOpen);
    rail.Children.Add(TaskLayout.Icon("\uE71B", "Relationships", async () => await RelateAsync()));
    Grid.SetColumn(rail, 1); content.Children.Add(rail);
    content.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    content.RowDefinitions.Add(new() { Height = GridLength.Auto });
    var mainScroll = PageScroll(body); content.Children.Add(mainScroll);
    Grid.SetColumn(threadPane, 2); content.Children.Add(threadPane);
    content.SizeChanged += (_, _) =>
    {
      content.ColumnDefinitions[2].Width = threadOpen ? new GridLength(Math.Clamp(content.ActualWidth * 0.39, 320, 560)) : new GridLength(0);
      body.Margin = content.ActualWidth >= 1150 ? new Thickness(56, 20, 0, 24) : new Thickness(24, 20, 0, 24);
    };
    if (model.Busy) body.Children.Add(new ProgressBar { IsIndeterminate = true });
    if (model.Message.Length > 0) body.Children.Add(new TerminalDeck.App.Views.Notices.CompactNotice { IsOpen = true, IsClosable = false, Severity = model.Failed ? InfoBarSeverity.Error : InfoBarSeverity.Informational, Message = model.Message });
    Grid.SetRow(content, 2); Children.Add(content);
  }
  private async System.Threading.Tasks.Task EditAsync()
  {
    var task = Task;
    var title = Field("Title", task.Title, max: 240); var details = Field("Description", task.Details, multiline: true, max: 40000);
    var project = Choice("Project", model.Projects.List().Select(p => (p.Id, p.Name)), task.ProjectId);
    var priority = Choice("Priority", new[] { ("", "None"), ("Low", "Low"), ("Medium", "Medium"), ("High", "High"), ("Critical", "Critical") }, task.Priority ?? "");
    var start = new TaskDateField("Start date", task.StartDate, task.StartTime); var due = new TaskDateField("Due date", task.DueDate, task.DueTime);
    var tags = Field("Tags, separated by commas", string.Join(", ", task.Labels), max: 4000); var board = Field("Board", task.Board ?? "", max: 120);
    var folder = Field("Project folder · full path", task.Folder);
    var goal = TaskGoalsPage.GoalPicker(model, task.ProjectId, task.GoalId);
    project.SelectionChanged += (_, _) => TaskGoalsPage.FillGoals(goal, model, Picked(project), null);
    project.SelectionChanged += (_, _) => folder.Text = model.Projects.Get(Picked(project)).HomeFolder ?? "";
    var body = Stack(); foreach (var field in new UIElement[] { title, details, project, folder, goal, priority, start, due, tags, board }) body.Children.Add(field);
    body.Children.Add(AsyncButton("Choose folder…", async () =>
    {
      var hwnd = Microsoft.UI.Win32Interop.GetWindowFromWindowId(XamlRoot.ContentIslandEnvironment.AppWindowId);
      if (await PickFolderAsync(hwnd) is { } selected) folder.Text = selected;
    }));
    var error = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error }; body.Children.Add(error);
    var dialog = Dialog(XamlRoot, "Edit task", body);
    dialog.PrimaryButtonClick += async (_, e) =>
    {
      var deferral = e.GetDeferral();
      try
      {
        e.Cancel = !await model.RunAsync(() =>
        {
          model.Tasks.Update(taskId, TaskService.Draft(task) with { Title = title.Text, Details = details.Text, ProjectId = Picked(project),
            Folder = TasksPage.Empty(folder.Text), GoalId = TasksPage.Empty(Picked(goal)), Priority = TasksPage.Empty(Picked(priority)),
            StartDate = start.Date, StartTime = start.Time, DueDate = due.Date, DueTime = due.Time, Board = TasksPage.Empty(board.Text),
            Labels = tags.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToImmutableArray() }, TaskActor.Owner, task.Revision);
          return System.Threading.Tasks.Task.CompletedTask;
        }, "Task saved.");
        error.Message = model.Message; error.IsOpen = e.Cancel;
      }
      finally { deferral.Complete(); }
    };
    await dialog.ShowAsync();
  }

  private async System.Threading.Tasks.Task AssignAsync()
  {
    var task = Task;
    var candidates = model.People().Where(p => !p.Id.StartsWith("session:", StringComparison.Ordinal));
    var person = Choice("Assign to", new[] { ("me", "You"), ("none", "Unassigned") }.Concat(candidates.Select(p => (p.Id, p.Name))), task.Assignee);
    var body = Stack(); body.Children.Add(person); var mode = model.Tasks.CanRun("chat") ? "chat" : "terminal";
    ComboBox? modes = null;
    if (model.Tasks.CanRun("chat") && model.Tasks.CanRun("terminal")) { modes = Choice("Open as", new[] { ("chat", "Chat"), ("terminal", "Terminal") }, "chat"); body.Children.Add(modes); }
    body.Children.Add(Words("Giving this task to an agent starts a session for the task. Its replies belong in these comments.", muted: true));
    if (await Dialog(XamlRoot, "Assign task", body, "Assign").ShowAsync() != ContentDialogResult.Primary) return;
    if (modes is not null) mode = Picked(modes);
    await model.RunAsync(async () => { await model.Tasks.AssignAsync(taskId, Picked(person), TaskActor.Owner, mode); }, "Task assigned.");
  }
  private async System.Threading.Tasks.Task DuplicateAsync()
  {
    var source = Task; var title = Field("Title", source.Title[..Math.Min(235, source.Title.Length)] + " copy", max: 240);
    var body = Stack(); body.Children.Add(title); body.Children.Add(Words("A new unassigned task keeps this task's description, dates, tags, board and goal.", 12, true));
    var error = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error }; body.Children.Add(error); var dialog = Dialog(XamlRoot, "Duplicate task", body, "Duplicate");
    dialog.PrimaryButtonClick += async (_, e) =>
    {
      var deferral = e.GetDeferral();
      try
      {
        DeckTask? copy = null; e.Cancel = !await model.RunAsync(() => { copy = model.Tasks.Duplicate(taskId, TaskActor.Owner, title.Text); return System.Threading.Tasks.Task.CompletedTask; }, "Task duplicated.");
        if (!e.Cancel && copy is not null) model.Select(copy.Id, keepFeedback: true); error.Message = model.Message; error.IsOpen = e.Cancel;
      }
      finally { deferral.Complete(); }
    };
    await dialog.ShowAsync();
  }
  private async System.Threading.Tasks.Task DeleteAsync()
  {
    if (!await ConfirmAsync(XamlRoot, "Move to Trash?", "You can restore the task and its comments from Trash.", "Move to Trash")) return;
    await model.RunAsync(() => { model.Tasks.Delete(taskId, TaskActor.Owner); model.Select(null); return System.Threading.Tasks.Task.CompletedTask; }, "Task moved to Trash.");
  }
  private static string RunWords(TaskRunState state) => state switch { TaskRunState.Starting => "Starting", TaskRunState.Working => "Working", TaskRunState.NeedsYou => "Needs you", TaskRunState.Uncertain => "Check the session", TaskRunState.Yielded => "Waiting; folder released", _ => "Ended" };
}
