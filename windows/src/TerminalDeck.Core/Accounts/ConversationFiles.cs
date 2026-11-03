using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Accounts;

public interface IConversationFiles
{
  string FindConversation(SessionRecord session);
  void Validate(SessionDefinition source, SessionDefinition destination);
  void Copy(SessionDefinition source, SessionDefinition destination);
  // What a running AI program itself reports: the conversation it is in now (it
  // changes on /clear and /resume) and whether it is mid-turn. Null when it says nothing.
  LiveConversation? Live(SessionDefinition definition, int processId, long startedAtMs) => null;
  // The one conversation this session moved to since it started, read from the AI's
  // transcripts, never one claimed by another session. Null when none or ambiguous.
  string? Discover(SessionRecord session, IReadOnlySet<string> claimed) => null;
  // The newest conversation written in this folder since the session started. Only for a
  // folder no other open terminal of the same AI holds (the Mac's unnamed-continue rule).
  string? Newest(SessionRecord session) => null;
  // False only when the AI certainly has nothing saved under this conversation yet.
  bool CanResume(SessionDefinition definition) => true;
}
public sealed record LiveConversation(string? ConversationId, bool? Busy);

// Only transcripts below the two explicit app-owned homes can move. Auth files,
// global histories, settings, and links are never copied with a conversation.
public sealed partial class ConversationFiles(AppDataRoot root) : IConversationFiles
{
  private string Home(SessionDefinition definition)
  {
    if (!Guid.TryParseExact(definition.AccountHome ?? definition.AccountId, "N", out _)) throw new IOException("Choose an isolated account home.");
    return AccountHomes.Resolve(root, definition.Provider, definition.AccountHome ?? definition.AccountId!,
      Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), StableChannel.IsStable(AppContext.BaseDirectory));
  }
  private static void NoLinks(string path)
  {
    for (var current = new DirectoryInfo(Path.GetDirectoryName(path)!); current is not null; current = current.Parent)
      if (current.Exists && current.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new IOException("A conversation folder cannot be a link.");
    if (File.Exists(path) && File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint)) throw new IOException("A conversation file cannot be a link.");
  }
  private IEnumerable<string> Candidates(SessionDefinition definition)
  {
    var directory = Path.Combine(Home(definition), definition.Provider switch { "claude" => "projects", "codex" => "sessions", "gemini" => Path.Combine(".gemini", "tmp"), _ => throw new IOException("Shells have no saved AI conversation.") });
    NoLinks(Path.Combine(directory, "placeholder"));
    if (!Directory.Exists(directory)) return [];
    var options = new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint, IgnoreInaccessible = false };
    return Directory.EnumerateFiles(directory, definition.Provider == "gemini" ? "session-*.json" : "*.jsonl", options).Take(4097).ToArray();
  }
  private static (string? Id, string? Folder) Identity(string path, string provider)
  {
    NoLinks(path);
    if (new FileInfo(path).Length > 128 * 1024 * 1024) throw new IOException("This conversation is too large to transfer safely.");
    try
    {
      if (provider == "gemini")
      {
        using var json = JsonDocument.Parse(File.ReadAllBytes(path)); var data = json.RootElement;
        return (data.TryGetProperty("sessionId", out var id) ? id.GetString() : null, null);
      }
      using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
      using var reader = new StreamReader(stream);
      for (var count = 0; count < 128 && !reader.EndOfStream; count++)
      {
        var line = reader.ReadLine(); if (line is null || line.Length > 4 * 1024 * 1024) throw new IOException("The conversation metadata is unusable.");
        using var json = JsonDocument.Parse(line); var data = json.RootElement;
        if (provider == "codex" && data.TryGetProperty("type", out var type) && type.GetString() == "session_meta") data = data.GetProperty("payload");
        if (data.TryGetProperty(provider == "claude" ? "sessionId" : "id", out var id) && data.TryGetProperty("cwd", out var cwd)) return (id.GetString(), cwd.GetString());
      }
    }
    catch (JsonException) { throw new IOException("The saved conversation metadata could not be read."); }
    return (null, null);
  }
  private string Locate(SessionDefinition definition)
  {
    var candidates = Candidates(definition).ToArray();
    if (candidates.Length > 4096) throw new IOException("This account has too many transcripts to select safely.");
    var matches = candidates.Where(path => Path.GetFileName(path).Contains(definition.ConversationId ?? "!", StringComparison.OrdinalIgnoreCase))
      .Where(path => Identity(path, definition.Provider).Id == definition.ConversationId).ToArray();
    if (matches.Length != 1) throw new IOException("Choose one saved conversation before switching this account.");
    var metadata = Identity(matches[0], definition.Provider);
    if (metadata.Folder is not null && !Path.GetFullPath(metadata.Folder).Equals(Path.GetFullPath(definition.Cwd), StringComparison.OrdinalIgnoreCase)) throw new IOException("The saved conversation belongs to another folder.");
    return matches[0];
  }
  public string FindConversation(SessionRecord session)
  {
    if (session.Definition.ConversationId is { } saved) { _ = Locate(session.Definition); return saved; }
    // A session without a stored id is matched only when one newly written
    // transcript names this exact working folder. Ambiguity never selects latest.
    var candidates = Candidates(session.Definition).ToArray();
    if (candidates.Length > 4096 || session.Definition.Provider == "gemini") throw new IOException("This session needs its exact saved conversation identity before switching.");
    var matches = candidates.Where(p => File.GetLastWriteTimeUtc(p) >= DateTimeOffset.FromUnixTimeMilliseconds(session.CreatedAt).UtcDateTime)
      .Select(p => Identity(p, session.Definition.Provider)).Where(x => x.Id is not null && x.Folder is not null && Path.GetFullPath(x.Folder).Equals(Path.GetFullPath(session.Definition.Cwd), StringComparison.OrdinalIgnoreCase)).Distinct().ToArray();
    return matches.Length == 1 ? matches[0].Id! : throw new IOException("The saved conversation is missing or ambiguous. Its current account was kept.");
  }
  public string MostRecent(SessionDefinition definition)
  {
    var paths = Candidates(definition).ToArray();
    if (paths.Length > 4096 || definition.Provider == "gemini") throw new IOException("Choose an exact saved conversation for this account.");
    var match = paths.OrderByDescending(File.GetLastWriteTimeUtc).Select(p => Identity(p, definition.Provider))
      .FirstOrDefault(x => x.Id is not null && x.Folder is not null && Path.GetFullPath(x.Folder).Equals(Path.GetFullPath(definition.Cwd), StringComparison.OrdinalIgnoreCase));
    return match.Id ?? throw new IOException("No saved conversation was found for this folder and account.");
  }
  public void Validate(SessionDefinition source, SessionDefinition destination)
  {
    if (source.Provider != destination.Provider || source.ConversationId != destination.ConversationId || source.ConversationId is null) throw new IOException("Choose another account for the same AI to keep its exact conversation.");
    var path = Locate(source); var target = Path.Combine(Home(destination), Path.GetRelativePath(Home(source), path)); NoLinks(target);
    if (File.Exists(target) && !SHA256.HashData(File.ReadAllBytes(path)).SequenceEqual(SHA256.HashData(File.ReadAllBytes(target)))) throw new IOException("The other account already has a different copy of this conversation. Its files were kept.");
  }
  public void Copy(SessionDefinition source, SessionDefinition destination)
  {
    Validate(source, destination);
    var path = Locate(source); var target = Path.Combine(Home(destination), Path.GetRelativePath(Home(source), path));
    if (File.Exists(target)) return;
    Directory.CreateDirectory(Path.GetDirectoryName(target)!); NoLinks(target);
    var temporary = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
    try
    {
      using (var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
      using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { input.CopyTo(output); output.Flush(true); }
      File.Move(temporary, target);
    }
    finally { if (File.Exists(temporary)) File.Delete(temporary); }
  }
}
