using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;
using TerminalDeck.App.Views;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.App.Views.WhatsApp;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.WhatsApp;

namespace TerminalDeck.App.Verification;

/// The WhatsApp screens' picture proof (developer copies only: TD_DEV=1 and TD_WHATSAPP_SCREENS_PROOF=<a folder inside
/// the --user-data-dir>). It draws the real WhatsApp parts against the engine's in-memory WhatsAppAgentsFixture (no key,
/// no network, never WhatsApp), writes one PNG per page ("wa-<page>-<theme>.png") and `whatsapp-screens-proof.json`,
/// then closes. Made-up names only.
/// Stand-ins (said in the JSON): a menu or a pop-up cannot be drawn off-screen, so the real menus' items are drawn as a
/// list beside their owner; the session page's heading line is built from the same ChatBar parts the pane bar uses, with
/// the real WhatsApp chip; the session row menu's other items are listed by name (the menu needs the running shell).
internal sealed class WhatsAppScreensProofWindow : Window
{
  private readonly Grid host = new();
  private readonly string output;
  private readonly List<string> written = [], failed = [];

  internal WhatsAppScreensProofWindow(AppDataRoot data, string output)
  {
    _ = data; this.output = output;
    Content = host; AppWindow.Resize(new(1300, 900)); AppWindow.Move(new(-20000, -20000));
    host.Loaded += async (_, _) =>
    {
      Directory.CreateDirectory(output);
      try { await RunAsync(); }
      catch (Exception error) when (error is not OutOfMemoryException) { failed.Add(error.ToString()); }
      finally
      {
        await File.WriteAllTextAsync(Path.Combine(output, "whatsapp-screens-proof.json"), JsonSerializer.Serialize(new
        {
          at = DateTimeOffset.UtcNow, written, failed,
          standIns = new[]
          {
            "menus and the receiver pop-up: the real items, in order, drawn as a list beside their owner (a menu cannot be drawn off-screen)",
            "session page heading: the pane bar's ChatBar parts (title, project chip, account chip) with the real WhatsAppChip",
            "session row menu: the other items listed by name (the real menu needs the running shell); the WhatsApp submenu's items are the real ones",
            "the info button's popover: its real content in a card"
          }
        }, new JsonSerializerOptions { WriteIndented = true }));
        Close();
      }
    };
  }

  private async Task Shot(string name, Func<FrameworkElement> make, double width, double height, bool dark = false, string background = "DeckCanvasBrush", Func<FrameworkElement, Task>? ready = null)
  {
    foreach (var theme in dark ? new[] { ElementTheme.Light, ElementTheme.Dark } : [ElementTheme.Light])
    {
      try
      {
        host.Children.Clear(); host.RequestedTheme = theme; host.Width = width; host.Height = height;
        var page = make();
        host.Children.Add(page);
        await Task.Delay(500); host.UpdateLayout();
        if (ready is not null) { await ready(page); await Task.Delay(500); host.UpdateLayout(); }
        host.Background = (Brush)ShellTheme.Resource(host, background); host.UpdateLayout();
        var themeWord = theme == ElementTheme.Dark ? "dark" : "light";
        await W10Proof.CaptureAsync(host, output, "wa-" + name, themeWord, "Made-up local data; no key, no network", _ => { });
        written.Add("wa-" + name + "-" + themeWord + ".png");
      }
      catch (Exception error) when (error is not OutOfMemoryException) { failed.Add(name + " " + theme + ": " + error.Message); }
    }
  }

  private async Task Page(string name, Func<Task> draw)
  {
    try { await draw(); }
    catch (Exception error) when (error is not OutOfMemoryException) { failed.Add(name + ": " + error); }
  }

  // ---- made-up WhatsApp agents and places ----

  private static readonly WhatsAppReceiver LoginSession = WhatsAppReceiver.Session("s-login", "Fix the login page");

  private static WhatsAppAgentProfile[] Seven() =>
  [
    new("wa-1", "Office", WhatsAppAgentState.Connected, WhatsAppReceiver.Hoot, "This PC", AnsweredHere: true),
    new("wa-2", "Website lead", WhatsAppAgentState.Connected, WhatsAppReceiver.Agent("proof-lead", "Lead"), "This PC", AnsweredHere: true),
    new("wa-3", "Phone", WhatsAppAgentState.Waiting, LoginSession, "This PC", AnsweredHere: true),
    new("wa-4", "Old number", WhatsAppAgentState.Refused, WhatsAppReceiver.Nowhere),
    new("wa-5", "Weekend", WhatsAppAgentState.Connected, WhatsAppReceiver.Agent("proof-review", "Reviewer"), "This PC", AnsweredHere: true, Sending: false),
    new("wa-6", "Travel", WhatsAppAgentState.Connected, WhatsAppReceiver.Nowhere),
    new("wa-7", "Second phone", WhatsAppAgentState.Connected, WhatsAppReceiver.Hoot, "Studio Mac", AnsweredHere: false),
  ];

  private static WhatsAppReceiverChoices Choices() => WhatsAppReceiverChoices.From(
    [("proof-lead", "Lead", "Website"), ("proof-review", "Reviewer", "Website"), ("proof-store", "Store writer", "Mobile app")],
    [("s-login", "Fix the login page"), ("s-notes", "Write the release notes"), ("s-site", "Build the website")]);

  private static async Task<WhatsAppAgentsStore> Store(IEnumerable<WhatsAppAgentProfile> agents)
  {
    var store = new WhatsAppAgentsStore();
    await store.ConnectAsync(new WhatsAppAgentsFixture(agents));
    return store;
  }

  private static FrameworkElement OnSettings(FrameworkElement group)
  {
    var column = new StackPanel { Width = 600, Margin = new Thickness(24), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
    column.Children.Add(group);
    return column;
  }

  private async Task RunAsync()
  {
    var seven = await Store(Seven());
    await Page("settings-seven", () => Shot("settings-seven", () => OnSettings(new WhatsAppSettingsGroup(seven, Choices)), 650, 480, dark: true, background: "DeckRailBrush"));

    var two = await Store(Seven().Where(a => a.Id is "wa-1" or "wa-3"));
    await Page("settings-adding", () => Shot("settings-adding", () => OnSettings(new WhatsAppSettingsGroup(two, Choices, startsAdding: true)), 650, 260, dark: true, background: "DeckRailBrush"));

    await Page("settings-refused-key", async () =>
    {
      var refusing = await Store(Seven().Where(a => a.Id is "wa-1" or "wa-3"));
      await Shot("settings-refused-key", () => OnSettings(new WhatsAppSettingsGroup(refusing, Choices, startsAdding: true)), 650, 290, background: "DeckRailBrush",
        ready: page => WorkspaceVisuals.Tree(page).OfType<WhatsAppSettingsGroup>().First().ProofAddAsync("refused-test-key"));
    });

    await Page("info", () => Shot("info", () =>
    {
      var card = new Border { Child = WhatsAppSettingsGroup.InfoContent(), Padding = new Thickness(14), CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Margin = new Thickness(24), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
      card.SetResourceReference(Border.BackgroundProperty, "DeckCardBrush"); card.SetResourceReference(Border.BorderBrushProperty, "DeckDividerBrush");
      return card;
    }, 380, 220, dark: true, background: "DeckRailBrush"));

    await Page("row-menu", () => Shot("row-menu", () =>
    {
      var group = new WhatsAppSettingsGroup(seven, Choices);
      var paused = seven.Agents.First(a => a.Id == "wa-5");
      return Beside(OnSettings(group), List(MenuLines(group.RowMenu(paused))), top: 250);
    }, 900, 480, background: "DeckRailBrush"));

    await Page("receiver-list", () => Shot("receiver-list", () =>
    {
      var lead = seven.Agents.First(a => a.Id == "wa-2");
      var lines = Choices().Lines(lead.Receiver).Select(l => (l.Kind == WhatsAppPopUpLineKind.Separator ? "-" : l.Text, l.Checked, l.Kind == WhatsAppPopUpLineKind.Header));
      return Beside(OnSettings(new WhatsAppSettingsGroup(seven, Choices)), List(lines), top: 110);
    }, 900, 520, background: "DeckRailBrush"));

    await Page("session-row-menu", () => Shot("session-row-menu", () =>
    {
      var sub = WhatsAppMenus.Submenu(LoginSession, seven);
      var row = new[] { "Pin", "Open in new window", "Account…", "Split view  ›", "Archive in sidebar", "Rename…", "Attach browser  ›", WhatsAppWords.SubmenuTitle + "  ›", "Stop", "-", "Delete" }
        .Select(t => (t, false, false));
      var menus = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(250, 40, 0, 0) };
      menus.Children.Add(List(row));
      var subList = List(MenuLines(sub.Items)); subList.Margin = new Thickness(0, 7 * 31, 0, 0);
      menus.Children.Add(subList);
      var grid = new Grid(); grid.Children.Add(SidePanel()); grid.Children.Add(menus);
      return grid;
    }, 760, 520, dark: true));

    await Page("session-chip-on", async () =>
    {
      var on = await Store(Seven());
      await Shot("session-chip-on", () => Heading(on, LoginSession), 760, 110, dark: true);
    });
    await Page("session-chip-off", async () =>
    {
      var off = await Store(Seven());
      await off.SetSendingAsync(false, "wa-3");
      await Shot("session-chip-off", () => Heading(off, LoginSession), 760, 110, dark: true);
    });
    await Page("session-no-chip", () => Shot("session-no-chip", () => Heading(seven, WhatsAppReceiver.Session("s-notes", "Write the release notes")), 760, 110));
  }

  // ---- the stand-ins ----

  /// The session pane's heading: title, then project · account · (WhatsApp chip and switch, only while attached).
  private static FrameworkElement Heading(WhatsAppAgentsStore store, WhatsAppReceiver session)
  {
    var bar = ChatBar.Frame(false);
    var identity = ChatBar.Identity();
    identity.Children.Add(ChatBar.Title(session.Name));
    var line = ChatBar.Line();
    line.Children.Add(ChatBar.ProjectChip("Website"));
    line.Children.Add(ChatBar.Dot());
    line.Children.Add(ChatBar.AccountChip("Sam · Claude"));
    line.Children.Add(new WhatsAppChip(session, store));
    identity.Children.Add(line);
    bar.Children.Add(identity);
    var frame = new Border { Child = bar, BorderThickness = new Thickness(0, 0, 0, 1), VerticalAlignment = VerticalAlignment.Top };
    frame.SetResourceReference(Border.BorderBrushProperty, "DeckDividerBrush");
    return frame;
  }

  /// The side panel's sessions with the real row builder (icon and name only); the row right-clicked is selected.
  private static FrameworkElement SidePanel()
  {
    var panel = new StackPanel { Spacing = 2, Padding = new(12, 8, 12, 8), Width = 240, HorizontalAlignment = HorizontalAlignment.Left };
    panel.SetResourceReference(Panel.BackgroundProperty, "DeckRailBrush");
    var caption = new TextBlock { Text = "Sessions", Margin = new(8, 10, 0, 4), FontSize = 12 };
    caption.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    panel.Children.Add(caption);
    foreach (var (name, chat, selected) in new[] { ("Fix the login page", true, true), ("Write the release notes", true, false), ("Build the website", false, false) })
    {
      var button = new Button { Content = ShellWindow.SidebarSimpleRow(SidebarRowLook.Glyph(chat), name, false, selected), Height = 32, Padding = new(8, 0, 8, 0),
        HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Style = (Style)Application.Current.Resources["DeckSidebarActionStyle"] };
      if (selected) button.SetResourceReference(Control.BackgroundProperty, "DeckSidebarSelectionBrush");
      panel.Children.Add(button);
    }
    return panel;
  }

  private static IEnumerable<(string Text, bool Checked, bool Header)> MenuLines(IEnumerable<MenuFlyoutItemBase> items)
  {
    foreach (var item in items)
      yield return item switch
      {
        MenuFlyoutSeparator => ("-", false, false),
        ToggleMenuFlyoutItem toggle => (toggle.Text, toggle.IsChecked, false),
        MenuFlyoutSubItem sub => (sub.Text + "  ›", false, false),
        MenuFlyoutItem plain => (plain.Text, false, !plain.IsEnabled),
        _ => ("?", false, false)
      };
  }

  private static IEnumerable<(string Text, bool Checked, bool Header)> MenuLines(MenuFlyout menu) => MenuLines(menu.Items);

  /// A menu's lines in a card: a check mark column, greyed headers and disabled items, thin separators.
  private static Border List(IEnumerable<(string Text, bool Checked, bool Header)> lines)
  {
    var items = new StackPanel { Padding = new(4) };
    foreach (var (text, check, header) in lines)
    {
      if (text == "-") { var rule = new Border { Height = 1, Margin = new(8, 4, 8, 4) }; rule.SetResourceReference(Border.BackgroundProperty, "DeckDividerBrush"); items.Children.Add(rule); continue; }
      var row = new Grid { ColumnSpacing = 6, Padding = new(8, 6, 24, 6) };
      row.ColumnDefinitions.Add(new() { Width = new GridLength(16) }); row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
      if (check) row.Children.Add(new DeckIcon { Glyph = "check", FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
      var words = new TextBlock { Text = text, FontSize = 13 };
      if (header) words.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
      Grid.SetColumn(words, 1); row.Children.Add(words);
      items.Children.Add(row);
    }
    var card = new Border { Child = items, CornerRadius = new(8), BorderThickness = new(1), MinWidth = 220, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
    card.SetResourceReference(Border.BackgroundProperty, "DeckCardBrush"); card.SetResourceReference(Border.BorderBrushProperty, "DeckDividerBrush");
    return card;
  }

  private static FrameworkElement Beside(FrameworkElement owner, Border list, double top)
  {
    var grid = new Grid();
    grid.Children.Add(owner);
    list.HorizontalAlignment = HorizontalAlignment.Left; list.Margin = new Thickness(640, top, 0, 0);
    grid.Children.Add(list);
    return grid;
  }
}
