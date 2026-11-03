namespace TerminalDeck.Core.Receiver;

public enum ArtifactOpenHandler { TextEditor, DefaultApplication }

public static class ArtifactOpenPolicy
{
  private static readonly HashSet<string> TextPreviewTypes = new(StringComparer.OrdinalIgnoreCase)
    { ".txt", ".md", ".json", ".csv", ".tsv", ".log", ".xml", ".yaml", ".yml", ".swift", ".cs", ".ts", ".js", ".py", ".css", ".svg", ".html", ".htm", ".xhtml" };
  private static readonly HashSet<string> DefaultHandlerTypes = new(StringComparer.OrdinalIgnoreCase)
    { ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".pdf" };
  public static bool IsTextPreview(string extension) => TextPreviewTypes.Contains(extension);
  // Previewable source is data, even when a Windows association calls it a
  // runnable script. Only fixed text-editor dispatch may open these files.
  public static ArtifactOpenHandler HandlerFor(string path)
  {
    var extension = Path.GetExtension(path);
    if (TextPreviewTypes.Contains(extension)) return ArtifactOpenHandler.TextEditor;
    if (DefaultHandlerTypes.Contains(extension) || ArtifactCatalogPolicy.Includes(path) && extension is not (".svg" or ".html" or ".htm" or ".xhtml")) return ArtifactOpenHandler.DefaultApplication;
    throw new ArgumentException("Preview this file here. This app does not launch executable or unknown file types.");
  }
}
