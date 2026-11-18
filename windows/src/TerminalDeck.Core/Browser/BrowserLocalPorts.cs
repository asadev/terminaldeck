namespace TerminalDeck.Core.Browser;

public sealed record BrowserLocalPort(int Port, int ProcessId, string Process, bool Ours = false);
public static class BrowserLocalPorts
{
  private static readonly HashSet<string> Excluded = new(StringComparer.OrdinalIgnoreCase) { "System", "Idle", "svchost", "services", "lsass", "wininit", "spoolsv", "sqlservr", "MsMpEng", "vmware-hostd", "com.docker.backend", "postgres", "mysqld", "redis-server", "mongod", "sshd", "adb", "Spotify", "Dropbox", "Slack", "chrome", "msedge", "msedgewebview2" };
  private static readonly string[] Runtimes = ["node", "bun", "deno", "python", "ruby", "php", "java", "dotnet", "caddy", "nginx", "iisexpress"];
  public static BrowserLocalPort[] Select(IEnumerable<BrowserLocalPort> listeners) => listeners
    .Where(p => p.Port is >= 1024 and <= 65535 && (p.Ours || !Excluded.Contains(p.Process)))
    .GroupBy(p => p.Port).Select(rows => rows.OrderBy(Rank).First()).OrderBy(Rank).ThenBy(p => p.Port).ToArray();
  public static int Rank(BrowserLocalPort port)
  {
    if (port.Ours) return 2000;
    if (port.Process == "unknown") return 1000;
    var index = Array.FindIndex(Runtimes, name => port.Process.StartsWith(name, StringComparison.OrdinalIgnoreCase)); return index < 0 ? 500 : index;
  }
}
