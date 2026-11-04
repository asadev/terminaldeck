using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.App.Views;

// A terminal tab shows the icon of the program it runs (Windows PowerShell,
// PowerShell 7, Command Prompt), as the taskbar and Windows Terminal do. Each
// icon is read from the program file once and shared.
internal static class ShellIcons
{
  private static readonly Dictionary<string, BitmapImage?> icons = [];
  private static string? Program(string shell)
  {
    var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
    return shell switch
    {
      TerminalShells.CommandPrompt => Path.Combine(system, "cmd.exe"),
      TerminalShells.WindowsPowerShell => Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe"),
      TerminalShells.PowerShell7 => TerminalDeck.Platform.Windows.WindowsProviderLaunchPlanner.FindPowerShell7(TerminalDeck.Platform.Windows.Accounts.WindowsAiEnvironment.Read()),
      _ => null
    };
  }
  // Returns at once; the picture appears when the icon has loaded. Null for a
  // session that does not record its shell (older or remote terminals), so the
  // caller keeps the generic terminal glyph.
  public static BitmapImage? For(string? shell)
  {
    if (shell is null) return null;
    if (icons.TryGetValue(shell, out var known)) return known;
    if (Program(shell) is not { } path || !File.Exists(path)) return icons[shell] = null;
    var image = new BitmapImage(); icons[shell] = image; _ = LoadAsync(shell, path, image);
    return image;
  }
  private static async Task LoadAsync(string shell, string path, BitmapImage image)
  {
    try
    {
      var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
      using var thumbnail = await file.GetThumbnailAsync(Windows.Storage.FileProperties.ThumbnailMode.SingleItem, 32, Windows.Storage.FileProperties.ThumbnailOptions.UseCurrentScale);
      await image.SetSourceAsync(thumbnail);
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or System.Runtime.InteropServices.COMException) { icons[shell] = null; }
  }
}
