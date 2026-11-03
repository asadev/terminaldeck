using System.Text.Json;
using TerminalDeck.Core.Code;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Chats;

public sealed record ChatWorktree(string Id, string ParentSessionId, string? SessionId, string Project, string Folder, string Branch);
public sealed record ChatWorktreeState(ChatWorktree[] Entries);
public sealed record ChatBranchResult(ChatRecord Chat, string ParentSessionId, bool Forked, bool Confirmed, bool Worktree, string? Warning = null);

public sealed class ChatBranchService(AppDataRoot root, IStateStore<ChatWorktreeState> store, Func<IChatSessions> sessions,
  Func<ChatRecord, string?, CancellationToken, ValueTask<string>> codexFork, Func<IReadOnlyList<string>> liveFolders, ICodeProcessRunner? runner = null)
{
  private readonly ICodeProcessRunner process = runner ?? new CodeProcessRunner();
  private readonly SemaphoreSlim gate = new(1, 1);
  private string WorktreeRoot => Path.Combine(root.DirectoryPath, "chat-worktrees");
  private async Task<string> Git(string cwd, CancellationToken ct, params string[] arguments)
  {
    var result = await process.RunAsync("git", ["-C", cwd, .. arguments], cwd, TimeSpan.FromSeconds(30), ct);
    return result.Ok ? result.Output.Trim() : throw new IOException("Git could not complete this worktree operation. Check that the project has a commit and the worktree is available.");
  }
  private ChatWorktreeState Read() => store.Load() ?? new([]);
  private void Save(ChatWorktree entry) => store.Save(new(Read().Entries.Where(e => e.Id != entry.Id).Append(entry).TakeLast(200).ToArray()));
  public IReadOnlyList<ChatWorktree> Worktrees(string parent) => Read().Entries.Where(e => e.ParentSessionId == parent || e.SessionId == parent).ToArray();
  public static string? ProviderTurn(ChatRecord parent, string? through)
  {
    if (through is null or "") return null;
    if (parent.Definition.Provider != "codex") throw new InvalidOperationException("This provider forks the whole conversation. Earlier-turn forks are offered by Codex only.");
    return parent.Events.LastOrDefault(e => e.Kind == "providerTurnComplete" && (e.Id == through || e.ClientId == through))?.Id is { Length: > 0 and <= 512 } id ? id : throw new InvalidOperationException("Choose a finished turn whose provider turn ID was recorded. Older chats can still fork at their latest point.");
  }
  public async ValueTask<ChatBranchResult> CreateAsync(string parentId, bool fork, bool worktree, string? through, string? title, CancellationToken ct, Func<CancellationToken, ValueTask>? authorize = null)
  {
    await gate.WaitAsync(ct); ChatWorktree? made = null; ChatRecord? created = null;
    try
    {
      var parent = await sessions().ReadAsync(parentId, ct);
      if (authorize is not null) await authorize(ct);
      if (fork && parent.Definition.Provider == "gemini") throw new InvalidOperationException("This Gemini chat protocol does not offer conversation forks. Start a fresh chat in a worktree instead.");
      if (fork && parent.Busy) throw new InvalidOperationException("Wait for this answer to finish before forking its conversation.");
      if (fork && string.IsNullOrEmpty(parent.ConversationId)) throw new InvalidOperationException("This chat has no provider conversation identity yet.");
      if (fork && worktree && parent.Definition.Provider != "codex") throw new InvalidOperationException("Only Codex can fork a conversation into another folder. Start a fresh worktree chat for this provider instead.");
      var providerTurn = ProviderTurn(parent, through); var conversation = fork ? parent.Definition.Provider == "codex" ? await codexFork(parent, providerTurn, ct) : parent.ConversationId : null;
      if (fork && parent.Definition.Provider == "codex" && (string.IsNullOrEmpty(conversation) || conversation == parent.ConversationId)) throw new IOException("The provider did not confirm a new conversation. The original chat was kept.");
      var folder = parent.Definition.Cwd;
      if (worktree)
      {
        var project = await Git(folder, ct, "rev-parse", "--show-toplevel"); await Git(project, ct, "rev-parse", "--verify", "HEAD");
        var id = Guid.NewGuid().ToString("N"); folder = Path.Combine(WorktreeRoot, id); Directory.CreateDirectory(WorktreeRoot);
        made = new(id, parentId, null, project, folder, "deck-chat/" + id[..12]); Save(made);
        if (authorize is not null) await authorize(ct);
        await Git(project, ct, "worktree", "add", "-b", "deck-chat/" + id[..12], folder, "HEAD");
      }
      var name = string.IsNullOrWhiteSpace(title) ? (fork ? "Fork · " : "Worktree · ") + parent.Definition.Title : title.Trim(); if (name.Length > 120) name = name[..(char.IsHighSurrogate(name[119]) ? 119 : 120)];
      var definition = parent.Definition with { Id = Guid.NewGuid().ToString(), Cwd = folder, Title = name, ForkSession = fork && parent.Definition.Provider == "claude" };
      if (authorize is not null) await authorize(ct);
      created = await sessions().CreateAsync(definition, conversation, ct);
      if (made is not null) Save(made with { SessionId = created.Definition.Id });
      var confirmed = !fork || parent.Definition.Provider == "codex";
      return new(created, parentId, fork, confirmed, worktree, confirmed ? null : "Claude will confirm the new conversation identity when this fork first starts. The original conversation remains separate.");
    }
    catch
    {
      if (made is not null && created is null)
      {
        try { if (!Directory.Exists(made.Folder)) store.Save(new(Read().Entries.Where(e => e.Id != made.Id).ToArray()));
          else if ((await Git(made.Folder, CancellationToken.None, "status", "--porcelain", "--untracked-files=all")).Length == 0) { await Git(made.Project, CancellationToken.None, "worktree", "remove", made.Folder); store.Save(new(Read().Entries.Where(e => e.Id != made.Id).ToArray())); } } catch (Exception ex) when (ex is IOException or InvalidOperationException) { }
      }
      throw;
    }
    finally { gate.Release(); }
  }
  private ChatWorktree Require(string parent, string target)
  {
    var entry = Read().Entries.FirstOrDefault(e => e.SessionId == target || e.Id == target) ?? throw new ArgumentException("Choose an app-created chat worktree.");
    if (entry.SessionId != parent && entry.ParentSessionId != parent) throw new UnauthorizedAccessException("That worktree belongs to another chat.");
    if (!Guid.TryParseExact(entry.Id, "N", out _) || !ProjectPaths.Equal(Path.Combine(WorktreeRoot, entry.Id), entry.Folder) || entry.Branch != "deck-chat/" + entry.Id[..12] || !ProjectPaths.Contains(WorktreeRoot, entry.Folder)) throw new IOException("The saved worktree is outside this app's private worktree folder.");
    for (var directory = new DirectoryInfo(entry.Folder); directory is not null && ProjectPaths.Contains(WorktreeRoot, directory.FullName); directory = directory.Parent)
      if (directory.Exists && directory.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new IOException("A worktree cannot be a linked folder.");
    return entry;
  }
  public async ValueTask<object> StatusAsync(string parent, string target, CancellationToken ct)
  {
    var entry = Require(parent, target); var changes = await Git(entry.Folder, ct, "status", "--porcelain", "--untracked-files=all");
    return new { entry.SessionId, entry.ParentSessionId, entry.Folder, entry.Branch, dirty = changes.Length > 0, active = liveFolders().Any(f => ProjectPaths.Contains(entry.Folder, f)), changes };
  }
  public async ValueTask RemoveAsync(string parent, string target, CancellationToken ct, Func<CancellationToken, ValueTask>? authorize = null)
  {
    await gate.WaitAsync(ct);
    try
    {
      var entry = Require(parent, target);
      if (liveFolders().Any(f => ProjectPaths.Contains(entry.Folder, f))) throw new InvalidOperationException("A session is still using this worktree. End it before cleanup.");
      if ((await Git(entry.Folder, ct, "status", "--porcelain", "--untracked-files=all")).Length > 0) throw new InvalidOperationException("This worktree has uncommitted changes. Its files and branch were kept.");
      var source = await Git(entry.Project, ct, "rev-parse", "--path-format=absolute", "--git-common-dir"); var destination = await Git(entry.Folder, ct, "rev-parse", "--path-format=absolute", "--git-common-dir");
      if (!ProjectPaths.Equal(source, destination)) throw new IOException("This folder no longer belongs to the recorded repository.");
      if (authorize is not null) await authorize(ct);
      await Git(entry.Project, ct, "worktree", "remove", entry.Folder); store.Save(new(Read().Entries.Where(e => e.Id != entry.Id).ToArray()));
    }
    finally { gate.Release(); }
  }
}
