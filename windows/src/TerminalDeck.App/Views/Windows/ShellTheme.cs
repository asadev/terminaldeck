using Microsoft.UI.Xaml;

namespace TerminalDeck.App.Shell;

internal static class ShellTheme
{
  internal static object Resource(FrameworkElement element, string key)
  {
    object? Find(ResourceDictionary dictionary)
    {
      var theme = new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast ? "HighContrast" : element.ActualTheme == ElementTheme.Dark ? "Default" : "Light";
      if (dictionary.ThemeDictionaries.TryGetValue(theme, out var values) && values is ResourceDictionary themed && themed.TryGetValue(key, out var value)) return value;
      // WinUI TryGetValue also searches merged dictionaries using the system theme.
      // Select each merged dictionary explicitly before allowing that fallback.
      foreach (var merged in dictionary.MergedDictionaries.Reverse()) { var found = Find(merged); if (found is not null) return found; }
      return dictionary.TryGetValue(key, out value) ? value : null;
    }
    return Find(Application.Current.Resources) ?? throw new InvalidOperationException("A shared appearance resource is missing: " + key);
  }
  internal static void SetResourceReference(this FrameworkElement element, DependencyProperty property, string key)
  {
    void Apply() => element.SetValue(property, Resource(element, key));
    element.Loaded += (_, _) => Apply(); element.ActualThemeChanged += (_, _) => Apply(); Apply();
  }
}
