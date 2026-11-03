using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.App.Views.Receiver;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Integration;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;
using TerminalDeck.Platform.Windows;
using TerminalDeck.Platform.Windows.Receiver;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  public IReceiver Receiver { get; private set; } = null!;
  public WindowsReceiverIntake ReceiverIntake { get; private set; } = null!;
  public ReceiverActivation ReceiverActivation { get; private set; } = null!;
  public ReceiverArtifacts Artifacts { get; private set; } = null!;
  public event Action<string>? ReceiverOutcome;
  private ReceiverFiles receiverFiles = null!;
  private FileStream? receiverOwner;
  private readonly object receiverSourceGate = new();
  private W9ReceiverDelivery receiverDelivery = null!;
  private static string LocalSource(IntakeKind kind) => "w9-local-" + kind.ToString().ToLowerInvariant();

  // The shell supplies its awaitable dispatcher. Intake must not subscribe to
  // WinRT clipboard events on an arbitrary thread-pool thread.
  public async Task InitializeReceiverAsync(Func<Func<Task>, Task> onUi)
  {
    if (Receiver is not null) return;
    var stateDirectory = Path.Combine(Root.DirectoryPath, "state"); WindowsPrivateDirectory.Ensure(stateDirectory);
    try { receiverOwner = new(Path.Combine(stateDirectory, "receiver-owner.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
    catch (IOException) { throw new IOException("Receiver is already open in another app using this data folder. Close that app before opening Receiver here."); }
    try
    {
      var protector = new CurrentUserDpapi(Root);
      receiverFiles = new(Root);
      receiverDelivery = new(new ProtectedReceiverState<W9ReceiverReceipts>(new JsonStateStore<byte[]>(Root, "receiver-deliveries"), protector),
        ReceiverDestinations, PrepareReceiverTarget, RecoverReceiverReceiptAsync, DeliverReceiverAsync);
      Receiver = new ReceiverStore(new ProtectedReceiverState<ReceiverState>(new JsonStateStore<byte[]>(Root, "receiver-inbox"), protector), receiverDelivery, normalize: draft => ReceiverSources.NormalizeInternal(draft));
      Receiver.Changed += ReceiverChanged;
      Artifacts = new(new JsonStateStore<ReceiverArtifactState>(Root, "receiver-artifacts"), ReceiverProjectForFolder,
        WindowsArtifactOpener.OpenAsync, SendReceiverArtifactAsync);
      artifactCursorStore = new JsonStateStore<Dictionary<string, long>>(Root, "receiver-artifact-cursors");
      var catalogueVersion = new JsonStateStore<int>(Root, "artifact-catalogue-version");
      var rebuildCatalogue = catalogueVersion.Load() < 2;
      var savedCursors = rebuildCatalogue ? new Dictionary<string, long>() : artifactCursorStore.Load() ?? [];
      if (rebuildCatalogue) artifactCursorStore.Save(savedCursors);
      if (savedCursors.Any(c => !Guid.TryParse(c.Key, out _) || c.Value < 0))
        throw new IOException("The saved file event history could not be read safely.");
      artifactCursors.Clear();
      foreach (var cursor in savedCursors) artifactCursors.Add(cursor.Key, cursor.Value);
      Artifacts.Changed += ReceiverChanged;
      Chats.Changed += RecordChatArtifacts;
      RecordChatArtifacts();
      if (rebuildCatalogue) catalogueVersion.Save(2);
      SeedReceiverSources();
      Projects.Changed += SeedReceiverSources;
      // A local intake belongs to the project selected when it arrives, rather
      // than whichever project happened to be selected during app startup.
      var local = new ReceiverIntakeRouter(Receiver, kind => EnsureReceiverSource(kind, Projects.ActiveProjectId ?? ProjectIdentity.IndependentId));
      var data = new WindowsReceiverData(local, receiverFiles);
      ReceiverIntake = new(Root, local, data, LocalSource(IntakeKind.Clipboard), LocalSource(IntakeKind.Browser), onUi);
      ReceiverActivation = new(data, LocalSource(IntakeKind.Share), LocalSource(IntakeKind.Drop));
      ReceiverIntake.Outcome += ShowReceiverOutcome; ReceiverActivation.Outcome += ShowReceiverOutcome;
      await ReceiverIntake.RestoreAsync();
    }
    catch
    {
      await DisposeReceiverAsync();
      Receiver = null!; ReceiverIntake = null!; ReceiverActivation = null!; Artifacts = null!;
      throw;
    }
  }
  public void RegisterReceiverTools()
  {
    new ReceiverMcp(Receiver, Artifacts, ReceiverIntake, async (item, text, ct) => { var outcome = await ReceiverSources.ReplyAsync(item.Id, text, ct); if (outcome.State != "sent") throw new IOException(outcome.Problem ?? "Reply delivery was not confirmed."); }).Register(Door);
    RegisterReceiverSourceTools();
  }
  public async ValueTask DisposeReceiverAsync()
  {
    DisposeReceiverSources();
    Projects.Changed -= SeedReceiverSources;
    if (Chats is not null) Chats.Changed -= RecordChatArtifacts;
    if (Receiver is not null) Receiver.Changed -= ReceiverChanged;
    if (Artifacts is not null) Artifacts.Changed -= ReceiverChanged;
    try
    {
      if (ReceiverIntake is not null) { ReceiverIntake.Outcome -= ShowReceiverOutcome; await ReceiverIntake.DisposeAsync(); }
      if (ReceiverActivation is not null) ReceiverActivation.Outcome -= ShowReceiverOutcome;
    }
    finally { receiverOwner?.Dispose(); receiverOwner = null; }
  }
  private readonly Dictionary<string, long> artifactCursors = [];
  private IStateStore<Dictionary<string, long>> artifactCursorStore = null!;
  private readonly object artifactCursorGate = new();
  private void RecordChatArtifacts()
  {
    lock (artifactCursorGate)
    {
      foreach (var chat in Chats.List())
      {
        var after = artifactCursors.GetValueOrDefault(chat.Definition.Id);
        var complete = true;
        foreach (var writes in W9ArtifactWrites.Read(chat, after).GroupBy(w => w.Sequence).OrderBy(g => g.Key))
        {
          foreach (var write in writes)
          {
            try
            {
              var full = Path.GetFullPath(write.Path, chat.Definition.Cwd);
              var relative = Path.GetRelativePath(chat.Definition.Cwd, full).Replace('\\', '/');
              RecordReceiverArtifact(chat.Definition.Id, chat.Definition.Cwd, relative, write.At);
            }
            // A rejected path or a file already removed is intentionally absent.
            // A disk/permission failure must leave the event available to retry.
            catch (Exception ex) when (ex is ArgumentException or FileNotFoundException or DirectoryNotFoundException)
            { ShowReceiverOutcome("A produced file is no longer available inside an open project. Its original file was left alone."); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            { ShowReceiverOutcome("A produced file could not be added to Artifacts. Its saved event will be checked again."); complete = false; break; }
          }
          if (!complete || !SaveArtifactCursor(chat.Definition.Id, writes.Key)) { complete = false; break; }
        }
        if (complete && chat.Events.LastOrDefault()?.Sequence is { } through && through > after)
          _ = SaveArtifactCursor(chat.Definition.Id, through);
      }
    }
  }
  private bool SaveArtifactCursor(string chatId, long sequence)
  {
    if (sequence <= artifactCursors.GetValueOrDefault(chatId)) return true;
    var next = new Dictionary<string, long>(artifactCursors) { [chatId] = sequence };
    try
    {
      artifactCursorStore.Save(next); artifactCursors[chatId] = sequence; return true;
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
    { ShowReceiverOutcome("The file event history could not be saved. Artifacts will be checked again."); return false; }
  }
  private void ReceiverChanged() => Changed?.Invoke();
  private void ShowReceiverOutcome(string message) => ReceiverOutcome?.Invoke(message);
  private void SeedReceiverSources()
  {
    try
    {
      foreach (var kind in new[] { IntakeKind.Share, IntakeKind.Drop, IntakeKind.Clipboard, IntakeKind.Browser })
        _ = EnsureReceiverSource(kind, Projects.ActiveProjectId ?? ProjectIdentity.IndependentId);
    }
    catch (Exception ex) when (ex is IOException or ArgumentException)
    { ShowReceiverOutcome("This project's Receiver sources could not be prepared. Review Sources before adding an item."); }
  }
  private string EnsureReceiverSource(IntakeKind kind, string projectId)
  {
    lock (receiverSourceGate)
    {
      var project = Projects.Get(projectId);
      var id = "w9-" + kind.ToString().ToLowerInvariant() + "-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(projectId)));
      if (!Receiver.Sources().Any(s => s.Id == id)) Receiver.SaveSource(new(id, project.Name + " · " + kind, kind, project.Id));
      return id;
    }
  }
  public string ReceiverSourceForSession(string sessionId, IntakeKind kind = IntakeKind.Phone)
  {
    var row = ProjectSessions().FirstOrDefault(s => s.Id == sessionId) ?? throw new ArgumentException("Choose a current session.");
    return EnsureReceiverSource(kind, ReceiverSessionProject(row.Id, row.Folder));
  }
  public ReceiverPhoneIntake CreateReceiverPhoneIntake(Func<ApprovedDevice, string, bool> canSend)
  {
    var phone = new ReceiverIntakeRouter(Receiver, kind => EnsureReceiverSource(kind, Projects.ActiveProjectId ?? ProjectIdentity.IndependentId),
      target => target.Kind == RouteKind.Session && Chats.List().Any(c => c.Definition.Id == target.Id)
        ? target with { Kind = RouteKind.Chat } : target);
    return new(phone, canSend, (_, sessionId) => ReceiverSourceForSession(sessionId));
  }
  public IReadOnlyList<(string Id, string Label)> ReceiverProjectChoices() => Projects.List().Where(p => p.IsOpen).Select(p => (p.Id, p.Name)).ToArray();
  public IReadOnlyList<ArtifactFolder> ReceiverArtifactFolders() => Projects.List().Where(p => p.IsOpen)
    .SelectMany(p => p.Folders.Select(f => new ArtifactFolder(f, p.Name + " · " + Path.GetFileName(f), p.Id))).ToArray();
  private string? ReceiverProjectForFolder(string folder) => Projects.List().Where(p => p.IsOpen)
    .FirstOrDefault(p => p.Folders.Any(f => ProjectPaths.Contains(f, folder)))?.Id;
  private string ReceiverSessionProject(string id, string folder) => Projects.GroupSessions([new(id, "", "", folder, "")]).Single().ProjectId;
  private IReadOnlyList<ReceiverDestination> ReceiverDestinations()
  {
    var rows = new List<ReceiverDestination>();
    foreach (var session in Sessions.Where(s => s.State == SessionState.Running && s.Definition.Provider != "shell" && s.Definition.Purpose is null))
      rows.Add(new(new(RouteKind.Session, session.Definition.Id), session.Definition.Title, ReceiverSessionProject(session.Definition.Id, session.Definition.Cwd)));
    foreach (var chat in Chats.List().Where(c => !c.Ended && c.Definition.Id != Hoot.Read().ChatId))
      rows.Add(new(new(RouteKind.Chat, chat.Definition.Id), chat.Definition.Title + " · Chat", ReceiverSessionProject(chat.Definition.Id, chat.Definition.Cwd)));
    foreach (var project in Projects.List().Where(p => p.IsOpen))
    {
      rows.Add(new(new(RouteKind.NewTask), "New task", project.Id));
      if (Hoot.Read().Settings is not null) rows.Add(new(new(RouteKind.Hoot), "Hoot", project.Id));
    }
    foreach (var agent in Agents.List().Where(a => a.Status == SavedAgentStatus.Active))
    {
      var run = Agents.Runs().Where(r => r.AgentId == agent.Id && r.State == AgentRunState.Running).ToArray();
      if (run.Length == 1 && rows.Any(d => d.Target.Id == run[0].SessionId && d.ProjectId == run[0].ProjectId))
        rows.Add(new(new(RouteKind.Agent, agent.Id), agent.Name + " · Agent", run[0].ProjectId));
    }
    return rows;
  }
  private ReceiverTarget PrepareReceiverTarget(ReceiverItem item, ReceiverTarget target)
  {
    if (target.ThreadKey is not null) throw new ArgumentException("Choose the conversation itself; thread routing is not connected.");
    if (target.Kind == RouteKind.NewTask && ReceiverMessage(item).Length > 40000)
      throw new ArgumentException("This item's quoted content is too long for a task. Choose a chat or session.");
    if (target.Kind != RouteKind.Agent) return target;
    var runs = Agents.Runs().Where(r => r.AgentId == target.Id && r.ProjectId == item.ProjectId && r.State == AgentRunState.Running).ToArray();
    if (runs.Length != 1) throw new ArgumentException("Choose an agent with one running session in this project.");
    return new(runs[0].Mode == "chat" ? RouteKind.Chat : RouteKind.Session, runs[0].SessionId);
  }
  private async ValueTask<DeliveryReceipt?> RecoverReceiverReceiptAsync(ReceiverItem item, ReceiverTarget target, string id, CancellationToken ct)
  {
    if (target.Kind == RouteKind.Chat)
    {
      await Chats.RefreshAsync(ct);
      var message = Chats.Get(target.Id!).Messages.FirstOrDefault(m => m.ClientId == id);
      if (message is not null && message.Text != ReceiverMessage(item)) throw new IOException("The chat receipt belongs to different content.");
      if (message?.State is ChatMessageState.Queued or ChatMessageState.Sent) return new("chat:" + target.Id + ":" + id, message.State == ChatMessageState.Queued ? "Saved in the chat's queue." : "Delivered to the chat.");
      if (message is not null) throw new IOException("The chat has an unconfirmed or removed copy. Check it before sending again.");
    }
    if (target.Kind == RouteKind.Hoot && Hoot.Read().Turns.FirstOrDefault(t => t.Id == id) is { } turn)
    {
      if (turn.Text != ReceiverMessage(item)) throw new IOException("The Hoot receipt belongs to different content.");
      if (turn.State is HootTurnState.Uncertain or HootTurnState.Dispatching)
        throw new IOException("Hoot has an unconfirmed copy. Check its conversation before sending again.");
      return new("hoot:" + id, "Saved in Hoot's conversation.");
    }
    if (target.Kind == RouteKind.NewTask)
    {
      foreach (var archived in new[] { false, true }) foreach (var trash in new[] { false, true })
      {
        var task = Tasks.List(new(ProjectId: item.ProjectId, Status: "all", Archived: archived, Trash: trash)).FirstOrDefault(t => t.Connected == new ConnectedTaskLink("receiver", id));
        if (task is not null) return new(task.Id, "Saved as a task.");
      }
    }
    return null;
  }
  private async ValueTask<DeliveryReceipt> DeliverReceiverAsync(ReceiverItem item, ReceiverTarget target, string id, CancellationToken ct)
  {
    var recovered = await RecoverReceiverReceiptAsync(item, target, id, ct);
    if (recovered is not null) return recovered;
    if (!ReceiverDestinations().Any(d => d.ProjectId == item.ProjectId && d.Target == target))
      throw new ArgumentException("This destination is no longer available in the item's project.");
    var text = ReceiverMessage(item);
    switch (target.Kind)
    {
      case RouteKind.Chat:
        await Chats.SendAsync(target.Id!, id, text, cancellationToken: ct);
        return await RecoverReceiverReceiptAsync(item, target, id, ct) ?? throw new IOException("The chat did not confirm this message.");
      case RouteKind.Session:
        var reply = await Keeper.WriteAsync(target.Id!, Encoding.UTF8.GetBytes("\u001b[200~" + text + "\u001b[201~\r"), ct);
        if (reply.Success != true) throw new IOException("The session did not acknowledge this message.");
        return new("session:" + target.Id + ":" + id, "Delivered to the session.");
      case RouteKind.NewTask:
        var task = Tasks.Create(new(item.Title, text, item.ProjectId, Projects.Get(item.ProjectId).HomeFolder), TaskActor.Owner, new("receiver", id));
        return new(task.Id, "Saved as a task.");
      case RouteKind.Hoot:
        await Hoot.SayAsync(id, text, new HootSource("session", item.Id, "From Receiver: " + item.Title), ct);
        return await RecoverReceiverReceiptAsync(item, target, id, ct) ?? throw new IOException("Hoot did not save this message.");
      default: throw new ArgumentException("Choose a connected destination.");
    }
  }
  private string ReceiverMessage(ReceiverItem item)
  {
    var attachments = item.Files.Select(f =>
    {
      using var input = receiverFiles.Open(f);
      if (input.Length != f.Bytes) throw new IOException("A saved attachment changed. Keep this item for review.");
      if (f.Sha256 is not null && !string.Equals(Convert.ToHexStringLower(SHA256.HashData(input)), f.Sha256, StringComparison.OrdinalIgnoreCase))
        throw new IOException("A saved attachment changed. Keep this item for review.");
      return new { f.Name, f.MediaType, f.Bytes, path = Path.Combine(Root.DirectoryPath, "receiver", "files", f.Id) };
    }).ToArray();
    return ReceiverStore.OutsideNote + "\nProject: " + item.ProjectId + "\nReceiver item: " + item.Id + "\n\n" +
      JsonSerializer.Serialize(new { item.Title, item.Text, item.Url, attachments });
  }
  private async ValueTask SendReceiverArtifactAsync(ReceiverArtifact artifact, ReceiverTarget target, CancellationToken ct)
  {
    if (target.Kind is not (RouteKind.Session or RouteKind.Hoot)) throw new ArgumentException("Choose a session or Hoot for this file.");
    var path = ReceiverArtifacts.SafePath(artifact.Cwd, artifact.RelPath);
    var source = EnsureReceiverSource(IntakeKind.Hoot, artifact.ProjectId);
    var row = Receiver.Receive(new(source, "File: " + Path.GetFileName(path), "A session produced this file: " + path,
      ExternalId: "artifact-" + artifact.Id + "-" + Guid.NewGuid().ToString("N")));
    var outcome = await Receiver.RouteAsync(row.Id, target, ct);
    if (outcome.Status != InboxStatus.Delivered) throw new IOException("The file send was not confirmed. Review it in Receiver.");
  }
  // Called only by a trusted session write event, never by a folder scan or an
  // MCP caller's assertion that a file was produced by a session.
  public void RecordReceiverArtifact(string sessionId, string cwd, string relative, DateTimeOffset producedAt)
  {
    var session = ProjectSessions().SingleOrDefault(s => s.Id == sessionId) ?? throw new ArgumentException("The producing session is no longer known.");
    if (!ProjectPaths.Equal(session.Folder, cwd)) throw new ArgumentException("The output folder does not match its producing session.");
    Artifacts.Record(cwd, relative, sessionId, producedAt);
  }
  private sealed class ReceiverIntakeRouter(IReceiver inner, Func<IntakeKind, string> source, Func<ReceiverTarget, ReceiverTarget>? resolveTarget = null) : IReceiver
  {
    public event Action? Changed { add => inner.Changed += value; remove => inner.Changed -= value; }
    public ReceiverItem Receive(ReceiverDraft draft)
    {
      foreach (var kind in new[] { IntakeKind.Share, IntakeKind.Drop, IntakeKind.Clipboard, IntakeKind.Browser })
        if (draft.SourceId == LocalSource(kind)) return inner.Receive(draft with { SourceId = source(kind) });
      return inner.Receive(draft);
    }
    public IReadOnlyList<ReceiverSource> Sources() => inner.Sources();
    public IReadOnlyList<ReceiverRule> Rules() => inner.Rules();
    public IReadOnlyList<ReceiverItem> Items(string? source = null, InboxStatus? status = null, string query = "", int limit = 200) => inner.Items(source, status, query, limit);
    public ReceiverItem Item(string id) => inner.Item(id);
    public IReadOnlyList<ReceiverDestination> Destinations(string projectId) => inner.Destinations(projectId);
    public ReceiverDecision Test(ReceiverDraft draft, ReceiverRule? rule = null) => inner.Test(draft, rule);
    public void SaveSource(ReceiverSource row) => inner.SaveSource(row);
    public void RemoveSource(string id) => inner.RemoveSource(id);
    public void SaveRule(ReceiverRule row) => inner.SaveRule(row);
    public void RemoveRule(string id) => inner.RemoveRule(id);
    public void MoveRule(string id, int index) => inner.MoveRule(id, index);
    public ValueTask<ReceiverItem> RouteAsync(string id, ReceiverTarget target, CancellationToken ct = default) => inner.RouteAsync(id, resolveTarget?.Invoke(target) ?? target, ct);
    public void Hold(string id, ReceiverTarget target) => inner.Hold(id, resolveTarget?.Invoke(target) ?? target);
    public void Dismiss(string id) => inner.Dismiss(id);
  }
}
