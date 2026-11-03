using Microsoft.Win32;

namespace TerminalDeck.Platform.Windows;

public static class TerminalFontCatalog
{
  private static readonly string[] Candidates = ["Cascadia Mono", "Cascadia Code", "Consolas", "Courier New", "JetBrains Mono", "Fira Code", "Hack", "Source Code Pro", "IBM Plex Mono", "Iosevka", "Monaspace Neon", "Roboto Mono", "Ubuntu Mono", "DejaVu Sans Mono", "Menlo", "Monaco", "SF Mono"];
  public static string[] Installed()
  {
    var registered = new List<string>();
    foreach (var hive in new[] { Registry.LocalMachine, Registry.CurrentUser })
    {
      using var key = hive.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"); if (key is not null) registered.AddRange(key.GetValueNames());
    }
    return Candidates.Where(candidate => registered.Any(name => name.StartsWith(candidate + " ", StringComparison.OrdinalIgnoreCase) || name.Equals(candidate, StringComparison.OrdinalIgnoreCase))).ToArray();
  }
}
