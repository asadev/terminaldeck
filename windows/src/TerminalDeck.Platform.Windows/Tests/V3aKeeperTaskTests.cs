using System.Diagnostics;
using System.Text;
using System.Text.Json;
using TerminalDeck.App.Services;
using TerminalDeck.Core;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class V3aKeeperTaskTests
{
  private static string Executable => Environment.GetEnvironmentVariable("TD_KEEPER_EXE") ?? throw new InvalidOperationException("Choose the scratch Keeper executable.");
  private static AppDataRoot Scratch() => AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-v3a-continuity-" + Guid.NewGuid().ToString("N"), "data"));
  private static async Task Until(Func<bool> ready, CancellationToken ct)
  { while (!ready()) await Task.Delay(50, ct); }
  private static async Task StopSupervisor(AppDataRoot root)
  {
    var path = Path.Combine(root.DirectoryPath, "keeper", "supervisor.identity.json");
    if (!File.Exists(path)) return;
    using var identity = JsonDocument.Parse(File.ReadAllBytes(path));
    if (identity.RootElement.GetProperty("Pid").GetInt32() == Environment.ProcessId) return;
    try
    {
      using var process = Process.GetProcessById(identity.RootElement.GetProperty("Pid").GetInt32());
      Assert.Equal(identity.RootElement.GetProperty("StartedUtcTicks").GetInt64(), process.StartTime.ToUniversalTime().Ticks);
      process.Kill(); await process.WaitForExitAsync();
    }
    catch (ArgumentException) { }
  }
  private static async Task Clean(AppDataRoot root)
  {
    await StopSupervisor(root);
    var workers = WorkerPaths.DirectoryFor(root);
    if (Directory.Exists(workers))
      foreach (var path in Directory.GetFiles(workers, "*.identity.json"))
      {
        var identity = JsonSerializer.Deserialize<WorkerIdentity>(File.ReadAllBytes(path))!;
        try
        {
          using var process = Process.GetProcessById(identity.Pid);
          if (process.StartTime.ToUniversalTime().Ticks == identity.StartedUtcTicks)
          { process.Kill(); await process.WaitForExitAsync(); }
        }
        catch (ArgumentException) { }
      }
    await new WindowsCredentialStore(root).DeleteAsync($"{Brand.Name}/{root.NamespaceId}/keeper/auth-v2");
    // A completed listener can still be releasing its last directory handle.
    for (var attempt = 0; ; attempt++)
      try { Directory.Delete(Path.GetDirectoryName(root.DirectoryPath)!, true); break; }
      catch (IOException) when (attempt < 20) { await Task.Delay(100); }
  }
  private static ProjectService Projects(AppDataRoot root)
  {
    var projects = new ProjectService(new JsonStateStore<ProjectState>(root, "projects"), new LocalProjectFolders(root));
    var project = Path.Combine(Path.GetDirectoryName(root.DirectoryPath)!, "project"); Directory.CreateDirectory(project);
    projects.Save(new("sample", "Scratch task project", [project])); return projects;
  }
  private sealed class Runner(KeeperClient keeper) : ITaskRunner
  {
    public int Starts;
    public bool CanStart(string mode) => true;
    public async ValueTask<string> StartAsync(TaskLaunch launch, Func<TaskPreparedSession, CancellationToken, ValueTask> prepared, CancellationToken ct)
    {
      Starts++; var id = Guid.NewGuid().ToString();
      await prepared(new(id, launch.Task.ProjectId, launch.Task.Folder, "scratch", "fixture"), ct);
      await keeper.CreateAsync(new(id, "shell", launch.Task.Folder, "Owned task continuity fixture"), ct); return id;
    }
    public ValueTask NotifyAsync(string id, string text, CancellationToken ct) => throw new InvalidOperationException("No automatic input is allowed in this proof.");
  }
  [Fact(Timeout = 90000)]
  public async Task WindowReopenAndAbruptKeeperRestartKeepOneRunAndOneWorker()
  {
    var root = Scratch(); WindowsPrivateDirectory.Ensure(root.DirectoryPath);
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(75)); SessionRecord? row = null;
    try
    {
      var projects = Projects(root); var keeper = await KeeperConnection.AttachAsync(root, Executable, timeout.Token);
      var runner = new Runner(keeper);
      TaskService Open() => new(TaskStore.At(root), projects, _ => new("fixture", "Fixture", "agent", null), runner, recoverStarts: false);
      var foreground = Open(); var task = foreground.Create(new("Scratch continuity", ProjectId: "sample"), TaskActor.Owner);
      await foreground.AssignAsync(task.Id, "fixture", TaskActor.Owner, "terminal", timeout.Token);
      var run = Assert.Single(foreground.Runs()); row = (await keeper.ListAsync(timeout.Token)).Sessions!.Single();
      var reopened = Open(); Assert.Equal(run, Assert.Single(reopened.Runs()));
      await Assert.ThrowsAsync<InvalidOperationException>(async () => await reopened.AssignAsync(task.Id, "fixture", TaskActor.Owner, "terminal", timeout.Token));
      var workerIdentity = File.ReadAllBytes(WorkerPaths.PathFor(root, row.CreationKey, ".identity.json"));
      await StopSupervisor(root);
      keeper = await KeeperConnection.AttachAsync(root, Executable, timeout.Token);
      Assert.Equal(workerIdentity, File.ReadAllBytes(WorkerPaths.PathFor(root, row.CreationKey, ".identity.json")));
      Assert.Equal(row.CreationKey, (await keeper.ListAsync(timeout.Token)).Sessions!.Single().CreationKey);
      // No foreground observer is running. Keeper must post the exit itself.
      await keeper.WriteAsync(row.Definition.Id, Encoding.UTF8.GetBytes("exit\r"), timeout.Token);
      try { await Until(() => Open().Runs()[0].State == TaskRunState.Ended, timeout.Token); }
      catch (OperationCanceledException)
      { throw new InvalidOperationException("Terminal run stayed " + Open().Runs()[0].State + "; coordinator lease: " + File.Exists(Path.Combine(root.DirectoryPath, "keeper", "task-coordinator.lock"))); }
      var final = Open(); Assert.Equal(run.Id, Assert.Single(final.Runs()).Id); Assert.Equal(1, runner.Starts);
      Assert.Single(Directory.GetFiles(WorkerPaths.DirectoryFor(root), "*.identity.json"));
      Assert.Single(final.Get(task.Id).Activity, a => a.Text.Contains("session ended", StringComparison.Ordinal));
    }
    finally
    {
      if (row is not null)
      {
        var adapter = new DurableSessionProcessKeeper(root, Executable, new(root, "unused-tools"), KeeperCredentials.GetOrCreate(root));
        try { await adapter.QuitAsync(row.CreationKey, CancellationToken.None); } catch (Exception ex) when (ex is IOException or TimeoutException) { }
      }
      await Clean(root);
    }
  }
  [Fact(Timeout = 90000)]
  public async Task FinishedHootResultSurvivesKeeperRestartAndPhoneRefusesACachedDeskWhileDown()
  {
    var root = Scratch(); WindowsPrivateDirectory.Ensure(root.DirectoryPath);
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(75));
    using var serving = new CancellationTokenSource(); Task? keeperRun = null;
    try
    {
      var projects = Projects(root); var store = TaskStore.At(root);
      var tasks = new TaskService(store, projects, _ => null, recoverStarts: false);
      var task = tasks.Create(new("Saved Hoot result", ProjectId: "sample"), TaskActor.Owner); var id = Guid.NewGuid().ToString();
      store.Change(s => (s with { Tasks = [task with { CurrentRunId = id, Status = "Working on it" }],
        Runs = [new(id, task.Id, "hoot", task.Folder, "chat", TaskRunState.Working, DateTimeOffset.UtcNow, "hoot-task:" + id)] }, true));
      HootStorage.At(root).Save(HootState.Empty with { Turns = [new(id, "Synthetic saved brief", new("task", task.Id), HootTurnState.Finished, DateTimeOffset.UtcNow, Answer: "Synthetic saved answer.")] });
      keeperRun = new TerminalDeck.Keeper.WindowsKeeperRuntime(root, Executable, "unused-tools").RunAsync(serving.Token);
      var complete = Until(() => tasks.Runs()[0].State == TaskRunState.Ended, timeout.Token);
      if (await Task.WhenAny(keeperRun, complete) == keeperRun) await keeperRun;
      await complete;
      var phone = new PhoneRecoveryHost(root, _ => ValueTask.CompletedTask);
      Assert.Single((await phone.ReadAsync(timeout.Token)).Turns);
      serving.Cancel(); await keeperRun; keeperRun = null;
      await Assert.ThrowsAsync<IOException>(async () => await phone.ReadAsync(timeout.Token));
      // Reopen the same saved root with a fresh real Keeper composition.
      using var resumed = new CancellationTokenSource();
      keeperRun = new TerminalDeck.Keeper.WindowsKeeperRuntime(root, Executable, "unused-tools").RunAsync(resumed.Token);
      try { Assert.Single((await phone.ReadAsync(timeout.Token)).Turns); }
      finally { resumed.Cancel(); await keeperRun; keeperRun = null; }
      Assert.Equal(TaskRunState.Ended, Assert.Single(tasks.Runs()).State);
      Assert.Contains("Synthetic saved answer.", Assert.Single(tasks.Get(task.Id).Comments).Text);
      Assert.Empty(Directory.GetFiles(Path.Combine(root.DirectoryPath, "chats"), "*.json", SearchOption.AllDirectories));
    }
    finally { serving.Cancel(); if (keeperRun is not null) await keeperRun; await Clean(root); }
  }
}
