using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Tasks;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Tasks;

namespace TerminalDeck.Core.Tests.Cloud;

public sealed class CloudTaskBudgetTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-cloud-task-budget-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }

  [Fact]
  public void The_existing_shared_token_budget_reaches_the_runtime_field_and_never_widens_from_another_device()
  {
    var f = new TaskFixture(); var root = AppDataRoot.Explicit(folder);
    // Foreground and Cloud own separate stores in production. Use their durable shared ledger:
    // two in-memory TaskStores intentionally keep separate cached snapshots.
    var tasks = new TaskService(TaskStore.At(root), f.Projects, _ => null);
    var task = tasks.Create(new("Check the task", ProjectId: "sample"), TaskActor.Owner);
    tasks.Detail(task.Id, "token-budget", null, "100", TaskActor.Owner);
    var owner = new CloudTasksOwner(TaskStore.At(root), f.Projects, new(folder, folder, "tasks"));
    var entity = "task:" + task.Id; var before = owner.CloudRecords()[entity];
    Assert.Equal(100, CloudRecordJson.Get(before, "tokenBudget")?.AsInteger);
    var shorter = CloudRecordJson.Set(before, "tokenBudget", CloudJson.From(50d));
    var plan = owner.CloudPlan(entity, shorter);
    owner.CloudWrite(entity, plan.Store!, before);
    Assert.Equal(50, TaskExtras.Of(tasks.Get(task.Id)).TokenBudget);
    Assert.Equal(50, TaskExtras.Of(TaskStore.At(root).Read().Tasks.Single(t => t.Id == task.Id)).TokenBudget);
    Assert.Empty(tasks.Runs());
    var current = owner.CloudRecords()[entity];
    var larger = owner.CloudPlan(entity, CloudRecordJson.Set(current, "tokenBudget", CloudJson.From(200d)));
    Assert.Equal(CloudTasksOwner.BudgetStays, larger.Held!["tokenBudget"]);
    Assert.Equal(50, CloudRecordJson.Get(larger.Store, "tokenBudget")?.AsInteger);
    var removed = owner.CloudPlan(entity, CloudRecordJson.Remove(current, "tokenBudget"));
    Assert.Equal(CloudTasksOwner.BudgetStays, removed.Held!["tokenBudget"]);
    var invalid = owner.CloudPlan(entity, CloudRecordJson.Set(current, "tokenBudget", CloudJson.From(1.5d)));
    Assert.True(invalid.Held!.ContainsKey("tokenBudget"));
    Assert.Equal(50, TaskExtras.Of(tasks.Get(task.Id)).TokenBudget);
  }
}
