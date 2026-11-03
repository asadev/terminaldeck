using TerminalDeck.Core.Servers;
namespace TerminalDeck.Platform.Windows.Servers;

public static class WindowsSshAliases
{
  // An explicit owner read, never a probe at startup. Directive values are
  // parsed as data: Match/ProxyCommand/LocalCommand/Include are never executed.
  public static IReadOnlyList<ServerSshAlias> Read(string selectedConfig)
  {
    var file = new FileInfo(Path.GetFullPath(selectedConfig));
    for (var folder = file.Directory; folder is not null; folder = folder.Parent)
      if (folder.Exists && folder.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new ServerRefusal("Choose the real SSH configuration file.");
    if (!file.Exists) return [];
    if (file.Attributes.HasFlag(FileAttributes.ReparsePoint) || file.Length > 1048576) throw new ServerRefusal("Choose an SSH configuration file up to 1 MB without links.");
    return Parse(File.ReadAllText(file.FullName));
  }
  public static IReadOnlyList<ServerSshAlias> Parse(string text)
  {
    if (text.Length > 1048576) throw new ServerRefusal("The SSH configuration is too large.");
    var result = new List<ServerSshAlias>(); string[] aliases = []; string? host = null, user = null; var port = 22; var keys = new List<string>();
    void Flush()
    {
      foreach (var alias in aliases)
      {
        if (result.Count >= 500) break;
        var destination = host ?? alias; var login = user ?? Environment.UserName;
        try { ServerValidation.Draft(new(alias, destination, port, login, ServerAuthentication.Key)); result.Add(new(alias, destination, port, login, keys.Distinct().ToArray())); } catch (ServerRefusal) { }
      }
    }
    foreach (var raw in text.Split('\n'))
    {
      var line = raw.Trim(); if (line.Length == 0 || line[0] == '#') continue;
      var split = line.IndexOfAny([' ', '\t', '=']); if (split < 0) continue;
      var directive = line[..split].ToLowerInvariant(); var value = line[(split + 1)..].Trim().TrimStart('=').Trim();
      if (directive == "host") { Flush(); aliases = value.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries).Where(a => a.Length <= 128 && a.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.')).ToArray(); host = user = null; port = 22; keys.Clear(); }
      else if (directive == "match") { Flush(); aliases = []; }
      else if (aliases.Length > 0)
      {
        if (directive == "hostname" && host is null) host = value;
        else if (directive == "user" && user is null) user = value;
        else if (directive == "port" && int.TryParse(value, out var parsed) && parsed is >= 1 and <= 65535) port = parsed;
        else if (directive == "identityfile") { var name = Path.GetFileName(value.Trim('"').Replace('\\', '/')); if (ServerSettingsRules.Name(name, 255)) keys.Add(name); }
      }
    }
    Flush(); return result.DistinctBy(a => a.Alias, StringComparer.OrdinalIgnoreCase).OrderBy(a => a.Alias).ToArray();
  }
}
