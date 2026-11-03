using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Markup;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.App.Views.Chat;

internal static class ChatMarkdownView
{
  private static Style? codeStyle;
  private static Style CodeStyle => codeStyle ??= (Style)XamlReader.Load("""
    <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Border"><Setter Property="Background" Value="{ThemeResource ControlFillColorSecondaryBrush}"/></Style>
    """);
  public static FrameworkElement Render(string text, Action<string> copy, Action<string> error)
  {
    var body = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Stretch };
    foreach (var block in ChatMarkdown.Blocks(text))
    {
      if (block.Kind == "code")
      {
        var code = new StackPanel { Spacing = 4 };
        var action = new Button { Content = block.Language.Length > 0 ? "Copy " + block.Language + " code" : "Copy code", MinHeight = 28, FontSize = 11, HorizontalAlignment = HorizontalAlignment.Right };
        action.Click += (_, _) => copy(block.Text); code.Children.Add(action);
        code.Children.Add(new ScrollViewer
        {
          HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
          Content = new TextBlock { Text = block.Text, FontFamily = TerminalDeck.App.Views.DeckFonts.Mono, FontSize = 12, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.NoWrap }
        });
        body.Children.Add(new Border { Child = code, CornerRadius = new CornerRadius(8), Padding = new Thickness(12), Style = CodeStyle }); continue;
      }
      var view = new RichTextBlock { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, FontSize = block.Kind == "heading" ? Math.Max(14, 23 - block.Level * 2) : ChatAppearance.BodySize, FontWeight = ChatAppearance.BodyWeight };
      var paragraph = new Paragraph();
      if (block.Kind == "list") paragraph.Inlines.Add(new Run { Text = (block.Language.Length > 1 && char.IsDigit(block.Language[0]) ? block.Language : "•") + " " });
      if (block.Kind == "quote") { view.Opacity = 0.75; view.Margin = new Thickness(12, 0, 0, 0); }
      foreach (var span in ChatMarkdown.Spans(block.Text))
      {
        var run = new Run { Text = span.Text };
        if (span.Kind == "code") run.FontFamily = TerminalDeck.App.Views.DeckFonts.Mono;
        if (span.Kind == "strong" || block.Kind == "heading") run.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        if (span.Kind == "emphasis") run.FontStyle = Windows.UI.Text.FontStyle.Italic;
        if (span.Kind == "link" && span.Target is { } target && ChatMarkdown.CanOpenLink(target))
        {
          var link = new Hyperlink(); link.Inlines.Add(run);
          link.Click += async (_, _) =>
          {
            try { if (!await Windows.System.Launcher.LaunchUriAsync(new Uri(target))) error("This link could not be opened."); }
            catch (Exception ex) when (ex is ArgumentException or System.Runtime.InteropServices.COMException) { error("This link could not be opened."); }
          };
          paragraph.Inlines.Add(link);
        }
        else paragraph.Inlines.Add(run);
      }
      view.Blocks.Add(paragraph); body.Children.Add(view);
    }
    return body;
  }
}
