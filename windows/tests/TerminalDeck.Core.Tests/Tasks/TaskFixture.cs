using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

internal sealed class MemoryStore<T> : IStateStore<T>
{
  public T? State;
  public bool Fail;
  public T? Load() => State;
  public void Save(T state) { if (Fail) throw new IOException("Synthetic disk failure."); State = state; }
}
internal sealed class TaskFolders : IProjectFolders
{
  public string RequireFolder(string folder) => ProjectPaths.Normalize(folder);
  public IReadOnlyList<ProjectFolder> Browse(string folder, bool showHidden) => [];
}
internal sealed class FakeTaskRunner : ITaskRunner
{
  public int Starts;
  public bool FailBefore;
  public bool FailAfter;
  public bool FailNotify;
  public TaskLaunch? Launch;
  public List<(string Session, string Text)> Notifications = [];
  public TaskCompletionSource? Hold;
  public Action<string>? AfterPrepared;
  public TaskCompletionSource Prepared = new(TaskCreationOptions.RunContinuationsAsynchronously);
  public bool CanStart(string mode) => mode is "terminal" or "chat";
  public async ValueTask<string> StartAsync(TaskLaunch launch, Func<TaskPreparedSession, CancellationToken, ValueTask> prepared, CancellationToken ct)
  {
    Starts++; Launch = launch;
    if (FailBefore) throw new IOException("Synthetic protected driver error.");
    var session = "session-" + Starts;
    await prepared(new(session, launch.Task.ProjectId, launch.Task.Folder, "account-one", launch.AgentId), ct);
    Prepared.TrySetResult();
    AfterPrepared?.Invoke(session);
    if (Hold is not null) await Hold.Task.WaitAsync(ct);
    if (FailAfter) throw new IOException("Synthetic protected driver error.");
    return session;
  }
  public ValueTask NotifyAsync(string sessionId, string text, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    if (FailNotify) throw new IOException("Synthetic protected delivery error.");
    Notifications.Add((sessionId, text)); return ValueTask.CompletedTask;
  }
}
internal sealed class FakeBriefFiles : ITaskBriefFiles
{
  public Dictionary<string, string> Text = [];
  public Action? BeforeSave;
  public string Save(string taskId, string runId, string text) { BeforeSave?.Invoke(); var path = "C:/Scratch/task-briefs/" + runId + ".txt"; Text[path] = text; return path; }
}
internal sealed class TaskFixture
{
  public MemoryStore<TasksState> Persistence = new();
  public IProjects Projects = new ProjectService(new MemoryStore<ProjectState>(), new TaskFolders());
  public FakeTaskRunner Runner = new();
  public FakeBriefFiles Files = new();
  public Dictionary<string, TaskRecipient> People = new() { ["reviewer"] = new("reviewer", "Reviewer", "agent", "existing-session"), ["session:existing-session"] = new("session:existing-session", "Existing session", "agent", "existing-session") };
  public TaskService Tasks;
  public TaskFixture()
  {
    Projects.Save(new("sample", "Sample project", ["C:/Work/Sample"])); Projects.Save(new("other", "Other project", ["C:/Work/Other"]));
    Tasks = Open();
  }
  public TaskService Open() => new(new TaskStore(Persistence), Projects, id => People.GetValueOrDefault(id), Runner, Files);
  public DeckTask Create(string title = "Check the task", string? due = null) => Tasks.Create(new(title, "Read the supplied files and report what changed.", "sample", DueDate: due), TaskActor.Owner);
}
