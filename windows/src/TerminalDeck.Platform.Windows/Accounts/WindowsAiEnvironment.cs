using System.Collections;
using Microsoft.Win32;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Platform.Windows.Accounts;

public static class WindowsAiEnvironment
{
  public static Dictionary<string, string> Read()
  {
    var process = Environment.GetEnvironmentVariables().Cast<DictionaryEntry>()
      .Where(p => p.Key is string key && !key.StartsWith('='))
      .ToDictionary(p => (string)p.Key, p => (string)p.Value!, StringComparer.OrdinalIgnoreCase);
    Dictionary<string, string> RegistryValues(RegistryKey hive, string path)
    {
      using var key = hive.OpenSubKey(path);
      return key?.GetValueNames().Select(name => (name, value: key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames)))
        .Where(p => p.value is string).ToDictionary(p => p.name, p => (string)p.value!, StringComparer.OrdinalIgnoreCase) ?? new(StringComparer.OrdinalIgnoreCase);
    }
    // Installer folders belong to the Windows user, not an MSIX virtualized
    // AppData directory or a build launcher's overridden profile variables.
    process["USERPROFILE"] = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    using (var folders = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"))
    {
      process["APPDATA"] = folders?.GetValue("AppData", null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string ?? Path.Combine(process["USERPROFILE"], "AppData", "Roaming");
      process["LOCALAPPDATA"] = folders?.GetValue("Local AppData", null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string ?? Path.Combine(process["USERPROFILE"], "AppData", "Local");
    }
    return WindowsAiSearch.EnvironmentNow(process,
      RegistryValues(Registry.LocalMachine, @"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"), RegistryValues(Registry.CurrentUser, "Environment"));
  }
  public static AiInstallSearch Search(string tools, IReadOnlyDictionary<string, string> environment) => WindowsAiSearch.Create(environment, tools, path =>
  {
    try { return Directory.Exists(path) ? Directory.GetDirectories(path) : []; }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return []; }
  });
}
