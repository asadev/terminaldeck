using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using System.Runtime.InteropServices;

namespace TerminalDeck.App.Views.Settings;

public sealed partial class SettingsPanel
{
  private FrameworkElement AboutDetailsPage()
  {
    var column = Column();
    var version = Services.WindowsUpdateStatus.Version();
    column.Children.Add(GroupRows([
      SettingRow(TerminalDeck.Core.Brand.Name, "", StateText(version)),
      SettingRow("Licence", "The source is available under the MIT licence. Open the licence for its terms and copyright notice.", AboutLink("MIT", "https://github.com/asadev/terminaldeck/blob/main/LICENSE", "MIT licence")),
      SettingRow("Build", "Version " + version + " · " + RuntimeInformation.ProcessArchitecture + " · .NET " + Environment.Version + ". The version comes from the installed Windows package.", StateText("Windows · " + RuntimeInformation.ProcessArchitecture)),
      AboutDestination("Source", "https://github.com/asadev/terminaldeck"),
      AboutDestination("Website", "https://terminaldeck.dev"),
      AboutDestination("Releases", "https://github.com/asadev/terminaldeck/releases?q=windows-v&expanded=true")
    ]));

    column.Children.Add(new TextBlock { Text = "Help topics", FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
    var searchHelp = new TextBox { PlaceholderText = "Search help", Margin = new Thickness(0, 0, 0, 8) };
    AutomationProperties.SetName(searchHelp, "Search help topics");
    column.Children.Add(searchHelp);
    var topics = new StackPanel { Spacing = 8 };
    (string Title, string Text)[] help = [
      ("Getting started", "Open New session, choose an AI and account, then choose Chat or Terminal. Pick a project or folder from the header. Send your first message to create the session. Opening the page alone does not start anything."),
      ("Projects and folders", "The project menu chooses where a new session runs. Choose folder starts in a folder without adding a project. No project uses an independent folder. Open Projects from More to manage your projects."),
      ("Chat and Terminal", "Chat shows a conversation with the selected coding AI. Terminal runs the AI's own command-line interface. Select an open session in the sidebar to return to it. Closing its tab keeps the session; use Stop when you want it to finish."),
      ("Accounts and sign-in", "Open Settings > Coding AIs to add, name or sign in to an AI account. The account name in a session's header opens its account choices. A switch may need confirmation or wait for the current turn to finish; check the result before sending another message."),
      ("Permission modes", "The pill below a new message chooses what the AI may do. Plans only reads and plans. Asks before changes asks for approval. Other modes permit some or all actions without asking. Each AI offers only the modes it supports; check the pill before sending."),
      ("Finding pages and shortcuts", "More lists pages you can open or pin. Ctrl+K opens the Command Palette. Ctrl+/ opens the shortcut list. In Settings, Ctrl+F searches and the Back and Forward buttons return to pages you visited."),
      ("Updating Windows", "Open Settings > General to check for updates. Download an available version, then install it when it is ready. Your sessions and settings are kept. If an older updater cannot install, get the Windows package from the website and install it over the existing copy."),
      ("When something fails", "Read the error next to the action and keep any unsent message. Check the chosen AI account in Settings > Coding AIs. For a problem report, include your Windows package version, the action you tried and the visible error; leave out passwords and login files. Settings > Advanced has diagnostic controls.")
    ];
    var entries = new List<(string Search, Expander View)>();
    foreach (var topic in help)
    {
      var view = new Expander
      {
        Header = topic.Title, HorizontalAlignment = HorizontalAlignment.Stretch,
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
        Content = new TextBlock { Text = topic.Text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }
      };
      AutomationProperties.SetName(view, topic.Title);
      entries.Add((topic.Title + " " + topic.Text, view));
      topics.Children.Add(view);
    }
    column.Children.Add(topics);
    var empty = StateText("No help topics match this search.");
    empty.Visibility = Visibility.Collapsed; column.Children.Add(empty);
    searchHelp.TextChanged += (_, _) =>
    {
      var query = searchHelp.Text.Trim();
      var found = 0;
      foreach (var entry in entries)
      {
        var matches = query.Length == 0 || entry.Search.Contains(query, StringComparison.CurrentCultureIgnoreCase);
        entry.View.Visibility = matches ? Visibility.Visible : Visibility.Collapsed;
        if (matches) found++;
      }
      empty.Visibility = found == 0 ? Visibility.Visible : Visibility.Collapsed;
    };
    return Scroll(column);
  }

  private FrameworkElement AboutDestination(string title, string url) => SettingRow(title, "", AboutLink("Open", url, title));

  private Button AboutLink(string text, string url, string? title = null)
  {
    var button = new Button { Content = text, MinWidth = 72 };
    AutomationProperties.SetName(button, "Open " + (title ?? text));
    ToolTipService.SetToolTip(button, url);
    button.Click += async (_, _) =>
    {
      try
      {
        if (!await Windows.System.Launcher.LaunchUriAsync(new Uri(url))) throw new InvalidOperationException();
      }
      catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException)
      {
        saveStatus.Severity = InfoBarSeverity.Error; saveStatus.Text = "Windows could not open that page. Try again."; saveStatus.IsOpen = true;
      }
    };
    return button;
  }
}
