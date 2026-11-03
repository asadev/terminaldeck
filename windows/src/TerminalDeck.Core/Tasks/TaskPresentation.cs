using System.Collections.Immutable;

namespace TerminalDeck.Core.Tasks;

public static class TaskPresentation
{
  public static readonly ImmutableArray<string> ColumnKeys = ["assignee", "due", "priority", "status", "created", "project", "goal"];
  public static readonly ImmutableArray<string> DefaultColumns = ["assignee", "due", "priority", "status", "project"];
  public static ImmutableArray<string> Columns(TaskFilter state) => state.Columns.IsDefault ? DefaultColumns : state.Columns;
  public static ImmutableArray<string> Order(TaskFilter state) => state.ColumnOrder.IsDefault ? ColumnKeys :
    state.ColumnOrder.Length == ColumnKeys.Length - 1 && !state.ColumnOrder.Contains("goal") ? state.ColumnOrder.Add("goal") : state.ColumnOrder;
  public static bool ValidColumns(TaskFilter state) => Columns(state).Distinct().Count() == Columns(state).Length && Columns(state).All(ColumnKeys.Contains) &&
    Order(state).Length == ColumnKeys.Length && Order(state).Distinct().Count() == ColumnKeys.Length && Order(state).All(ColumnKeys.Contains);
  public static bool Same(TaskFilter a, TaskFilter b) => a with { Columns = default, ColumnOrder = default, ProjectIds = default, Statuses = default, Assignees = default } == b with { Columns = default, ColumnOrder = default, ProjectIds = default, Statuses = default, Assignees = default }
    && Columns(a).ToHashSet().SetEquals(Columns(b)) && Order(a).SequenceEqual(Order(b))
    && Set(a.ProjectIds).SetEquals(Set(b.ProjectIds)) && Set(a.Statuses).SetEquals(Set(b.Statuses)) && Set(a.Assignees).SetEquals(Set(b.Assignees));
  private static HashSet<string> Set(ImmutableArray<string> values) => values.IsDefault ? [] : values.ToHashSet();
}
