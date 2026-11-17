namespace TerminalDeck.App.Services;

internal static class WindowsPackageData
{
  internal static string? LocalCache()
  {
    try { return Windows.Storage.ApplicationData.Current.LocalCacheFolder.Path; }
    catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException) { return null; }
  }
}
