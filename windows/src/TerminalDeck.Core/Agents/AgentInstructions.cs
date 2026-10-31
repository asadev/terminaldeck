using System.Text;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Agents;

public sealed class AgentInstructions(AppDataRoot root) : IAgentInstructions
{
  public string Save(string id, string text)
  {
    if (!Projects.ProjectIdentity.ValidId(id) || Encoding.UTF8.GetByteCount(text) > 512_000 || text.Contains('\0'))
      throw new ArgumentException("Keep agent instructions below 500 KB and use plain text.");
    var directory = Path.Combine(root.DirectoryPath, "agents", "instructions");
    Directory.CreateDirectory(directory);
    var path = Path.Combine(directory, id + "-" + Guid.NewGuid().ToString("N") + ".md");
    // Immutable files keep an unsuccessful profile save from replacing its old instructions.
    using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
    file.Write(Encoding.UTF8.GetBytes(text)); file.Flush(true);
    return path;
  }
  public string Read(string path)
  {
    if (!Path.IsPathFullyQualified(path) || !path.EndsWith(".md", StringComparison.OrdinalIgnoreCase) || !File.Exists(path) || new FileInfo(path).Length > 512_000)
      throw new ArgumentException("Choose a Markdown instructions file below 500 KB.");
    return File.ReadAllText(path, new UTF8Encoding(false, true));
  }
}
