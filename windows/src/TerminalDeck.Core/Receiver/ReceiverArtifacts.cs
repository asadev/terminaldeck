using System.Collections.Immutable;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Receiver;

public sealed record ReceiverArtifact(string Id, string ProjectId, string Cwd, string RelPath, string SessionId, DateTimeOffset ProducedAt, bool Hidden = false);
public sealed record ReceiverArtifactRoot(string Path, string ProjectId);
public sealed record ReceiverArtifactState(ImmutableArray<ReceiverArtifact> Artifacts);
public sealed record ArtifactPreview(ReceiverArtifact Artifact, string MediaType, string? Text, string? ImagePath, bool Truncated)
{
  public string? FilePath { get; init; }
}
public interface IReceiverArtifacts
{
  event Action? Changed;
  IReadOnlyList<ReceiverArtifactRoot> Roots() => [];
  IReadOnlyList<ReceiverArtifact> List(string cwd, string? path = null, int limit = 300);
  ArtifactPreview Preview(string cwd, string relPath);
  ValueTask OpenAsync(string cwd, string relPath, CancellationToken ct = default);
  ValueTask SendAsync(string cwd, string relPath, ReceiverTarget target, CancellationToken ct = default);
  void Remove(string cwd, string relPath);
}

// Only recorded agent outputs appear. A folder scan cannot tell which files a
// session produced. Transcript/session owners call Record after a real write.
public sealed class ReceiverArtifacts(IStateStore<ReceiverArtifactState> store, Func<string, string?> projectForFolder,
  Func<string, CancellationToken, ValueTask> open, Func<ReceiverArtifact, ReceiverTarget, CancellationToken, ValueTask> send) : IReceiverArtifacts
{
  private readonly object gate = new();
  private ReceiverArtifactState state = store.Load() ?? new([]);
  public event Action? Changed;
  public void Record(string cwd, string relative, string sessionId, DateTimeOffset at)
  {
    if (!ArtifactCatalogPolicy.Includes(relative)) return;
    var producingFolder = Path.GetFullPath(cwd); var projectId = projectForFolder(producingFolder) ?? "independent";
    ReceiverStore.Check(sessionId, 128);
    if (relative.Contains('\0') || !Path.IsPathFullyQualified(cwd)) throw new ArgumentException("Choose a recorded output path.");
    // Only trusted write receipts call Record. An outside output grants this
    // exact file; it never lets previews traverse out from the producing folder.
    var full = Path.GetFullPath(relative, producingFolder);
    var isInside = full.StartsWith(Path.TrimEndingDirectorySeparator(producingFolder) + Path.DirectorySeparatorChar, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
    var outputRoot = isInside ? producingFolder : Path.GetDirectoryName(full)!;
    var outputRelative = Path.GetRelativePath(outputRoot, full).Replace('\\', '/');
    _ = SafePath(outputRoot, outputRelative);
    lock (gate)
    {
      var previous = state.Artifacts.FirstOrDefault(a => Same(Path.Combine(a.Cwd, a.RelPath), full));
      // Historical rebuilds replay saved receipts, never the delivery itself.
      // Equal/older receipts must not resurface a person's hidden catalogue item.
      if (previous is not null && previous.ProducedAt >= at) return;
      var artifact = new ReceiverArtifact(previous?.Id ?? Guid.NewGuid().ToString("N"), projectId, outputRoot, outputRelative, sessionId, at);
      Save(new(state.Artifacts.Where(a => a.Id != artifact.Id).Append(artifact).TakeLast(2000).ToImmutableArray()));
    }
    Changed?.Invoke();
  }
  public IReadOnlyList<ReceiverArtifactRoot> Roots()
  {
    lock (gate) return state.Artifacts.Where(a => !a.Hidden && ArtifactCatalogPolicy.Includes(a.RelPath))
      .Select(a => new ReceiverArtifactRoot(a.Cwd, a.ProjectId)).DistinctBy(a => a.Path, OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal).ToArray();
  }
  public IReadOnlyList<ReceiverArtifact> List(string cwd, string? path = null, int limit = 300)
  {
    if (!Path.IsPathFullyQualified(cwd)) throw new ArgumentException("Choose a recorded output folder.");
    if (projectForFolder(Path.GetFullPath(cwd)) is null && !Roots().Any(r => Same(r.Path, cwd))) throw new ArgumentException("Choose a project or recorded output folder.");
    lock (gate) return state.Artifacts.Where(a => !a.Hidden && ArtifactCatalogPolicy.Includes(a.RelPath) && Same(a.Cwd, cwd) && (path is null || a.RelPath == path)).OrderByDescending(a => a.ProducedAt).Take(Math.Clamp(limit, 1, 300)).ToArray();
  }
  public ArtifactPreview Preview(string cwd, string relPath)
  {
    var artifact = Find(cwd, relPath); var path = SafePath(cwd, relPath); var extension = Path.GetExtension(path).ToLowerInvariant();
    if (ArtifactCatalogPolicy.Kind(path) == "Pictures") return new(artifact, "image/" + extension[1..], null, path, false) { FilePath = path };
    if (ArtifactCatalogPolicy.Kind(path) == "Videos") return new(artifact, extension is ".mp3" or ".m4a" or ".wav" or ".aac" or ".flac" or ".ogg" ? "audio/" + extension[1..] : "video/" + extension[1..], null, null, false) { FilePath = path };
    if (extension == ".pdf") return new(artifact, "application/pdf", null, null, false) { FilePath = path };
    if (extension is not (".html" or ".htm" or ".xhtml") && !ArtifactOpenPolicy.IsTextPreview(extension)) return new(artifact, "application/octet-stream", "Preview is unavailable for this file type. Open it in its own app.", null, false);
    using var stream = File.OpenRead(path); using var reader = new StreamReader(stream);
    var chars = new char[65537]; var count = reader.ReadBlock(chars, 0, chars.Length);
    var text = new string(chars, 0, Math.Min(65536, count));
    if (text.Contains('\0')) return new(artifact, "application/octet-stream", "This file has no text preview.", null, false);
    return new(artifact, extension is ".html" or ".htm" or ".xhtml" ? "text/html" : "text/plain", text, null, count > 65536) { FilePath = path };
  }
  public async ValueTask OpenAsync(string cwd, string relPath, CancellationToken ct = default)
  {
    _ = Find(cwd, relPath); var path = SafePath(cwd, relPath);
    _ = ArtifactOpenPolicy.HandlerFor(path);
    await open(path, ct);
  }
  public async ValueTask SendAsync(string cwd, string relPath, ReceiverTarget target, CancellationToken ct = default)
  {
    var artifact = Find(cwd, relPath); _ = SafePath(cwd, relPath); ReceiverStore.ValidateTarget(target); await send(artifact, target, ct);
  }
  public void Remove(string cwd, string relPath)
  {
    var artifact = Find(cwd, relPath);
    lock (gate) Save(new(state.Artifacts.Replace(artifact, artifact with { Hidden = true })));
    Changed?.Invoke();
  }
  private ReceiverArtifact Find(string cwd, string relative) => List(cwd, relative).SingleOrDefault() ?? throw new ArgumentException(ArtifactCatalogPolicy.Includes(relative)
    ? relative + " is not in this folder's Artifacts list yet. A web page, PDF, picture or video appears there after a session writes it; artifacts_list shows what is there."
    : relative + " is not an artifact type. Artifacts holds web pages, PDFs, pictures, audio and video that sessions made; read other files with your own file tools.");
  private void Save(ReceiverArtifactState next) { store.Save(next); state = next; }
  private static bool Same(string a, string b) => string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(a)), Path.TrimEndingDirectorySeparator(Path.GetFullPath(b)), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
  public static string SafePath(string cwd, string relative)
  {
    if (!Path.IsPathFullyQualified(cwd) || Path.IsPathRooted(relative) || relative.Length == 0 || relative.Contains(':') || relative.Contains('\\') || relative.Split('/').Any(s => s is ".." or "." or "")) throw new ArgumentException("Choose a relative file inside the project.");
    var root = Path.GetFullPath(cwd); var path = Path.GetFullPath(Path.Combine(root, relative));
    if (!path.StartsWith(Path.TrimEndingDirectorySeparator(root) + Path.DirectorySeparatorChar, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) throw new ArgumentException("Choose a file inside this project.");
    if (!File.Exists(path)) throw new IOException("File no longer on disk. Its source is still in the chat.");
    for (var current = new DirectoryInfo(root); current is not null; current = current.Parent)
      if ((current.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("Linked project folders cannot be opened here.");
    var check = root;
    foreach (var part in relative.Split('/'))
    {
      check = Path.Combine(check, part);
      if ((File.GetAttributes(check) & FileAttributes.ReparsePoint) != 0) throw new IOException("Linked files and folders cannot be opened here.");
    }
    if (!File.Exists(path)) throw new IOException("File no longer on disk. Its source is still in the chat.");
    return path;
  }
}
