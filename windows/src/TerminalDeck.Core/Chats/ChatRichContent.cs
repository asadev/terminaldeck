using System.Net;
using System.Text;
using Markdig;
using Markdig.Renderers;
using Markdig.Renderers.Html;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;

namespace TerminalDeck.Core.Chats;

public sealed record ChatRenderedBlock(string Type, string Source, string Language = "", bool Complete = true);

public static class ChatRichContent
{
  // The same words on every app (Mac: ChatMarkdown.instruction). Visuals follow the app's light or dark theme
  // through the sealed document's variables (release check, 6 Nov: dark grey chart text on the dark card).
  public const string Instruction = "This chat shows GitHub Markdown (tables, lists, math), ```mermaid diagrams and ```visual blocks (HTML/SVG/JS; scripts only from cdnjs/jsdelivr) drawn live. Visuals follow the app's light or dark theme: colour text, labels, axes and lines with var(--text) or currentColor, secondary text with var(--muted), highlights with var(--accent) and fills behind text with var(--background); never fixed dark or light text colours. Canvas charts read them with getComputedStyle(document.documentElement).getPropertyValue('--text').";
  private static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder().UseAdvancedExtensions().DisableHtml().Build();
  public static MarkdownDocument Parse(string text) => Markdown.Parse(text, Pipeline);
  public static IReadOnlyList<ChatRenderedBlock> Blocks(string text)
  {
    var document = Parse(text);
    var blocks = document.Select(block => block is FencedCodeBlock fence
      ? new ChatRenderedBlock(Kind(fence), fence.Lines.ToString(), fence.Info ?? "", fence.ClosingFencedCharCount >= fence.OpeningFencedCharCount)
      : new ChatRenderedBlock("markdown", text.Substring(block.Span.Start, Math.Max(0, Math.Min(text.Length - block.Span.Start, block.Span.Length))))).ToList();
    var topFences = document.OfType<FencedCodeBlock>().Select(f => f.Span.Start).ToHashSet();
    blocks.AddRange(document.Descendants<FencedCodeBlock>().Where(f => !topFences.Contains(f.Span.Start)).Select(f =>
      new ChatRenderedBlock(Kind(f), f.Lines.ToString(), f.Info ?? "", f.ClosingFencedCharCount >= f.OpeningFencedCharCount)));
    return blocks;
  }
  private static string Kind(FencedCodeBlock block) => block.Info?.Trim().ToLowerInvariant() switch
  { "visual" => "visual", "mermaid" => "mermaid", "svg" => "svg", _ => "code" };
  // Decker, 8 Nov (D3): the drawing instruction goes to the AI ONCE per session, as on the Mac, not with
  // every message (about 85 tokens each). Codex's app-server gets it in its thread's developer
  // instructions (the Mac's point); Claude and Gemini with the first message of each connection;
  // Codex exec with the first turn of a conversation.
  public static string Prompt(ChatRecord chat, string text, bool drawing = true)
  {
    // Replayed context stays complete on disk and crosses stdin, never argv.
    var replay = chat.ReplayHistory && chat.ConversationId is null ? "Saved conversation (context only; do not repeat its operations):\n" + ChatText.Export(chat with { Events = chat.Events.Where(e => e.Kind != "historySeed").ToArray() }) : "";
    return string.Join("\n\n", new[] { chat.Definition.Instructions, drawing ? Instruction : "", replay, text }.Where(s => s.Length > 0));
  }
  public static string Html(string text, string? folder = null)
  {
    var document = Parse(text);
    foreach (var link in document.Descendants<LinkInline>())
    {
      var url = link.Url ?? "";
      if (link.IsImage) link.Url = ImageUrl(url, folder);
      else if (!ChatMarkdown.CanOpenLink(url) && !url.StartsWith('#')) link.Url = "#";
    }
    using var output = new StringWriter();
    var renderer = new HtmlRenderer(output);
    Pipeline.Setup(renderer);
    renderer.ObjectRenderers.Insert(0, new RichCodeRenderer());
    renderer.Render(document); output.Flush(); return output.ToString();
  }
  public static string ImageUrl(string target, string? folder)
  {
    if (target.StartsWith("data:image/", StringComparison.OrdinalIgnoreCase) && target.Length <= 12 * 1024 * 1024) return target;
    if (Uri.TryCreate(target, UriKind.Absolute, out var uri) && uri.Scheme is "https" or "http") return target;
    if (folder is null) return "";
    try
    {
      var path = Uri.TryCreate(target, UriKind.Absolute, out uri) && uri.IsFile ? uri.LocalPath : Path.GetFullPath(target, folder);
      var root = Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
      if (!path.StartsWith(root, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) return "";
      for (var current = new FileInfo(path) as FileSystemInfo; current is not null; current = current is FileInfo file ? file.Directory : ((DirectoryInfo)current).Parent)
      {
        if (current.Exists && current.Attributes.HasFlag(FileAttributes.ReparsePoint)) return "";
        if (string.Equals(current.FullName.TrimEnd(Path.DirectorySeparatorChar), root.TrimEnd(Path.DirectorySeparatorChar), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) break;
      }
      var extension = Path.GetExtension(path).ToLowerInvariant();
      var mime = extension switch { ".png" => "image/png", ".jpg" or ".jpeg" => "image/jpeg", ".gif" => "image/gif", ".webp" => "image/webp", ".svg" => "image/svg+xml", _ => "" };
      return mime.Length > 0 && new FileInfo(path).Length <= 8 * 1024 * 1024 ? "data:" + mime + ";base64," + Convert.ToBase64String(File.ReadAllBytes(path)) : "";
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return ""; }
  }
  private sealed class RichCodeRenderer : HtmlObjectRenderer<CodeBlock>
  {
    protected override void Write(HtmlRenderer renderer, CodeBlock block)
    {
      var fence = block as FencedCodeBlock;
      var kind = fence is null ? "code" : Kind(fence);
      var source = block.Lines.ToString();
      var encoded = WebUtility.HtmlEncode(source);
      if (kind != "code" && fence is { ClosingFencedCharCount: > 0 })
      {
        renderer.Write("<section class=\"rich-block\" data-kind=\"").Write(kind).Write("\" data-source=\"")
          .Write(Convert.ToBase64String(Encoding.UTF8.GetBytes(source))).Write("\"><div class=\"drawing\"></div><details><summary>Code</summary><pre><code>")
          .Write(encoded).Write("</code></pre></details></section>");
      }
      else
      {
        var language = WebUtility.HtmlEncode(fence?.Info ?? "");
        renderer.Write("<pre><code class=\"language-").Write(language).Write("\">").Write(encoded).Write("</code></pre>");
      }
    }
  }
}
