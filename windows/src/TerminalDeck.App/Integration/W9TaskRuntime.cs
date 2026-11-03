using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Integration;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  public TaskService Tasks { get; private set; } = null!;
  public ConnectedTasksService ConnectedTasks { get; private set; } = null!;
  public TaskPhoneGrants TaskGrants { get; private set; } = null!;
  public string TaskMachineIdentity => Environment.MachineName + ":" + Root.NamespaceId;
  public string? TaskProblem { get; private set; }
  private FileStream? taskOwner;
  private readonly CancellationTokenSource taskLifetime = new();
  private readonly object taskWatchGate = new();
  private IDisposable? taskChanges;
  private W9TaskRunner? taskRunner;
  private Task taskDelivery = Task.CompletedTask;

  // Only attended assignment and mention authority live in the window.
  // Keeper owns run watches and result posting, using the shared task ledger.
  public void InitializeTaskRuntime()
  {
    if (Tasks is not null) return;
    var directory = Path.Combine(Root.DirectoryPath, "state"); WindowsPrivateDirectory.Ensure(directory);
    try { taskOwner = new(Path.Combine(directory, "tasks-owner.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
    catch (IOException) { throw new IOException("Tasks are already open in another app using this data folder. Close that app before opening Tasks here."); }
    try
    {
      TaskGrants = new(new JsonStateStore<TaskPhoneGrantState>(Root, "phone-task-grants"), Projects);
      ConnectedTasks = new(new JsonStateStore<ConnectedTasksState>(Root, "connected-tasks"), new ManagedConnectedTaskGateway(Mcp), Projects);
      taskRunner = new(new AgentTaskRunner(Agents, Projects, SendTaskNotificationAsync), Hoot, taskLifetime.Token, coordinateResults: false);
      Tasks = new(TaskStore.At(Root), Projects, ResolveTaskRecipient, taskRunner, new TaskBriefFiles(Root), recoverStarts: false);
      taskRunner.Failed += TaskFailure;
      Tasks.Changed += TaskStateChanged; ConnectedTasks.Changed += TaskStateChanged;
      Chats.Changed += TaskSessionsChanged; Hoot.Changed += TaskHootChanged;
      taskChanges = Services.TaskCoordinatorHost.Observe(Root, TaskStateChanged);
      TaskStateChanged(); TaskSessionsChanged();
    }
    catch { taskOwner.Dispose(); taskOwner = null; throw; }
  }
  public void RegisterTaskTools() => new TasksMcp(Tasks, Projects, TaskMachineIdentity, ResolveTaskRecipient,
    ConnectedTasks, TaskSessionProject).Register(Door);
  private string? TaskSessionProject(string id) => Projects.GroupSessions(ProjectSessions()).FirstOrDefault(g => g.Sessions.Any(s => s.Id == id))?.ProjectId;
  public TaskRecipient? ResolveTaskRecipient(string id)
  {
    var state = Hoot.Read();
    if (id == "hoot" || state.ChatId is { } chat && id == "session:" + chat)
      return state.Settings is null ? null : new(id, "Hoot", "hoot", state.ChatId, "hoot");
    var target = TaskRecipients.Resolve(id, Agents, Projects, () => ProjectSessions().Where(TaskRecipients.IsNotificationChat).ToArray());
    return target?.SessionId is { } session && session == state.ChatId ? target with { Identity = "hoot", Kind = "hoot" } : target;
  }
  public IReadOnlyList<TaskRecipient> TaskPeople()
  {
    var ids = Agents.List().Where(a => a.Status == SavedAgentStatus.Active).Select(a => a.Id)
      .Concat(Projects.List().Where(p => p.Lead is not null).Select(p => "lead:" + p.Id))
      .Concat(ProjectSessions().Where(TaskRecipients.IsNotificationChat).Select(s => "session:" + s.Id))
      .Append("hoot");
    return ids.Select(ResolveTaskRecipient).OfType<TaskRecipient>().DistinctBy(p => p.Id).ToArray();
  }
  public void RequireTaskProjectRemovable(string id)
  {
    if (ConnectedTasks.Systems().Any(s => s.ProjectId == id) ||
      new[] { false, true }.Any(archive => new[] { false, true }.Any(trash => Tasks.List(new(ProjectId: id, Status: "all", Archived: archive, Trash: trash)).Count > 0)))
      throw new InvalidOperationException("This project still owns tasks or connected task systems. Keep it in the project list.");
  }
  private void TaskFailure(string message) { TaskProblem = message; Changed?.Invoke(); }
  private void TaskHootChanged(HootState state) => TaskSessionsChanged();
  private void TaskStateChanged()
  {
    if (!taskLifetime.IsCancellationRequested) Changed?.Invoke();
  }
  public void TaskSessionsChanged()
  {
    if (Tasks is null || taskLifetime.IsCancellationRequested) return;
    lock (taskWatchGate) if (taskDelivery.IsCompleted) taskDelivery = DeliverTaskMentionsAsync();
  }
  private async Task DeliverTaskMentionsAsync()
  {
    try
    {
      foreach (var id in Tasks.Mentions().Where(m => !m.Delivered).Select(m => m.TaskId).Distinct())
        await Tasks.DeliverMentionsAsync(id, taskLifetime.Token);
    }
    catch (OperationCanceledException) when (taskLifetime.IsCancellationRequested) { }
    catch (Exception ex) when (ex is not OutOfMemoryException) { TaskFailure("A task mention is still waiting. Open the task to check its delivery."); }
  }
  private ValueTask SendTaskNotificationAsync(string id, string text, CancellationToken ct) =>
    TaskNotificationSink.SendAsync(id, text, candidate => candidate == Hoot.Read().ChatId ||
      Chats.List().Any(c => c.Definition.Id == candidate && !c.Ended), SendStructuredTaskNotificationAsync, ct);
  private async ValueTask SendStructuredTaskNotificationAsync(string id, string text, CancellationToken ct)
  {
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(75));
    var token = deadline.Token;
    var clientId = W9TaskRunner.NotificationClientId(id, text);
    if (id == Hoot.Read().ChatId)
    {
      var receipt = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
      void Observe(HootState state)
      {
        var turn = state.Turns.FirstOrDefault(t => t.Id == clientId);
        if (turn?.State is HootTurnState.Running or HootTurnState.Finished) receipt.TrySetResult();
        if (turn?.State is HootTurnState.Uncertain or HootTurnState.Failed or HootTurnState.Stopped)
          receipt.TrySetException(new IOException("Hoot did not confirm this task notification."));
      }
      Hoot.Changed += Observe;
      try
      {
        await Hoot.BackgroundTurnAsync(clientId, "background", "tasks", "Task mention", text, cancellationToken: token);
        Observe(Hoot.Read()); await receipt.Task.WaitAsync(token);
      }
      finally { Hoot.Changed -= Observe; }
    }
    else if (Chats.List().Any(c => c.Definition.Id == id))
    {
      await Chats.SendAsync(id, clientId, text, cancellationToken: token);
      await foreach (var chat in Chats.WatchAsync(id, token))
      {
        var message = chat.Messages.FirstOrDefault(m => m.ClientId == clientId);
        if (message?.State == ChatMessageState.Sent) return;
        if (chat.Ended || message?.State is ChatMessageState.Failed or ChatMessageState.Uncertain or ChatMessageState.Removed)
          throw new IOException("The chat did not confirm this task notification.");
      }
      throw new IOException("The task notification needs to reconnect.");
    }
    else throw new InvalidOperationException("Task mentions can only be sent to a running agent chat. Terminal sessions cannot receive automatic task input.");
  }
  public async ValueTask DisposeTaskRuntimeAsync()
  {
    if (Tasks is null) return;
    Tasks.Changed -= TaskStateChanged; ConnectedTasks.Changed -= TaskStateChanged;
    Chats.Changed -= TaskSessionsChanged; Hoot.Changed -= TaskHootChanged;
    if (taskRunner is not null) taskRunner.Failed -= TaskFailure;
    taskLifetime.Cancel(); taskChanges?.Dispose();
    Task delivery; lock (taskWatchGate) delivery = taskDelivery;
    await delivery;
    if (taskRunner is not null) await taskRunner.FinishPendingWritesAsync();
    taskOwner?.Dispose(); taskOwner = null;
  }
}
