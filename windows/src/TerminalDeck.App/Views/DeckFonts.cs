using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace TerminalDeck.App.Views;

// Code-built views read the fonts named once in Styles/DeckResources.xaml.
internal static class DeckFonts
{
  private static FontFamily Get(string key) => (FontFamily)Application.Current.Resources[key];
  public static FontFamily Text => Get("DeckTextFontFamily");
  public static FontFamily Mono => Get("DeckMonoFontFamily");
  public static FontFamily Icons => Get("DeckIconFontFamily");
  // An explicit TextBlock style replaces the app's implicit one, so it names the family too.
  public const string TextSetter = "<Setter Property=\"FontFamily\" Value=\"{ThemeResource DeckTextFontFamily}\"/>";
}
