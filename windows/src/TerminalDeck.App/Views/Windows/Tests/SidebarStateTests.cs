using System.Text.Json;
using Xunit;

namespace TerminalDeck.App.Shell;

public sealed class SidebarStateTests
{
  [Fact] public void FreshAndUpgradeDefaultsMatchAndSavedPinsWin()
  {
    Assert.Equal(new[] { "Agents", "Tasks", "Projects" }, new SidebarState(null, false).Read.Pages);
    Assert.Equal(new[] { "Agents", "Tasks", "Projects" }, new SidebarState(null, true).Read.Pages);
    Assert.Equal(new[] { "Tasks", "Mcp" }, new SidebarState(new(["Tasks", "Mcp"], [], [], []), true).Read.Pages);
    Assert.Empty(new SidebarState(new([], [], [], []), true).Read.Pages);
  }
  [Fact] public void AllScopedPagesPinIndependentlyAndRoundTripTheirOrder()
  {
    SidebarSaved? saved = null;
    var state = new SidebarState(null, false, value => saved = JsonSerializer.Deserialize<SidebarSaved>(JsonSerializer.Serialize(value)));
    foreach (var page in SidebarState.Catalogue) state.Pin(page.Id, true);
    state.Pin("Tasks", false); state.MovePage("Mcp", "Agents");
    var restored = new SidebarState(saved, false);
    Assert.Equal("Mcp", restored.Read.Pages[0]); Assert.DoesNotContain("Tasks", restored.Read.Pages);
    Assert.Equal(SidebarState.Catalogue.Length - 1, restored.Read.Pages.Length);
    Assert.Throws<ArgumentException>(() => state.OrderPages(["Mcp", "Mcp"]));
  }
  [Fact] public void SessionPinsNeverChangePagePinsOrDuplicateRunningRows()
  {
    var state = new SidebarState(null, false); state.PinSession("c", true); state.PinSession("c", true);
    state.MoveSession("b", "a");
    Assert.Equal(new[] { "c", "b", "a" }, state.Sort(new[] { "a", "b", "c" }, id => id));
    Assert.Equal(new[] { "Agents", "Tasks", "Projects" }, state.Read.Pages);
  }
  [Fact] public void FailedSaveRetainsPriorChoicesAndGeometryCannotEscapeBounds()
  {
    var state = new SidebarState(null, false, _ => throw new IOException());
    Assert.Throws<IOException>(() => state.Pin("Agents", false)); Assert.True(state.Pinned("Agents"));
    state = new(null, false); state.Geometry(900, false);
    Assert.Equal(340, state.Read.Width); Assert.False(state.Read.Visible);
    Assert.Throws<ArgumentException>(() => state.Geometry(double.NaN, true));
  }
  [Fact] public void ReorderingKeepsPinnedSessionsFirstAcrossRoundTripAndNoOpChoicesDoNotSave()
  {
    var saves = 0; var state = new SidebarState(null, false, _ => saves++);
    state.Pin("Agents", true); state.HideSession("a", false); state.Geometry(264, true);
    Assert.Equal(0, saves);
    state.PinSession("b", true); state.OrderSessions(["a", "b", "c"]);
    var restored = new SidebarState(state.Read, false);
    Assert.Equal(new[] { "b", "a", "c" }, restored.Sort(new[] { "a", "b", "c" }, id => id));
  }

  [Fact] public void ArchiveIsExplicitAndIndependentOfHiddenOrPinnedRows()
  {
    var state = new SidebarState(new(["Tasks"], ["chat"], [], ["hidden"]), true);
    Assert.False(state.IsArchived("chat")); Assert.False(state.IsArchived("hidden"));
    state.ArchiveChat("chat", true); state.ArchiveChat("chat", true);
    var restored = new SidebarState(JsonSerializer.Deserialize<SidebarSaved>(JsonSerializer.Serialize(state.Read)), true);
    Assert.True(restored.IsArchived("chat")); Assert.Single(restored.Read.ArchivedChats!);
    restored.ArchiveChat("chat", false); Assert.Empty(restored.Read.ArchivedChats!);
    Assert.Equal(new[] { "Tasks" }, restored.Read.Pages);
  }
}
