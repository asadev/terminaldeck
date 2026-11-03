using System.Text;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

public static class ProjectMcpEnvironment
{
  public static IReadOnlyDictionary<string, string> Read(AppDataRoot root, string folder)
  {
    var state = new JsonStateStore<McpManagerState>(root, "mcp").Load(); if (state is null) return new Dictionary<string, string>();
    var secrets = new WindowsCredentialStore(root); var output = new Dictionary<string, string>();
    foreach (var config in state.Servers.Where(s => s.Scope == "project" && s.Enabled && string.Equals(Path.GetFullPath(s.Folder!), Path.GetFullPath(folder), StringComparison.OrdinalIgnoreCase)))
      foreach (var reference in config.EnvironmentReferences.Values.Concat(config.HeaderReferences.Values).Concat((config.ArgumentReferences ?? []).Values).Distinct())
      {
        var value = secrets.ReadAsync(reference).AsTask().GetAwaiter().GetResult();
        if (value is null) throw new IOException("A shared project MCP credential is unavailable. Update its protected sign-in in MCP settings.");
        try { output[McpProjectFiles.Variable(reference)] = Encoding.UTF8.GetString(value); }
        finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(value); }
      }
    return output;
  }
}
