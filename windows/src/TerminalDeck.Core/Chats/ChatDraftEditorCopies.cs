using System.Text;
using TerminalDeck.Core.Storage;
namespace TerminalDeck.Core.Chats;

public sealed record ChatEditorSource(long DraftRevision, string? ConversationId);
public sealed record ChatEditorCopy(string Id, string ChatId, string Path, long DraftRevision, string? ConversationId);
public sealed class ChatDraftEditorCopies(AppDataRoot root)
{
  private static readonly UTF8Encoding Encoding = new(false, true);
  private string PathFor(string chat, string copy) => System.IO.Path.Combine(root.DirectoryPath, "chats", Guid.Parse(chat).ToString("N"), "draft-editor", Guid.ParseExact(copy, "N").ToString("N") + ".txt");
  public ChatEditorCopy Prepare(ChatRecord chat, ChatDraftBuffer buffer, string? editorText = null, ChatEditorSource? source = null)
  { try { lock (buffer) return PrepareOwned(chat, buffer, editorText, source); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { throw new InvalidOperationException("The private editor copy could not be saved. Your draft is kept."); } }
  private ChatEditorCopy PrepareOwned(ChatRecord chat, ChatDraftBuffer buffer, string? editorText, ChatEditorSource? source)
  {
    if (buffer.EditorCopy is { } existing) { Validate(existing); return existing; }
    var draft = buffer.Read();
    if (source is not null && (draft.Revision != source.DraftRevision || chat.ConversationId != source.ConversationId)) throw new InvalidOperationException("The source draft or conversation changed. Open the current draft before making an editor copy.");
    var text = editorText ?? draft.Text; ChatText.ValidatePrompt(text);
    var bytes = Encoding.GetBytes(text);
    var id = Guid.NewGuid().ToString("N"); var path = PathFor(chat.Definition.Id, id);
    if (OperatingSystem.IsWindows()) Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
    else Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
    {
      if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
      output.Write(bytes); output.Flush(true);
    }
    var copy = new ChatEditorCopy(id, chat.Definition.Id, path, draft.Revision, chat.ConversationId); buffer.SetEditorCopy(copy); return copy;
  }
  public ChatDraftSnapshot Import(ChatRecord chat, ChatDraftBuffer buffer)
  { try { lock (buffer) return ImportOwned(chat, buffer); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { throw new InvalidOperationException("The private editor copy could not be read. Your draft is kept."); } }
  private ChatDraftSnapshot ImportOwned(ChatRecord chat, ChatDraftBuffer buffer)
  {
    if (chat.Ended) throw new InvalidOperationException("This chat ended. Its draft and private editor copy are kept.");
    var copy = buffer.EditorCopy ?? throw new InvalidOperationException("Open a private editor copy first."); Validate(copy);
    if (chat.Definition.Id != copy.ChatId || chat.ConversationId != copy.ConversationId) throw new InvalidOperationException("The conversation changed. Keep the editor copy and open the current draft before importing.");
    using var input = new FileStream(copy.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
    var bytes = new byte[ChatText.MaximumPromptBytes + 1]; var count = input.ReadAtLeast(bytes, bytes.Length, false);
    if (count > ChatText.MaximumPromptBytes) throw new ArgumentException("This saved copy is over 262144 UTF-8 bytes. Shorten it in the editor before importing.");
    var start = count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? 3 : 0;
    string text;
    try { text = Encoding.GetString(bytes, start, count - start); } catch (DecoderFallbackException) { throw new ArgumentException("Save this editor copy as UTF-8 before importing."); }
    var applied = buffer.Apply(text, copy.DraftRevision); buffer.SetEditorCopy(copy with { DraftRevision = applied.Revision }); return applied;
  }
  public void Discard(ChatDraftBuffer buffer)
  { try { lock (buffer) DiscardOwned(buffer); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { throw new InvalidOperationException("The private editor copy could not be discarded. Close its editor and try again. Your draft is kept."); } }
  private void DiscardOwned(ChatDraftBuffer buffer)
  {
    if (buffer.EditorCopy is not { } copy) return; Validate(copy, false); File.Delete(copy.Path); buffer.SetEditorCopy(null);
  }
  private void Validate(ChatEditorCopy copy, bool requireExists = true)
  {
    if (copy.Path != PathFor(copy.ChatId, copy.Id) || requireExists && !File.Exists(copy.Path) || File.Exists(copy.Path) && (File.GetAttributes(copy.Path) & FileAttributes.ReparsePoint) != 0)
      throw new InvalidOperationException("This private editor copy is unavailable. The draft is kept.");
  }
}
