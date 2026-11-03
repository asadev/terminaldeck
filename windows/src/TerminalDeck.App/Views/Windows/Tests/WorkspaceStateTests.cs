#if SHELL_WORKSPACE_TESTS
using System.Text.Json;
using Xunit;

namespace TerminalDeck.App.Shell;

public sealed class WorkspaceStateTests
{
  private static WorkspaceState Fixture()
  {
    var state = new WorkspaceState();
    state.Ensure("session", "session", "session", "terminal", "Work");
    state.Ensure("chat", "session", "chat", "chat", "Chat");
    state.Ensure("b1", "session", "b1", "browser", "B1");
    state.Ensure("b2", "session", "b2", "browser", "B2");
    state.Select("session"); return state;
  }
  [Fact] public void StartupDropsImplicitPagesAndKeepsSessionsAndBrowsers()
  {
    var saved = new WorkspaceSaved([
      new("page:Hoot", "pages", "Hoot", "page", "Hoot"),
      new("page:Tasks", "pages", "Tasks", "page", "Tasks"),
      new("session", "session", "session", "terminal", "Work"),
      new("browser", "session", "browser", "browser", "Reference")
    ], [new("pages", "main", "page:Tasks", new("page:Tasks"), SavedSplit: new("page:Tasks"))]);
    var restored = new WorkspaceState(saved);
    Assert.Equal(new[] { "session", "browser" }, restored.Tabs.Select(t => t.Id));
    Assert.Null(restored.Layout("pages").Active);
    Assert.Null(restored.Layout("pages").Root);
    Assert.Null(restored.Layout("pages").SavedSplit);
    restored.Ensure("page:Tasks", "pages", "Tasks", "page", "Tasks");
    restored.Select("page:Tasks");
    Assert.Equal("page:Tasks", restored.Layout("pages").Active);
    restored.Move("page:Tasks", 1);
    Assert.Equal(new[] { "session", "page:Tasks", "browser" }, restored.Tabs.Select(t => t.Id));
  }
  // Asad 3 Nov: Hoot stays closed until the person opens it. Even a Hoot tab an agent or the person
  // moved into the header (or a window) is not reopened at the next launch; its own tab closes like any other.
  [Fact] public void HootPageTabNeverReopensAtStartupAndCloses()
  {
    WorkspaceSaved? saved = null; var state = new WorkspaceState(persist: value => saved = value);
    state.Ensure(WorkspaceState.HootPageTab, "pages", "Hoot", "page", "Hoot", explicitPage: true); state.Select(WorkspaceState.HootPageTab);
    state.Ensure("page:Tasks", "pages", "Tasks", "page", "Tasks", explicitPage: true);
    var reopened = new WorkspaceState(saved);
    Assert.Equal(new[] { "page:Tasks" }, reopened.Tabs.Select(t => t.Id));
    Assert.NotEqual(WorkspaceState.HootPageTab, reopened.Layout("pages").Active);
    state.Close(WorkspaceState.HootPageTab);
    Assert.DoesNotContain(state.Tabs, t => t.Id == WorkspaceState.HootPageTab);
  }
  [Fact] public void ExplicitlyMovedPageTabSurvivesRestart()
  {
    WorkspaceSaved? saved = null; var state = new WorkspaceState(persist: value => saved = value);
    state.Ensure("page:Tasks", "pages", "Tasks", "page", "Tasks", explicitPage: true); state.Select("page:Tasks");
    var reopened = new WorkspaceState(saved);
    Assert.True(Assert.Single(reopened.Tabs).ExplicitPage); Assert.Equal("page:Tasks", reopened.Layout("pages").Active);
  }
  [Fact] public void SelectionTracksTheVisibleTabWithoutChangingAnExistingSplit()
  {
    var state = Fixture(); state.Split("session", "b1"); state.Focus("session");
    Assert.Equal(new[] { "session", "b1" }, state.Layout("session").Root!.Tabs);
    Assert.Equal("session", state.Layout("session").Active);
    state.Select("chat"); Assert.Equal("chat", state.Layout("session").Root!.Tab);
  }
  [Fact] public void SupportsThreePanesAndNestedVerticalSplit()
  {
    var state = Fixture(); state.Split("session", "b1"); state.Split("b1", "b2", true);
    var root = state.Layout("session").Root!;
    Assert.Equal(new[] { "session", "b1", "b2" }, root.Tabs);
    Assert.True(root.Second!.Vertical);
    state.ClosePane("session", "main", "b1"); Assert.Equal(new[] { "session", "b2" }, state.Layout("session").Root!.Tabs);
  }
  [Fact] public void ReaddingPaneDoesNotDuplicateIt()
  {
    var state = Fixture(); state.Split("session", "b1"); state.Split("session", "b1");
    Assert.Equal(2, state.Layout("session").Root!.Tabs.Count());
  }
  [Fact] public void TabOrderAndKeyboardWrapAreConsistent()
  {
    var state = Fixture(); state.Move("b2", 0); state.Select("b2");
    Assert.Equal("session", state.Step("session", "main", 1));
    Assert.Equal("b1", state.Step("session", "main", -1));
    Assert.Equal(new[] { "b2", "session", "chat", "b1" }, state.Tabs.Select(t => t.Id));
  }
  [Fact] public void SeparateWindowsHaveIndependentLayoutsAndReturnWithoutDuplicatingTabs()
  {
    var state = Fixture(); state.Split("session", "b1"); state.Transfer("b1", "separate");
    Assert.Equal(new[] { "session", "b1" }, state.Layout("session").Root!.Tabs);
    Assert.Equal("session", state.Layout("session").Active);
    Assert.Equal("b1", state.Layout("session", "separate").Root!.Tab);
    state.Transfer("b1", "main");
    Assert.Null(state.Layout("session", "separate").Root);
    Assert.Equal("b1", state.Layout("session").Active); Assert.Equal(4, state.Tabs.Count);
  }
  [Fact] public void ClosingActiveTabSelectsAnExistingNeighbour()
  {
    var state = Fixture(); state.Close("session");
    Assert.Equal("chat", state.Layout("session").Active);
    Assert.DoesNotContain(state.Tabs, t => t.Id == "session");
  }
  [Fact] public void RenameAndOrderSurviveRestartAndDetachedViewsReturnHome()
  {
    WorkspaceSaved? saved = null;
    var state = new WorkspaceState(persist: snapshot => saved = JsonSerializer.Deserialize<WorkspaceSaved>(JsonSerializer.Serialize(snapshot)));
    state.Ensure("one", "session", "one", "browser", "Original"); state.Rename("one", "Research"); state.Transfer("one", "separate");
    var restored = new WorkspaceState(saved); restored.Ensure("one", "session", "one", "browser", "Page title changed");
    Assert.Equal("main", restored.Get("one").Host); Assert.Equal("Research", restored.Get("one").Title);
  }
  [Fact] public void DividerWidthsAreClampedAndOtherSplitsStayIntact()
  {
    var state = Fixture(); state.Split("session", "b1"); state.Split("b1", "b2", true);
    var root = state.Layout("session").Root!; state.Resize("session", "main", root.Second!, 0.99);
    Assert.Equal(0.5, state.Layout("session").Root!.Ratio);
    Assert.Equal(0.85, state.Layout("session").Root!.Second!.Ratio);
  }
  [Fact] public void FocusInCrossSessionSplitKeepsTheLayoutOwner()
  {
    var state = Fixture(); state.Ensure("other", "other", "other", "terminal", "Other");
    state.Split("session", "other"); state.Focus("other", "session", "main");
    Assert.Equal("other", state.Layout("session").Active); Assert.Equal(2, state.Layout("session").Root!.Tabs.Count());
    state.One("other", "session"); Assert.Equal("other", state.Layout("session").Root!.Tab);
  }
  [Fact] public void GlobalHeaderReordersAcrossSessionsAndKeyboardVisitsEveryTab()
  {
    var state = Fixture(); state.Ensure("other", "other", "other", "chat", "Other session");
    state.Move("other", 1);
    Assert.Equal("other", state.Tabs[1].Id);
    state.Select("session"); Assert.Equal("other", state.Step("session", "main", 1, allTabs: true));
    Assert.Equal("chat", state.Step("session", "main", 1));
  }
  [Fact] public void ADetachedWindowCannotBeDuplicatedIntoAMainWindowSplit()
  {
    var state = Fixture(); state.Transfer("b1", "separate");
    Assert.Throws<ArgumentException>(() => state.Split("session", "b1"));
    Assert.Equal("b1", state.Layout("session", "separate").Root!.Tab);
    Assert.Equal("session", state.Layout("session").Root!.Tab);
  }
  [Fact] public void DockingOrAttachingToTheCurrentHostKeepsTheExistingSplit()
  {
    var state = Fixture(); state.Split("session", "b1");
    var layout = state.Layout("session");
    state.Transfer("b1", "main"); state.Adopt("b1", "session");
    Assert.Equal(layout, state.Layout("session"));
  }
  [Fact] public void PopAndReturnSessionPreserveItsThreePaneLayout()
  {
    var state = Fixture(); state.Split("session", "b1"); state.Split("b1", "b2", true);
    var original = state.Layout("session");
    state.TransferSession("session", "main", "separate");
    Assert.Null(state.Layout("session").Root);
    Assert.Equal(original.Root, state.Layout("session", "separate").Root);
    Assert.Equal(original.Active, state.Layout("session", "separate").Active);
    state.TransferSession("session", "separate", "main");
    Assert.Equal(original.Root, state.Layout("session").Root);
    Assert.All(state.Tabs, t => Assert.Equal("main", t.Host));
  }
  [Fact] public void RejectsBadNamesAndSplittingAWindowWithItself()
  {
    var state = Fixture();
    Assert.Throws<ArgumentException>(() => state.Rename("session", "\n"));
    Assert.Throws<ArgumentException>(() => state.Split("session", "session"));
    Assert.Throws<ArgumentException>(() => state.Get("missing"));
    state.Ensure("page", "pages", "Agents", "page", "Agents");
    Assert.Throws<ArgumentException>(() => state.Split("session", "page"));
    Assert.Throws<ArgumentException>(() => state.EmptySplit("page"));
  }
  [Fact] public void OnePaneRestoresTheSavedArrangementAndSwapPreservesRatios()
  {
    var state = Fixture(); state.Split("session", "b1"); state.Split("b1", "b2", true);
    var root = state.Layout("session").Root;
    state.One("session"); Assert.Equal("session", state.Layout("session").Root!.Tab);
    Assert.True(state.RestoreSplit("session")); Assert.Equal(root, state.Layout("session").Root);
    state.Swap("session", "main", "session", "b2");
    Assert.Equal(new[] { "b2", "b1", "session" }, state.Layout("session").Root!.Tabs);
    Assert.Equal(root!.Ratio, state.Layout("session").Root!.Ratio);
  }
  [Fact] public void ClosedViewsStayClosedAfterSyncAndRestartUntilExplicitlyReopened()
  {
    WorkspaceSaved? saved = null; var state = new WorkspaceState(persist: value => saved = value);
    state.Ensure("s", "s", "s", "terminal", "Work"); state.Close("s");
    var restored = new WorkspaceState(saved); restored.Ensure("s", "s", "s", "terminal", "Work");
    Assert.Empty(restored.Tabs);
    restored.Reveal("s"); restored.Ensure("s", "s", "s", "terminal", "Work"); Assert.Single(restored.Tabs);
  }

  [Fact] public void FailedPersistenceDoesNotLeaveAGhostTabOrLoseThePreviousSplit()
  {
    var fail = false; var state = new WorkspaceState(persist: _ => { if (fail) throw new IOException(); });
    state.Ensure("a", "a", "a", "terminal", "First"); state.Ensure("b", "a", "b", "browser", "Second"); state.Split("a", "b");
    var before = state.Layout("a"); fail = true;
    Assert.Throws<IOException>(() => state.Close("b")); Assert.Equal(before, state.Layout("a")); Assert.Equal("b", state.Get("b").Id); Assert.False(state.IsClosed("b"));
    Assert.Throws<IOException>(() => state.Ensure("ghost", "a", "ghost", "terminal", "New")); Assert.DoesNotContain(state.Tabs, t => t.Id == "ghost");
  }

  [Fact] public void EmptySplitCanBeFilledOrClosedWithoutStoppingOrDuplicatingItsSession()
  {
    var state = Fixture(); state.EmptySplit("session");
    var empty = state.Layout("session").Root!.Second!.EmptyId!;
    Assert.Single(state.Layout("session").Root!.Tabs);
    state.FocusEmpty("session", "main", empty); Assert.Equal(empty, state.Layout("session").ActiveEmpty);
    state.FillEmpty("session", "main", empty, "b1");
    Assert.Equal(new[] { "session", "b1" }, state.Layout("session").Root!.Tabs); Assert.Null(state.Layout("session").ActiveEmpty);
    state.EmptySplit("b1", true); empty = state.Layout("session").Root!.Second!.Second!.EmptyId!;
    state.ClosePane("session", "main", empty);
    Assert.Equal(new[] { "session", "b1" }, state.Layout("session").Root!.Tabs); Assert.Equal(4, state.Tabs.Count);
  }

  [Fact] public void DetachedBrowserPlaceholderReturnsToItsOriginalSplitWithoutDuplicateOwnership()
  {
    var state = Fixture(); state.Split("session", "b1"); var root = state.Layout("session").Root;
    state.Transfer("b1", "child"); Assert.Equal(root, state.Layout("session").Root); Assert.Equal("child", state.Get("b1").Host);
    state.Transfer("b1", "main"); Assert.Equal(root, state.Layout("session").Root); Assert.Null(state.Layout("session", "child").Root);
    Assert.Equal(1, state.Tabs.Count(t => t.Id == "b1"));
  }

  [Fact] public void DamagedLayoutsRefuseDuplicateNativeParentsAndNonFiniteDividers()
  {
    var tab = new WorkspaceTab("a", "a", "a", "terminal", "Work");
    var duplicate = new WorkspaceSaved([tab], [new("a", "main", "a", new(First: new("a"), Second: new("a")))]);
    var nonFinite = new WorkspaceSaved([tab], [new("a", "main", "a", new(First: new("a"), Second: new(EmptyId: "empty"), Ratio: double.NaN))]);
    Assert.Throws<ArgumentException>(() => new WorkspaceState(duplicate));
    Assert.Throws<ArgumentException>(() => new WorkspaceState(nonFinite));
  }

  [Theory]
  [InlineData("left", false, "b2", "session")]
  [InlineData("right", false, "session", "b2")]
  [InlineData("above", true, "b2", "session")]
  [InlineData("below", true, "session", "b2")]
  public void DirectionalPaneMovesPreserveUniqueViewsAndUnrelatedPanes(string edge, bool vertical, string first, string second)
  {
    var state = Fixture(); state.Split("session", "b1"); state.Split("b1", "b2", true);
    state.MovePane("session", "main", "b2", "session", edge);
    var root = state.Layout("session").Root!;
    Assert.Equal(3, root.Tabs.Distinct().Count()); Assert.Equal(3, root.Tabs.Count());
    Assert.Equal(first, root.First!.First!.Tab); Assert.Equal(second, root.First.Second!.Tab); Assert.Equal(vertical, root.First.Vertical);
    Assert.Equal("b1", root.Second!.Tab);
  }

  [Fact] public void CreationUsesTheFocusedSessionAndNeverAdoptsAPageAsASessionOwner()
  {
    var state = Fixture(); state.Ensure("other", "other", "other", "terminal", "Other");
    state.Split("session", "other"); Assert.Equal("other", state.CreationOwner("session"));
    state.Ensure("page:Hoot", "pages", "Hoot", "page", "Hoot"); state.Select("page:Hoot");
    Assert.Equal("", state.CreationOwner("pages"));
  }

  [Fact] public void SwarmIsDerivedAndPreservesManualLayoutAndDetachedOwnership()
  {
    var state = Fixture(); state.Split("session", "b1"); var manual = state.Layout("session").Root;
    state.Transfer("chat", "child"); state.Swarm(["session", "chat"]);
    Assert.Equal(new[] { "session", "chat" }, state.Layout("swarm").Root!.Tabs);
    Assert.Equal("child", state.Get("chat").Host); Assert.Equal(manual, state.Layout("session").Root);
    Assert.Throws<ArgumentException>(() => state.Swarm(["b1"]));
  }

  [Fact] public void NewSwarmMembersAppearWithoutStealingFocusOrResurrectingAClosedView()
  {
    var state = Fixture(); state.Swarm(["session", "chat"]); state.Focus("chat", "swarm");
    state.Ensure("new", "new", "new", "terminal", "Started from phone"); state.RefreshSwarm(["session", "chat", "new"]);
    Assert.Equal("chat", state.Layout("swarm").Active); Assert.Equal(3, state.Layout("swarm").Root!.Tabs.Count());
    state.Close("new"); state.RefreshSwarm(["session", "chat"]);
    Assert.DoesNotContain("new", state.Layout("swarm").Root!.Tabs); Assert.True(state.IsClosed("new"));
  }

  [Fact] public void TabExcursionsRestoreTheSplitButExplicitSoloStaysSoloUntilRestored()
  {
    var state = Fixture(); state.Split("session", "b1"); var split = state.Layout("session").Root;
    state.Select("chat"); Assert.Equal("chat", state.Layout("session").Root!.Tab);
    state.Select("session"); Assert.Equal(split, state.Layout("session").Root);
    state.One("session"); state.Select("b1"); Assert.Equal("b1", state.Layout("session").Root!.Tab);
    Assert.True(state.RestoreSplit("session")); Assert.Equal(split, state.Layout("session").Root);
    state.Select("chat"); state.Close("b1"); state.Select("session");
    Assert.Equal("session", state.Layout("session").Root!.Tab);
  }

}
#endif
