namespace TerminalDeck.Core.Tests;

// The chat fixtures are small Python 3 programs. Mac and Linux run /usr/bin/python3 with a bare PATH;
// Windows runs the python.exe found on PATH (not the Microsoft Store stub), with SYSTEMROOT, which Python needs there.
internal static class TestPython
{
  private static readonly Lazy<string> executable = new(Find);
  public static string Executable => executable.Value;

  public static Dictionary<string, string> Environment(params (string Name, string Value)[] extra)
  {
    var environment = new Dictionary<string, string>();
    if (OperatingSystem.IsWindows())
    {
      environment["PATH"] = Path.GetDirectoryName(Executable)!;
      environment["SYSTEMROOT"] = System.Environment.GetFolderPath(System.Environment.SpecialFolder.Windows);
    }
    else environment["PATH"] = "/usr/bin:/bin";
    foreach (var (name, value) in extra) environment[name] = value;
    return environment;
  }

  private static string Find()
  {
    if (!OperatingSystem.IsWindows()) return "/usr/bin/python3";
    foreach (var folder in (System.Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
    {
      if (folder.Contains("WindowsApps", StringComparison.OrdinalIgnoreCase)) continue;
      var candidate = Path.Combine(folder.Trim('"'), "python.exe");
      if (File.Exists(candidate)) return candidate;
    }
    throw new InvalidOperationException("The chat tests need Python 3 on PATH (python.exe from python.org or winget, not the Store stub).");
  }
}
