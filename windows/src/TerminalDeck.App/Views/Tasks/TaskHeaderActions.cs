using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Tasks;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Tasks;

public sealed partial class TaskDetailPage
{
  private static string[] SharedPeople(DeckTask task) => (task.Assignee == "none" ? Array.Empty<string>() : [task.Assignee])
    .Concat(TaskExtras.Of(task).Participants).Distinct(StringComparer.Ordinal).ToArray();
  private static bool PersonalTask(DeckTask task) => SharedPeople(task) is [] or ["me"];

  private FrameworkElement TaskAvatar(string id)
  {
    if (id == "me") return new Border { Width = 20, Height = 20, CornerRadius = new CornerRadius(10),
      Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 49, 130, 246)),
      Child = new TextBlock { Text = "ME", FontSize = 8, Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.White), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
    if (model.People().FirstOrDefault(p => p.Id == id) is { } person) return (FrameworkElement)PersonPicture(person);
    return new DeckIcon { Glyph = "\uE77B", FontSize = 16, Width = 20, Height = 20, Opacity = 0.7 };
  }

  private Flyout RetainedFlyout(FrameworkElement body)
  {
    var flyout = new Flyout { Content = body };
    flyout.Opened += (_, _) => holdPresentation?.Invoke(true);
    flyout.Closed += (_, _) => holdPresentation?.Invoke(false);
    return flyout;
  }

  private Flyout BoardFlyout()
  {
    var body = Stack(4); body.Width = 220;
    body.Children.Add(Words("Move to", 11, true));
    var choices = Stack(2); body.Children.Add(choices);
    var name = new TextBox { PlaceholderText = "New board…", MaxLength = 40, MinHeight = 30 };
    AutomationProperties.SetName(name, "New board"); AutomationProperties.SetAutomationId(name, "tasks.move.new-board");
    var feedback = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error };
    var flyout = RetainedFlyout(body);
    async System.Threading.Tasks.Task Move(string? board)
    {
      if (await SaveAsync(TaskService.Draft(Task) with { Board = board })) flyout.Hide();
      else { feedback.Message = model.Message; feedback.IsOpen = true; }
    }
    foreach (var board in new[] { "" }.Concat(model.Tasks.List(new(Status: "all")).Concat(model.Tasks.List(new(Status: "all", Archived: true))).Select(t => t.Board ?? "")
      .Where(b => !string.IsNullOrWhiteSpace(b)).Distinct(StringComparer.Ordinal).OrderBy(b => b, StringComparer.CurrentCultureIgnoreCase)))
    {
      var label = board.Length == 0 ? "No board" : board;
      var pick = TaskLayout.Quiet(label + (string.Equals(Task.Board ?? "", board, StringComparison.Ordinal) ? "  ✓" : ""), async () => await Move(board.Length == 0 ? null : board));
      pick.HorizontalAlignment = HorizontalAlignment.Stretch; pick.HorizontalContentAlignment = HorizontalAlignment.Left;
      choices.Children.Add(pick);
    }
    body.Children.Add(name);
    var create = TaskLayout.Quiet("Create board", async () => { if (!string.IsNullOrWhiteSpace(name.Text)) await Move(name.Text.Trim()); });
    create.IsEnabled = false; name.TextChanged += (_, _) => create.IsEnabled = !string.IsNullOrWhiteSpace(name.Text);
    name.KeyDown += async (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter && !string.IsNullOrWhiteSpace(name.Text)) { e.Handled = true; await Move(name.Text.Trim()); } };
    body.Children.Add(create); body.Children.Add(feedback); return flyout;
  }

  private Flyout ShareFlyout()
  {
    var body = Stack(10); body.Width = 448;
    var heading = new Grid(); heading.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    heading.Children.Add(Heading("Share this task", 18)); body.Children.Add(heading);
    body.Children.Add(Words("Sharing task · " + Task.Title, 13, true));
    var search = new TextBox { PlaceholderText = "Search people…", MinHeight = 30 };
    AutomationProperties.SetName(search, "Search local agents"); AutomationProperties.SetAutomationId(search, "tasks.share.search"); body.Children.Add(search);
    var people = Stack(2); var peopleScroll = new ScrollViewer { Content = people, MaxHeight = 190, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalContentAlignment = HorizontalAlignment.Stretch }; body.Children.Add(peopleScroll);
    body.Children.Add(Words("No link to share: this task lives on this computer. It can be shared only with your agents here — never with anyone outside it.", 12, true));
    body.Children.Add(Words("Share with", 12, true)); var roster = Stack(4); body.Children.Add(roster);
    var feedback = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error }; body.Children.Add(feedback);
    var flyout = RetainedFlyout(body);
    var close = TaskLayout.Icon("\uE711", "Close share", flyout.Hide); Grid.SetColumn(close, 1); heading.Children.Add(close);
    TaskRecipient[] Directory() => new[] { new TaskRecipient("me", "You", "human", null) }.Concat(model.People()
      .Where(p => p.Id != "none" && !p.Id.StartsWith("session:", StringComparison.Ordinal) && !p.Id.StartsWith("lead:", StringComparison.Ordinal)))
      .DistinctBy(p => p.Id).ToArray();
    TaskRecipient Person(string id) => Directory().FirstOrDefault(p => p.Id == id) ?? new(id, id, "agent", null);
    async System.Threading.Tasks.Task Change(string action, string id)
    {
      if (!await DetailAsync(action, value: id)) { feedback.Message = model.Message; feedback.IsOpen = true; }
      else feedback.IsOpen = false;
      Refresh();
    }
    StackPanel Identity(TaskRecipient person)
    {
      var row = Stack(8); row.Orientation = Orientation.Horizontal; row.VerticalAlignment = VerticalAlignment.Center;
      row.Children.Add(TaskAvatar(person.Id));
      row.Children.Add(TaskLayout.Cell(person.Name)); return row;
    }
    void Refresh()
    {
      people.Children.Clear(); roster.Children.Clear(); var selected = SharedPeople(Task);
      foreach (var person in Directory().Where(p => p.Name.Contains(search.Text.Trim(), StringComparison.CurrentCultureIgnoreCase)))
      {
        var row = new Grid(); row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.Children.Add(Identity(person));
        if (selected.Contains(person.Id)) { var tick = TaskLayout.Cell("✓", true); Grid.SetColumn(tick, 1); row.Children.Add(tick); }
        var pick = TaskLayout.Quiet("", async () => await Change("share", person.Id)); pick.Content = row;
        pick.HorizontalAlignment = HorizontalAlignment.Stretch; pick.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        pick.IsEnabled = !selected.Contains(person.Id) && Task.DeletedAt is null && !model.Busy;
        AutomationProperties.SetName(pick, "Invite " + person.Name); people.Children.Add(pick);
      }
      if (people.Children.Count == 0) people.Children.Add(Words("No matching agents", 12, true));
      if (selected.Length == 0) roster.Children.Add(Words("Only you.", 12, true));
      for (var i = 0; i < selected.Length; i++)
      {
        var person = Person(selected[i]); var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.Children.Add(Identity(person));
        if (i == 0) { var main = Words("MAIN", 10, true); main.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(main, 1); row.Children.Add(main); }
        var remove = TaskLayout.Icon("\uE711", "Remove " + person.Name, async () => await Change("unshare", person.Id));
        remove.IsEnabled = Task.DeletedAt is null && !model.Busy; Grid.SetColumn(remove, 2); row.Children.Add(remove); roster.Children.Add(row);
      }
    }
    search.TextChanged += (_, _) => Refresh(); flyout.Opened += (_, _) => Refresh(); Refresh(); return flyout;
  }
}
