using TerminalDeck.App.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Tasks;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Tasks;

public sealed partial class TaskDetailPage
{
  private Flyout DatesFlyout()
  {
    var body = Stack(12); body.Width = 320;
    var start = new TaskDateField("Start", Task.StartDate, Task.StartTime, "tasks.dates.start");
    var due = new TaskDateField("Due", Task.DueDate, Task.DueTime, "tasks.dates.due"); body.Children.Add(start); body.Children.Add(due);
    var error = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error };
    var flyout = RetainedFlyout(body);
    async System.Threading.Tasks.Task Save(bool clear)
    {
      var saved = await SaveAsync(TaskService.Draft(Task) with { StartDate = clear ? null : start.Date, StartTime = clear ? null : start.Time, DueDate = clear ? null : due.Date, DueTime = clear ? null : due.Time });
      if (saved) flyout.Hide(); else { error.Message = model.Message; error.IsOpen = true; }
    }
    var actions = Stack(8); actions.Orientation = Orientation.Horizontal;
    var save = AsyncButton("Save", async () => await Save(false), true); AutomationProperties.SetAutomationId(save, "tasks.dates.save"); actions.Children.Add(save);
    var clear = AsyncButton("Clear", async () => await Save(true)); AutomationProperties.SetAutomationId(clear, "tasks.dates.clear"); actions.Children.Add(clear);
    body.Children.Add(actions); body.Children.Add(error); return flyout;
  }

  private MenuFlyout PriorityFlyout()
  {
    var menu = new MenuFlyout();
    menu.Opened += (_, _) => holdPresentation?.Invoke(true); menu.Closed += (_, _) => holdPresentation?.Invoke(false);
    foreach (var value in new[] { "Critical", "High", "Medium", "Low", "" })
    {
      var item = new MenuFlyoutItem { Text = value.Length == 0 ? "Clear" : value };
      AutomationProperties.SetAutomationId(item, "tasks.priority." + (value.Length == 0 ? "clear" : value.ToLowerInvariant()));
      item.Click += async (_, _) => await SaveAsync(TaskService.Draft(Task) with { Priority = value.Length == 0 ? null : value }); menu.Items.Add(item);
    }
    return menu;
  }

  private FrameworkElement TagSummary(DeckTask task)
  {
    var row = new Grid { ColumnSpacing = 4 }; row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var chip = new Border { Child = TaskLayout.Cell(task.Labels[0]), Padding = new Thickness(6, 2, 6, 2), CornerRadius = new CornerRadius(5) };
    chip.SetResourceReference(Border.BackgroundProperty, "SubtleFillColorSecondaryBrush"); row.Children.Add(chip);
    if (task.Labels.Length > 1) { var more = TaskLayout.Cell("+" + (task.Labels.Length - 1), true); more.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(more, 1); row.Children.Add(more); }
    return row;
  }

  private Flyout TagsFlyout()
  {
    var body = Stack(8); body.Width = 280; body.Children.Add(Heading("Tags", 16));
    var search = new TextBox { PlaceholderText = "Search or create a tag…", MaxLength = 80 }; AutomationProperties.SetAutomationId(search, "tasks.tags.search"); AutomationProperties.SetName(search, "Search tags"); body.Children.Add(search);
    var rows = Stack(2); body.Children.Add(new ScrollViewer { Content = rows, MaxHeight = 260, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalContentAlignment = HorizontalAlignment.Stretch });
    var error = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error };
    var create = TaskLayout.Quiet("Create tag", () => { }); AutomationProperties.SetAutomationId(create, "tasks.tags.create"); body.Children.Add(create); body.Children.Add(error);
    var flyout = RetainedFlyout(body);
    async System.Threading.Tasks.Task Change(string label)
    {
      var current = Task; var labels = current.Labels.Contains(label) ? current.Labels.Remove(label) : current.Labels.Add(label);
      if (!await SaveAsync(TaskService.Draft(current) with { Labels = labels })) { error.Message = model.Message; error.IsOpen = true; } else error.IsOpen = false;
      Refresh();
    }
    void Refresh()
    {
      rows.Children.Clear(); var query = search.Text.Trim(); var selected = Task.Labels;
      var known = model.Tasks.List(new(Status: "all")).Concat(model.Tasks.List(new(Status: "all", Archived: true))).SelectMany(t => t.Labels)
        .Concat(selected).Distinct(StringComparer.Ordinal).OrderBy(t => t, StringComparer.CurrentCultureIgnoreCase).ToArray();
      foreach (var label in known.Where(t => t.Contains(query, StringComparison.CurrentCultureIgnoreCase)))
      {
        var pick = new CheckBox { Content = TaskLayout.Cell(label), IsChecked = selected.Contains(label), MinHeight = 30, HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(pick, "Tag " + label); pick.Click += async (_, _) => await Change(label); rows.Children.Add(pick);
      }
      if (rows.Children.Count == 0) rows.Children.Add(Words("No matching tags", 12, true));
      create.IsEnabled = query.Length > 0 && !known.Contains(query, StringComparer.Ordinal);
      create.Content = query.Length == 0 ? "Create tag" : "Create tag “" + query + "”";
    }
    create.Click += async (_, _) => { var name = search.Text.Trim(); if (name.Length > 0 && !Task.Labels.Contains(name)) await Change(name); };
    search.KeyDown += async (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter && create.IsEnabled) { e.Handled = true; await Change(search.Text.Trim()); } };
    search.TextChanged += (_, _) => Refresh(); flyout.Opened += (_, _) => Refresh(); Refresh(); return flyout;
  }
}
