using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Agents;

internal sealed class AgentPicturePicker : StackPanel
{
  public string Value { get; private set; }
  public AgentPicturePicker(string value = "person")
  {
    Value = value; Spacing = 8;
    var (picture, savedColour) = AgentPictures.Parse(value);
    var currentPicture = picture;
    var preview = new ContentControl();
    var chosen = Words("", 12, true);
    var options = ProjectIdentity.Colours.Select(c => (c, char.ToUpperInvariant(c[0]) + c[1..]));
    if (!ProjectIdentity.Colours.Contains(savedColour)) options = options.Append((savedColour, savedColour + " · saved colour"));
    var colour = Choice("Colour", options, savedColour);
    var mode = Choice("Picture", new[] { ("symbols", "Symbols"), ("emoji", "Emoji") }, picture.StartsWith("emoji:", StringComparison.Ordinal) ? "emoji" : "symbols");
    var search = new AutoSuggestBox { PlaceholderText = "Search symbols" };
    var symbols = Stack(4);
    var emoji = Field("One emoji", picture.StartsWith("emoji:", StringComparison.Ordinal) ? picture[6..] : "", max: 80);
    var error = new TerminalDeck.App.Views.Notices.CompactNotice { Severity = InfoBarSeverity.Error, IsClosable = false };
    var body = Stack(10); body.Width = 320;
    void Refresh()
    {
      Value = currentPicture + "@" + Picked(colour);
      preview.Content = AgentPicture(new SavedAgent("preview", "Preview", "codex", Icon: Value), 40);
      chosen.Text = currentPicture.StartsWith("emoji:", StringComparison.Ordinal) ? currentPicture[6..]
        : AgentPictures.Symbols.FirstOrDefault(s => s.Id == currentPicture)?.Name ?? currentPicture + " · saved picture";
    }
    void Fill()
    {
      symbols.Children.Clear();
      foreach (var symbol in AgentPictures.Symbols.Where(s => s.Name.Contains(search.Text, StringComparison.OrdinalIgnoreCase) || s.Id.Contains(search.Text, StringComparison.OrdinalIgnoreCase)))
        symbols.Children.Add(Button(symbol.Name, () => { currentPicture = symbol.Id; error.IsOpen = false; Refresh(); }));
      if (symbols.Children.Count == 0) symbols.Children.Add(Words("No symbols match.", 12, true));
    }
    var useEmoji = Button("Use emoji", () =>
    {
      try { currentPicture = AgentPictures.Parse(AgentPictures.Emoji(emoji.Text, Picked(colour))).Picture; error.IsOpen = false; Refresh(); }
      catch (ArgumentException ex) { error.Message = ex.Message; error.IsOpen = true; }
    });
    void Mode()
    {
      var symbolMode = Picked(mode) == "symbols";
      search.Visibility = symbols.Visibility = symbolMode ? Visibility.Visible : Visibility.Collapsed;
      emoji.Visibility = useEmoji.Visibility = symbolMode ? Visibility.Collapsed : Visibility.Visible;
    }
    foreach (var control in new UIElement[] { mode, colour, search, symbols, emoji, useEmoji, error }) body.Children.Add(control);
    body.Children.Add(Button("Use default picture", () => { currentPicture = "person"; colour.SelectedValue = "blue"; Refresh(); }));
    var flyout = new Flyout { Content = new ScrollViewer { Content = body, MaxHeight = 480, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
    var button = new Button { Content = "Choose picture…", Flyout = flyout }; MatchFlyoutTheme(this, flyout);
    Children.Add(Words("Picture", 13, true)); Children.Add(preview); Children.Add(chosen); Children.Add(button);
    search.TextChanged += (_, _) => Fill(); mode.SelectionChanged += (_, _) => Mode(); colour.SelectionChanged += (_, _) => Refresh();
    Fill(); Mode(); Refresh();
  }
}
