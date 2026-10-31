using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Tasks;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Tasks;

internal sealed class TaskDateField : StackPanel
{
  private readonly TextBox date;
  private readonly TextBox time;
  public string? Date => TasksPage.Empty(date.Text);
  public string? Time => TasksPage.Empty(time.Text);
  public TaskDateField(string label, string? day = null, string? clock = null, string? automationPrefix = null)
  {
    Spacing = 6; date = Field(label + " (YYYY-MM-DD)", day ?? "", max: 10); time = Field("Time (HH:mm) · optional", clock ?? "", max: 5);
    if (automationPrefix is not null)
    {
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(date, automationPrefix);
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(time, automationPrefix + ".time");
    }
    var row = new Grid { ColumnSpacing = 8 }; row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.Children.Add(date);
    var calendar = new CalendarView { SelectionMode = CalendarViewSelectionMode.Single, MinWidth = 288 };
    var addTime = new CheckBox { Content = "Add time", IsChecked = clock is not null };
    var picker = new TimePicker { ClockIdentifier = "24HourClock", Time = TaskDates.TryTime(clock, out var savedTime) ? savedTime.ToTimeSpan() : TimeSpan.FromHours(9), IsEnabled = clock is not null };
    var body = Stack(8); body.Children.Add(calendar);
    var actions = Stack(8); actions.Orientation = Orientation.Horizontal;
    actions.Children.Add(Button("Today", () => date.Text = DateTime.Today.ToString("yyyy-MM-dd")));
    actions.Children.Add(Button("Clear", () => { date.Text = ""; time.Text = ""; addTime.IsChecked = false; })); body.Children.Add(actions); body.Children.Add(addTime); body.Children.Add(picker);
    var flyout = new Flyout { Content = body };
    var choose = TaskLayout.Icon("\uE787", "Choose " + label.ToLowerInvariant(), () => { }); choose.Flyout = flyout; choose.VerticalAlignment = VerticalAlignment.Bottom; choose.Height = 32; choose.Width = 36;
    Grid.SetColumn(choose, 1); row.Children.Add(choose); Children.Add(row); Children.Add(time);
    time.Visibility = clock is null ? Visibility.Collapsed : Visibility.Visible;
    var reading = false;
    flyout.Opening += (_, _) =>
    {
      reading = true;
      try
      {
        calendar.SelectedDates.Clear();
        if (DateOnly.TryParseExact(date.Text, "yyyy-MM-dd", out var value))
        {
          var instant = new DateTimeOffset(value.ToDateTime(TimeOnly.MinValue));
          if (instant >= calendar.MinDate && instant <= calendar.MaxDate) { calendar.SelectedDates.Add(instant); calendar.SetDisplayDate(instant); }
        }
      }
      finally { reading = false; }
    };
    calendar.SelectedDatesChanged += (_, _) => { if (!reading && calendar.SelectedDates.Count > 0) date.Text = calendar.SelectedDates[0].ToString("yyyy-MM-dd"); };
    addTime.Checked += (_, _) => { time.Visibility = Visibility.Visible; picker.IsEnabled = true; if (time.Text.Length == 0) time.Text = picker.Time.ToString(@"hh\:mm", CultureInfo.InvariantCulture); };
    addTime.Unchecked += (_, _) => { time.Text = ""; time.Visibility = Visibility.Collapsed; picker.IsEnabled = false; };
    date.BeforeTextChanging += (_, e) => { if (e.NewText.Length == 0) { time.Text = ""; addTime.IsChecked = false; time.Visibility = Visibility.Collapsed; } };
    picker.TimeChanged += (_, e) => { if (addTime.IsChecked == true) time.Text = e.NewTime.ToString(@"hh\:mm", CultureInfo.InvariantCulture); };
  }
}
