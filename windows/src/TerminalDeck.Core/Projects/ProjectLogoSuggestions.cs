using System.Text.Json;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Projects;

// Finds a project's own picture the way the Mac does (ProjectLogos.suggestions):
// logo/icon files at the top, favicons and touch icons in the usual web folders,
// app icon sets and .icns files a few levels down. Windows adds what Windows and
// cross-platform projects keep: package.json and web-manifest icons, a .csproj
// ApplicationIcon, Android launcher icons and Store logos. Only files that are
// really there are offered, and links never lead outside the project folder.
public static partial class ProjectLogoSuggestions
{
  public static readonly string[] Extensions = [".png", ".jpg", ".jpeg", ".webp", ".bmp", ".ico", ".svg", ".icns"];
  // What the Windows picture store can decode. SVG and ICNS are offered but not adopted automatically.
  public static readonly string[] Usable = [".png", ".jpg", ".jpeg", ".webp", ".bmp", ".ico"];
  public const int Limit = 12;
  private const long MaxBytes = 10 * 1024 * 1024;
  private static readonly string[] WebFolders = ["public", "static", "assets", "public/images", "src/assets", "app", "src/app", "assets/images", "images", "img",
    "resources", "Resources", "build", "src-tauri/icons", "Assets", "brand", "branding", "docs/brand"];
  private static readonly string[] WebNames = ["apple-touch-icon.png", "icon-512.png", "icon-192.png", "logo.png", "icon.png", "favicon.png", "favicon.ico", "logo.ico", "icon.ico", "app.ico",
    "logo.svg", "icon.svg", "favicon.svg", "StoreLogo.png", "Square150x150Logo.png", "Square44x44Logo.png", "128x128@2x.png", "icon.icns"];
  private static readonly HashSet<string> Skip = new(StringComparer.OrdinalIgnoreCase)
  { "node_modules", ".git", ".build", "build", "DerivedData", "Pods", ".next", "dist", "vendor", ".gradle", "bin", "obj", "out", "coverage", "target", ".venv", "venv", "__pycache__", ".turbo", ".nuxt", "packages-cache" };
  [GeneratedRegex(@"^(favicon|logo|app-?icon|icon|apple-touch-icon|storelogo|square\d+x\d+logo)([-_.@][^\\/]*)?\.(png|jpe?g|webp|bmp|ico|svg|icns)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
  private static partial Regex PictureName();

  public static bool IsUsable(string path) => Usable.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);
  public static IReadOnlyList<string> Find(string folder) => Find([folder]);
  public static IReadOnlyList<string> Find(IEnumerable<string> folders)
  {
    var found = new List<string>();
    foreach (var folder in folders.Where(f => !string.IsNullOrWhiteSpace(f)))
    {
      if (found.Count >= Limit) break;
      try { Scan(folder, found); }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
    }
    return found;
  }

  private static void Scan(string folder, List<string> found)
  {
    var root = new DirectoryInfo(folder);
    if (!root.Exists) return;
    void Add(string? relative)
    {
      if (found.Count >= Limit || relative is null) return;
      var full = Inside(root, relative);
      if (full is null || found.Contains(full, StringComparer.OrdinalIgnoreCase)) return;
      found.Add(full);
    }
    foreach (var name in new[] { "logo", "icon", "Logo", "Icon" })
      foreach (var ext in new[] { ".png", ".ico", ".jpg", ".jpeg", ".webp", ".svg", ".icns" }) Add(name + ext);
    foreach (var dir in WebFolders) foreach (var name in WebNames) Add(dir + "/" + name);
    foreach (var manifest in new[] { "public/manifest.json", "public/site.webmanifest", "public/manifest.webmanifest", "static/manifest.json", "site.webmanifest", "manifest.json", "app/manifest.json" })
      Add(ManifestIcon(root, manifest));
    Add(PackageIcon(root));
    Walk(root, Add);
  }

  // App icon sets, .icns, Android launcher icons and well-named pictures a few levels down.
  private static void Walk(DirectoryInfo root, Action<string?> add)
  {
    var queue = new Queue<(DirectoryInfo Dir, int Depth)>(); queue.Enqueue((root, 0)); var visited = 0;
    string? bestLauncher = null; var bestDensity = -1;
    while (queue.Count > 0 && visited < 20_000)
    {
      var (dir, depth) = queue.Dequeue();
      IEnumerable<FileSystemInfo> entries;
      try { entries = dir.EnumerateFileSystemInfos().ToArray(); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
      foreach (var entry in entries)
      {
        if (++visited >= 20_000) break;
        if (entry.LinkTarget is not null || entry.Name.StartsWith('.')) continue;
        var relative = Path.GetRelativePath(root.FullName, entry.FullName).Replace('\\', '/');
        if (entry is DirectoryInfo child)
        {
          if (Skip.Contains(child.Name) || depth >= 5) continue;
          if (child.Name.EndsWith(".appiconset", StringComparison.OrdinalIgnoreCase) && child.Name.Contains("appicon", StringComparison.OrdinalIgnoreCase))
          {
            try { add(child.EnumerateFiles("*.png").Where(f => f.LinkTarget is null && f.Length is > 0 and <= MaxBytes).OrderByDescending(f => f.Length).FirstOrDefault() is { } largest ? relative + "/" + largest.Name : null); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
            continue;
          }
          if (child.Name.StartsWith("mipmap-", StringComparison.OrdinalIgnoreCase))
          {
            var density = Array.IndexOf(new[] { "mipmap-mdpi", "mipmap-hdpi", "mipmap-xhdpi", "mipmap-xxhdpi", "mipmap-xxxhdpi" }, child.Name.ToLowerInvariant());
            if (density > bestDensity && File.Exists(Path.Combine(child.FullName, "ic_launcher.png"))) { bestDensity = density; bestLauncher = relative + "/ic_launcher.png"; }
            continue;
          }
          queue.Enqueue((child, depth + 1));
        }
        else if (entry is FileInfo file)
        {
          var fileDepth = depth + 1;
          if (file.Extension.Equals(".icns", StringComparison.OrdinalIgnoreCase) && fileDepth <= 4) add(relative);
          else if (fileDepth <= 3 && PictureName().IsMatch(file.Name)) add(relative);
          else if (fileDepth <= 3 && file.Extension.Equals(".csproj", StringComparison.OrdinalIgnoreCase)) add(ApplicationIcon(root, file));
        }
      }
    }
    add(bestLauncher);
  }

  private static string? ManifestIcon(DirectoryInfo root, string relative)
  {
    var path = Inside(root, relative, pictures: false);
    if (path is null) return null;
    try
    {
      using var doc = JsonDocument.Parse(File.ReadAllText(path));
      if (!doc.RootElement.TryGetProperty("icons", out var icons) || icons.ValueKind != JsonValueKind.Array) return null;
      static int Size(JsonElement icon) => icon.TryGetProperty("sizes", out var s) && s.ValueKind == JsonValueKind.String
        ? s.GetString()!.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(v => int.TryParse(v.Split('x')[0], out var n) ? n : 0).DefaultIfEmpty(0).Max() : 0;
      var best = icons.EnumerateArray().Where(i => i.TryGetProperty("src", out var src) && src.ValueKind == JsonValueKind.String).OrderByDescending(Size).FirstOrDefault();
      if (best.ValueKind != JsonValueKind.Object) return null;
      var src = best.GetProperty("src").GetString()!.Split('?')[0];
      if (src.Contains("://", StringComparison.Ordinal)) return null;
      var baseDir = Path.GetDirectoryName(relative)!.Replace('\\', '/');
      // A leading slash is the web root, which for these manifests is the folder they sit in.
      return src.StartsWith('/') ? (baseDir.Length == 0 ? "" : baseDir + "/") + src.TrimStart('/') : (baseDir.Length == 0 ? "" : baseDir + "/") + src;
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException) { return null; }
  }
  private static string? PackageIcon(DirectoryInfo root)
  {
    var path = Inside(root, "package.json", pictures: false);
    if (path is null) return null;
    try
    {
      using var doc = JsonDocument.Parse(File.ReadAllText(path));
      var r = doc.RootElement;
      if (r.TryGetProperty("icon", out var icon) && icon.ValueKind == JsonValueKind.String) return icon.GetString();
      if (r.TryGetProperty("build", out var build) && build.ValueKind == JsonValueKind.Object && build.TryGetProperty("icon", out var built) && built.ValueKind == JsonValueKind.String) return built.GetString();
      if (r.TryGetProperty("build", out build) && build.ValueKind == JsonValueKind.Object && build.TryGetProperty("win", out var win) && win.ValueKind == JsonValueKind.Object && win.TryGetProperty("icon", out var winIcon) && winIcon.ValueKind == JsonValueKind.String) return winIcon.GetString();
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException) { }
    return null;
  }
  private static string? ApplicationIcon(DirectoryInfo root, FileInfo project)
  {
    try
    {
      var text = File.ReadAllText(project.FullName);
      var match = Regex.Match(text, "<ApplicationIcon>([^<]{1,200})</ApplicationIcon>", RegexOptions.CultureInvariant);
      return match.Success ? Path.GetRelativePath(root.FullName, Path.Combine(project.DirectoryName!, match.Groups[1].Value.Trim())).Replace('\\', '/') : null;
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
  }
  // The file must exist, sit inside the folder with no linked step on the way, and be a picture of sensible size.
  private static string? Inside(DirectoryInfo root, string relative, bool pictures = true)
  {
    if (relative.Length == 0 || relative.Contains('\0') || Path.IsPathRooted(relative)) return null;
    var parts = relative.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
    if (parts.Any(p => p is "." or "..")) return null;
    var current = root.FullName;
    for (var i = 0; i < parts.Length; i++)
    {
      current = Path.Combine(current, parts[i]);
      if (i < parts.Length - 1)
      {
        var dir = new DirectoryInfo(current);
        if (!dir.Exists || dir.LinkTarget is not null) return null;
      }
    }
    var file = new FileInfo(current);
    if (!file.Exists || file.LinkTarget is not null || file.Length is <= 0 or > MaxBytes) return null;
    if (pictures && !Extensions.Contains(file.Extension, StringComparer.OrdinalIgnoreCase)) return null;
    // Case-insensitive file systems answer for a differently-cased name; report the name on disk.
    try { var real = file.Directory!.EnumerateFiles(file.Name).FirstOrDefault(); if (real is not null) return real.FullName; } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    return file.FullName;
  }
}

// Gives a project with no picture the first usable one found in its folders. A person
// who removes a logo turns this off for that project (ProjectService.SetPicture), so a
// removed logo never comes back by itself.
public static class ProjectLogoAuto
{
  public const string OffKey = "logo.autoOff";
  public static bool Wanted(Project p) => p.Id != ProjectIdentity.IndependentId && p.Logo.Length == 0 && !p.Preferences.Flag(OffKey) && !p.Folders.IsDefaultOrEmpty;
  public static string? Fill(IProjects projects, string id, Func<IReadOnlyList<string>, IReadOnlyList<string>>? find = null)
  {
    var project = projects.List().FirstOrDefault(p => p.Id == id);
    if (project is null || !Wanted(project)) return null;
    foreach (var path in (find ?? ProjectLogoSuggestions.Find)(project.Folders).Where(ProjectLogoSuggestions.IsUsable))
    {
      if (projects.List().FirstOrDefault(p => p.Id == id) is not { } now || !Wanted(now)) return null;
      try { projects.SetPicture(id, path); return path; }
      catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException) { }
    }
    return null;
  }
  public static int FillAll(IProjects projects, Func<IReadOnlyList<string>, IReadOnlyList<string>>? find = null) =>
    projects.List().Where(Wanted).Select(p => p.Id).ToArray().Count(id => Fill(projects, id, find) is not null);
}
