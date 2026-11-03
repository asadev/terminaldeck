namespace TerminalDeck.Core.Receiver;

// Output types shared by the catalog and the write recorder. Source, plans and
// unknown extensions stay out even when older indexes recorded them.
public static class ArtifactCatalogPolicy
{
  public static string? Kind(string path) => Path.GetFileName(path).LastIndexOf('.') <= 0 ? null : Path.GetExtension(path).ToLowerInvariant() switch
  {
    ".html" or ".htm" or ".xhtml" or ".pdf" => "Documents",
    ".png" or ".jpg" or ".jpeg" or ".gif" or ".webp" or ".avif" or ".bmp" or ".ico" or ".heic" or ".heif" or ".svg" => "Pictures",
    ".mp4" or ".m4v" or ".mov" or ".webm" or ".mp3" or ".m4a" or ".wav" or ".aac" or ".flac" or ".ogg" => "Videos",
    _ => null
  };
  public static bool Includes(string path) => Kind(path) is not null;
}
