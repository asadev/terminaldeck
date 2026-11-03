using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Projects;

public sealed class LocalProjectFolders(AppDataRoot root) : IProjectFolders
{
  public string RequireFolder(string folder)
  {
    var path = ProjectPaths.Normalize(folder);
    if (!Directory.Exists(path)) throw new ArgumentException("Choose an existing home folder on this computer.");
    var resolved = Resolve(new DirectoryInfo(path));
    var own = Resolve(new DirectoryInfo(root.DirectoryPath));
    if (ProjectPaths.Contains(own, resolved)) throw new ArgumentException("Choose a home folder outside the app's own data folder.");
    return Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
  }
  public string Create(string parent, string name)
  {
    parent = RequireFolder(parent);
    var reserved = name.Split('.')[0].ToUpperInvariant();
    if (string.IsNullOrWhiteSpace(name) || name.Length > 255 || name is "." or ".." || name.EndsWith(' ') || name.EndsWith('.') ||
      name.Any(c => char.IsControl(c) || "<>:\"/\\|?*".Contains(c)) || reserved is "CON" or "PRN" or "AUX" or "NUL" ||
      reserved.Length == 4 && (reserved.StartsWith("COM", StringComparison.Ordinal) || reserved.StartsWith("LPT", StringComparison.Ordinal)) && reserved[3] is >= '1' and <= '9')
      throw new ArgumentException("Choose a folder name without path separators, reserved Windows names or trailing dots/spaces.");
    var path = Path.Combine(parent, name);
    if (Directory.Exists(path) || File.Exists(path)) throw new ArgumentException("That name already exists in this folder. Choose another name.");
    Directory.CreateDirectory(path); return RequireFolder(path);
  }
  public IReadOnlyList<ProjectFolder> Browse(string folder, bool showHidden)
  {
    var path = RequireFolder(folder);
    return new DirectoryInfo(path).EnumerateDirectories().Where(d => showHidden || !d.Name.StartsWith('.') && !d.Attributes.HasFlag(FileAttributes.Hidden))
      .OrderBy(d => d.Name, StringComparer.OrdinalIgnoreCase).Take(301).Select(d => new ProjectFolder(d.Name, d.FullName, Directory.Exists(Path.Combine(d.FullName, ".git")) || File.Exists(Path.Combine(d.FullName, ".git")))).ToArray();
  }
  private static string Resolve(DirectoryInfo directory)
  {
    if (directory.LinkTarget is not null)
    {
      var target = directory.ResolveLinkTarget(true) ?? throw new IOException("This folder link could not be opened.");
      // The link target can still contain a linked parent, such as macOS /var.
      // Resolve that ancestry too before comparing it with the app data root.
      return Resolve(new DirectoryInfo(target.FullName));
    }
    if (directory.Parent is null) return directory.FullName;
    return Path.Combine(Resolve(directory.Parent), directory.Name);
  }
}
