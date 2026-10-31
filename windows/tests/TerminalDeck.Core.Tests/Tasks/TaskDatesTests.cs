using System.Text.Json;
using TerminalDeck.Core.Tasks;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TaskDatesTests
{
  private sealed class Permission : IMcpPermissionBroker
  {
    public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest request, CancellationToken ct) => ValueTask.FromResult(new McpPermissionProof(Guid.NewGuid(), request.CallerId, request.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), true));
  }
  private sealed class Clock : TimeProvider
  {
    public override DateTimeOffset GetUtcNow() => new(2026, 10, 29, 13, 0, 0, TimeSpan.Zero);
    public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;
  }
  [Fact] public void OptionalTimesRoundTripAndAffectOnlyUnfinishedOverdueWork()
  {
    var f = new TaskFixture(); f.Tasks = new(new TaskStore(f.Persistence), f.Projects, _ => null, clock: new Clock());
    var late = f.Tasks.Create(new("Late", ProjectId: "sample", DueDate: "2026-10-29", DueTime: "12:30"), TaskActor.Owner);
    f.Tasks.Create(new("Later", ProjectId: "sample", DueDate: "2026-10-29", DueTime: "13:30"), TaskActor.Owner);
    Assert.Equal(late.Id, Assert.Single(f.Tasks.List(new(Due: "overdue"))).Id); Assert.Contains("Due: 2026-10-29 12:30", TaskBrief.Compose(late, "Project", "You"));
    f.Persistence.State = JsonSerializer.Deserialize<TasksState>(JsonSerializer.Serialize(f.Persistence.State)); Assert.Equal("12:30", f.Open().Get(late.Id).DueTime);
    f.Tasks.Status(late.Id, "Done", TaskActor.Owner); Assert.Empty(f.Tasks.List(new(Status: "all", Due: "overdue")));
  }
  [Theory] [InlineData("25:00")] [InlineData("9:30")] [InlineData("09:99")] [InlineData("")]
  public void InvalidTimesCannotChangeTheLedger(string time)
  {
    var f = new TaskFixture(); Assert.Throws<ArgumentException>(() => f.Tasks.Create(new("Invalid", DueDate: "2026-10-29", DueTime: time), TaskActor.Owner)); Assert.Empty(f.Tasks.List());
  }
  [Fact] public void DateAndTimeOrderAreValidatedTogether()
  {
    var f = new TaskFixture(); Assert.Throws<ArgumentException>(() => f.Tasks.Create(new("No date", DueTime: "12:00"), TaskActor.Owner));
    Assert.Throws<ArgumentException>(() => f.Tasks.Create(new("Wrong order", StartDate: "2026-10-29", StartTime: "14:00", DueDate: "2026-10-29", DueTime: "13:00"), TaskActor.Owner));
  }
  [Fact] public async Task ClearingADateThroughTheToolAlsoClearsItsTime()
  {
    var f = new TaskFixture(); var tools = new TasksMcp(f.Tasks, f.Projects, "pc", _ => null);
    var door = new McpDoor(new Permission()); tools.Register(door);
    var caller = door.RegisterCaller(new("date-fixture", null, null, true, AiPermissionMode.Ask, ["tasks.local_change"], Enum.GetValues<McpTier>(), ["*"], DateTimeOffset.UtcNow.AddHours(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
    var result = await door.CallAsync(caller.Id, "tasks.local_change", TasksMcp.Value(new { @do = "create", title = "Timed", projectId = "sample", due_date = "2026-10-29", due_time = "09:30" }));
    var id = result.GetProperty("task").GetString()!; Assert.Equal("09:30", f.Tasks.Get(id).DueTime);
    await door.CallAsync(caller.Id, "tasks.local_change", TasksMcp.Value(new { @do = "update", task = id, due_date = (string?)null }));
    Assert.Null(f.Tasks.Get(id).DueTime); Assert.Null(f.Tasks.Get(id).DueDate);
  }
}
