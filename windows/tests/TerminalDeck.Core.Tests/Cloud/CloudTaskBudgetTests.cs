using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Tasks;
using TerminalDeck.Core.Tests.Tasks;

namespace TerminalDeck.Core.Tests.Cloud;

public sealed class CloudTaskBudgetTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-cloud-task-budget-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }

  [Fact]
  public void The_existing_shared_token_budget_reaches_the_runtime_field_and_never_widens_from_another_device()
  {
    var f = new TaskFixture(); var task = f.Create();
    f.Tasks.Detail(task.Id, "token-budget", null, "100", TaskActor.Owner);
    var owner = new CloudTasksOwner(new TaskStore(f.Persistence), f.Projects, new(folder, folder, "tasks"));
    var entity = "task:" + task.Id; var before = owner.CloudRecords()[entity];
    Assert.Equal(100, CloudRecordJson.Get(before, "tokenBudget")?.AsInteger);
    var shorter = CloudRecordJson.Set(before, "tokenBudget", CloudJson.From(50d));
    var plan = owner.CloudPlan(entity, shorter);
    owner.CloudWrite(entity, plan.Store!, before);
    Assert.Equal(50, TaskExtras.Of(f.Tasks.Get(task.Id)).TokenBudget);
    Assert.Empty(f.Tasks.Runs());
    var current = owner.CloudRecords()[entity];
    var larger = owner.CloudPlan(entity, CloudRecordJson.Set(current, "tokenBudget", CloudJson.From(200d)));
    Assert.Equal(CloudTasksOwner.BudgetStays, larger.Held!["tokenBudget"]);
    Assert.Equal(50, CloudRecordJson.Get(larger.Store, "tokenBudget")?.AsInteger);
    var removed = owner.CloudPlan(entity, CloudRecordJson.Remove(current, "tokenBudget"));
    Assert.Equal(CloudTasksOwner.BudgetStays, removed.Held!["tokenBudget"]);
    var invalid = owner.CloudPlan(entity, CloudRecordJson.Set(current, "tokenBudget", CloudJson.From(1.5d)));
    Assert.True(invalid.Held!.ContainsKey("tokenBudget"));
    Assert.Equal(50, TaskExtras.Of(f.Tasks.Get(task.Id)).TokenBudget);
  }
}
