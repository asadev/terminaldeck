using System.Text;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Agents;

public sealed record AgentSkillDocument(string Name, string Summary, string Folder, string Text);

// Both the library page and its tools use the same installed SKILL.md files.
public static partial class AgentSkillLibrary
{
  public static AgentSkillDocument Read(string root, string name)
  {
    var folder = Folder(root, name);
    var file = Path.Combine(folder, "SKILL.md");
    if (!File.Exists(file)) throw new FileNotFoundException("This skill is no longer installed.");
    if (new FileInfo(file).Length > 512 * 1024) throw new IOException("This skill is too large to edit here.");
    if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0) throw new IOException("Choose a skill file without a link.");
    var text = File.ReadAllText(file);
    var facts = AgentSkills.FrontMatter(text.Split('\n').Take(60));
    return new(facts.Name.Length > 0 ? facts.Name : name, facts.Description, folder, text);
  }

  public static AgentSkillDocument Save(string root, string name, string text, string? expected = null)
  {
    if (string.IsNullOrWhiteSpace(text) || Encoding.UTF8.GetByteCount(text) > 512 * 1024)
      throw new ArgumentException("Write the skill instructions, up to 512 KB.");
    var folder = Folder(root, name);
    var file = Path.Combine(folder, "SKILL.md");
    if (File.Exists(file))
    {
      if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0) throw new IOException("Choose a skill file without a link.");
      if (expected is null) throw new IOException("A skill with this folder name is already installed.");
      if (File.ReadAllText(file) != expected) throw new IOException("This skill changed while you were editing it. Open it again.");
    }
    else if (expected is not null) throw new IOException("This skill was removed while you were editing it.");
    Directory.CreateDirectory(folder);
    var temporary = Path.Combine(folder, Guid.NewGuid().ToString("N") + ".tmp");
    try { File.WriteAllText(temporary, text, new UTF8Encoding(false)); File.Move(temporary, file, overwrite: expected is not null); }
    finally { if (File.Exists(temporary)) File.Delete(temporary); }
    return Read(root, name);
  }

  public static string Folder(string root, string name)
  {
    if (!SafeName().IsMatch(name)) throw new ArgumentException("Use a skill folder name with letters, numbers and dashes.");
    var full = Path.GetFullPath(root);
    var folder = Path.Combine(full, name);
    // A skill must stay in the selected installed-skills folder, including through directory links.
    for (DirectoryInfo? parent = new(folder); parent is not null; parent = parent.Parent)
      if (parent.Exists && (parent.Attributes & FileAttributes.ReparsePoint) != 0)
        throw new IOException("Choose a skills folder without a directory link.");
    return folder;
  }

  [GeneratedRegex("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$")]
  private static partial Regex SafeName();
}
