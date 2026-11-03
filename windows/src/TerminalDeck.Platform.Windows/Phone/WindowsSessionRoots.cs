using System.Text.Json;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Chats;
using TerminalDeck.Platform.Windows.Chats;

namespace TerminalDeck.Platform.Windows.Phone;

// The worker process behind each live session, read from the worker's identity file,
// so the Activity page can count everything under it as that session.
public static class WindowsSessionRoots
{
  public static IReadOnlyList<ActivitySessionRoot> Read(AppDataRoot root, IEnumerable<(string CreationKey, string SessionId, string Label)> sessions)
  {
    var roots = new List<ActivitySessionRoot>();
    foreach (var (key, sessionId, label) in sessions)
    {
      try
      {
        var identity = JsonSerializer.Deserialize<WorkerIdentity>(File.ReadAllBytes(WorkerPaths.PathFor(root, key, ".identity.json")));
        if (identity is not null && string.Equals(identity.SessionId, sessionId, StringComparison.Ordinal) && identity.Pid > 0)
          roots.Add(new ActivitySessionRoot(identity.Pid, identity.StartedUtcTicks, label));
      }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException) { }
    }
    return roots;
  }
  public static IReadOnlyList<ActivitySessionRoot> ReadChats(AppDataRoot root, IEnumerable<ChatRecord> chats)
  {
    var roots = new List<ActivitySessionRoot>();
    foreach (var chat in chats.Where(c => !c.Ended))
    {
      try
      {
        var identity = JsonSerializer.Deserialize<ChatWorkerIdentity>(File.ReadAllBytes(ChatWorkerPaths.FileFor(root, chat.CreationKey, ".identity.json")));
        if (identity is not null && identity.Key == chat.CreationKey && identity.ChatId == chat.Definition.Id && identity.Pid > 0)
          roots.Add(new(identity.Pid, identity.StartedUtcTicks, chat.Definition.Title));
      }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException) { }
    }
    return roots;
  }

}
