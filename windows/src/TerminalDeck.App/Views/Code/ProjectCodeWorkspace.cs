using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace TerminalDeck.App.Views.Code;

// The project has one Code destination. Its four sections retain their real
// underlying pages, scoped by the shell's project host, without extra windows.
public sealed class ProjectCodeWorkspace : Grid
{
  private readonly Func<string, CodePage> create;
  private readonly Dictionary<string, CodePage> pages = [];
  private readonly Dictionary<string, ToggleButton> buttons = [];
  private readonly ContentControl content = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
  public ProjectCodeWorkspace(Func<string, CodePage> create)
  {
    this.create = create;
    RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
    var choices = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
    foreach (var section in new[] { "Changes", "Pull requests", "Issues", "Actions" })
    {
      var button = new ToggleButton { Content = section, MinHeight = 30, Padding = new(12, 4, 12, 4) };
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, section + " in this project");
      button.Click += (_, _) => Select(section); buttons[section] = button; choices.Children.Add(button);
    }
    Children.Add(new ScrollViewer { Content = choices, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
    SetRow(content, 1); Children.Add(content); Select("Changes");
  }
  private void Select(string section)
  {
    if (!pages.TryGetValue(section, out var page)) pages[section] = page = create(section);
    content.Content = null;
    foreach (var (name, button) in buttons) button.IsChecked = name == section;
    content.Content = page;
  }
}
