using System.Runtime.InteropServices;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Platform.Windows;

public sealed class WindowsMcpCommandResolver : IMcpCommandResolver
{
  public McpCommand Resolve(string commandLine)
  {
    if (string.IsNullOrWhiteSpace(commandLine) || commandLine.Contains('\0') || commandLine.Length >= 32767) throw new McpRefusal("Choose a Windows executable and its arguments.");
    var argv = CommandLineToArgv(commandLine, out var count);
    if (argv == IntPtr.Zero) throw new McpRefusal("The Windows command could not be read.");
    try
    {
      var values = Enumerable.Range(0, count).Select(i => Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size)) ?? "").ToArray();
      if (values.Length == 0 || values[0].Length == 0) throw new McpRefusal("Choose the executable that starts this MCP server.");
      var requested = values[0];
      if (Path.GetExtension(requested).Length == 0) requested += ".exe";
      if (!requested.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) throw new McpRefusal("Choose the direct .exe file. Shell command wrappers need a verified provider adapter.");
      var candidates = Path.IsPathFullyQualified(requested) ? new[] { requested } :
        (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
          .Where(Path.IsPathFullyQualified).Select(folder => Path.Combine(folder, requested));
      var executable = candidates.FirstOrDefault(File.Exists) ?? throw new McpRefusal("This executable was not found. Choose its full Windows path.");
      return new(Path.GetFullPath(executable), values[1..]);
    }
    finally { LocalFree(argv); }
  }
  [DllImport("shell32.dll", EntryPoint = "CommandLineToArgvW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CommandLineToArgv(string commandLine, out int count);
  [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr pointer);
}
