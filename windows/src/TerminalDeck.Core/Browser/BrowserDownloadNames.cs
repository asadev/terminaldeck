namespace TerminalDeck.Core.Browser;

public static class BrowserDownloadNames
{
  public static string FileName(string suggested)
  {
    var name = suggested.Replace('\\', '/').Split('/').Last().Trim().TrimEnd('.', ' ');
    if (name.Length == 0 || name.Any(c => char.IsControl(c) || "<>:\"/\\|?*".Contains(c))) return "download";
    var stem = name.Split('.')[0].ToUpperInvariant();
    if (stem is "CON" or "PRN" or "AUX" or "NUL" || stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) && stem[3] is >= '1' and <= '9') name = "download-" + name;
    return name.Length > 180 ? name[..180].TrimEnd('.', ' ') : name;
  }
}
