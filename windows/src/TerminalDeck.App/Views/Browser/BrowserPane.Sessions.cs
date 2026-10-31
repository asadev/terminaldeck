using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TerminalDeck.App.Views;

public sealed record BrowserSessionChoice(string Id, string Title, string Machine = "This computer");

public sealed partial class BrowserPane
{
  public Func<IReadOnlyList<BrowserSessionChoice>> SessionChoices { get; set; } = () => [];
  public Action<string>? OpenBrowserSettings { get; set; }
  private Button SessionButton(BrowserTab tab)
  {
    var button = TextAction("Session", () => { }); var menu = new MenuFlyout(); button.Flyout = menu;
    menu.Opening += (_, _) =>
    {
      menu.Items.Clear(); var linked = Core.Get(tab.Id);
      foreach (var session in SessionChoices())
      {
        var item = new ToggleMenuFlyoutItem { Text = session.Title + " · " + session.Machine, IsChecked = linked.SessionId == session.Id };
        item.Click += async (_, _) => await GuardAsync(async () => { await Core.AttachAsync(tab.Id, session.Id); RefreshShellViews(); ShellChanged?.Invoke(); }, tab); menu.Items.Add(item);
      }
      if (linked.SessionId is not null) menu.Items.Add(MenuAction("Disconnect", tab, async () => { await Core.AttachAsync(tab.Id, null); RefreshShellViews(); ShellChanged?.Invoke(); }));
    };
    return button;
  }
}
