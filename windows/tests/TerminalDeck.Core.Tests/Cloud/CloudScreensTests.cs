using System.Text.Json;
using TerminalDeck.App.Shell;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// Lane U2 (15 Nov): the Cloud screens' rules that need no window. Made-up data only.
public sealed class CloudScreensTests
{
  private static readonly IReadOnlyDictionary<string, CloudSessionsRead.Machine> Machines = new Dictionary<string, CloudSessionsRead.Machine>
  {
    ["m-mini"] = new("m-mini", "Mac mini", true, true),
    ["m-book"] = new("m-book", "MacBook Pro.local", false, true)
  };

  private static CloudSessionsRead.Row Row(string reference, string? session, string? name, string machine, string kind = "terminal", string? status = null, bool mine = false, double used = 1, double? closed = null) =>
    new(reference, session, name, used, Kind: kind, Status: status, Machine: machine, Mine: mine, ClosedAt: closed);

  // ---- The side panel: one row per session, never twice ----

  [Fact]
  public void SidebarListsOtherMachinesSessionsOnceNewestFirst()
  {
    var rows = SidebarCloudRows.From([
      Row("r1", "s1", "Fix the login page", "m-mini", "chat", used: 10),
      Row("r2", "s2", "Release notes", "m-book", used: 20),
      Row("r1", "s1", "Fix the login page", "m-mini", "chat", used: 10),   // the same row twice
      Row("r3", "s1", "Fix the login page (copy)", "m-mini", used: 5)      // the same session under another ref
    ], Machines, []);
    Assert.Equal(["r2", "r1"], rows.Select(r => r.Ref));
    Assert.Equal("MacBook Pro", rows[0].MachineName);   // ".local" never shown
    Assert.False(rows[0].MachineOn);
    Assert.True(rows[1].Chat);
    Assert.False(rows[0].Chat);
  }

  [Fact]
  public void EveryOpenLocalSessionIsItsOwnRowAndAnotherMachinesIsOneMore()
  {
    // Four terminals on this PC (two of them share one tab strip: never collapsed into one row), one hidden.
    var local = new[] { ("t1", true), ("t2", true), ("t3", true), ("t4", true), ("t2", true), ("gone", false) };
    var rows = SidebarCloudRows.LocalRows(local, s => s.Item1, s => s.Item2).Select(s => s.Item1).ToArray();
    Assert.Equal(["t1", "t2", "t3", "t4"], rows);
    var others = SidebarCloudRows.From([Row("r9", "m9", "On the Mac", "m-mini"), Row("r2", "t2", "Same as a local one", "m-mini")], Machines, rows);
    var all = rows.Concat(others.Select(o => o.SessionId!)).ToArray();
    Assert.Equal(5, all.Length);
    Assert.Equal(all.Length, all.Distinct().Count());
  }

  [Fact]
  public void SidebarHidesACloudRowWhileItsSessionHasARowHere()
  {
    var rows = SidebarCloudRows.From([Row("r1", "s1", "Fix the login page", "m-mini"), Row("r2", "s2", "Release notes", "m-mini")], Machines, ["s1"]);
    Assert.Equal(["r2"], rows.Select(r => r.Ref));
  }

  [Fact]
  public void SidebarNeverListsThisPcsOwnRowsOrClosedSessions()
  {
    var rows = SidebarCloudRows.From([Row("r1", "s1", "Mine", "m-mini", mine: true), Row("r2", "s2", "Closed", "m-mini", closed: 5), Row("r3", "s3", null, "unknown")], Machines, []);
    var only = Assert.Single(rows);
    Assert.Equal(SidebarCloudRows.Untitled, only.Name);
    Assert.Equal("another computer", only.MachineName);
  }

  [Fact]
  public void SidebarRowShowsTheOrangeDotOnlyWhenTheSessionNeedsHim()
  {
    var rows = SidebarCloudRows.From([
      Row("a", "sa", "Waiting", "m-mini", status: "needs-input", used: 3),
      Row("b", "sb", "Working", "m-mini", status: "working", used: 2),
      Row("c", "sc", "Off", "m-book", status: "needs-input", used: 1)
    ], Machines, []);
    Assert.Equal([true, false, false], rows.Select(r => r.NeedsYou));   // an off machine asks nothing now
    foreach (var state in new[] { "waiting", "needs-input", "needs attention", "held" }) Assert.True(SidebarRowLook.NeedsYou(state));
    foreach (var state in new[] { "running", "working", "idle", "chat", "ended", "", null }) Assert.False(SidebarRowLook.NeedsYou(state));
  }

  [Fact]
  public void SidebarTypeIconIsChatOrTerminalOnly()
  {
    Assert.Equal(SidebarRowLook.ChatGlyph, SidebarRowLook.Glyph(true));
    Assert.Equal(SidebarRowLook.TerminalGlyph, SidebarRowLook.Glyph(false));
    Assert.NotEqual(SidebarRowLook.ChatGlyph, SidebarRowLook.TerminalGlyph);
    Assert.True(SidebarCloudRows.IsChat("chat")); Assert.True(SidebarCloudRows.IsChat("hoot"));
    Assert.False(SidebarCloudRows.IsChat("terminal")); Assert.False(SidebarCloudRows.IsChat("agent")); Assert.False(SidebarCloudRows.IsChat(null));
  }

  // ---- The Cloud chat page ----

  [Fact]
  public void CloudChatSaysWhereItRunsAndIsReadOnlyWithoutALiveLink()
  {
    var off = CloudChatRules.For("Fix the login page", "Mac mini", machineOn: false, liveLink: false);
    Assert.Equal("Runs on Mac mini, which is off", off.RunsOn);
    Assert.True(off.ReadOnly);
    var onNoLink = CloudChatRules.For("Fix the login page", "Mac mini", machineOn: true, liveLink: false);
    Assert.Equal("Runs on Mac mini", onNoLink.RunsOn);
    Assert.True(onNoLink.ReadOnly);   // Windows has no live link yet: still read only
    Assert.False(CloudChatRules.For("x", "Mac mini", true, true).ReadOnly);
    Assert.True(CloudChatRules.For("x", "Mac mini", false, true).ReadOnly);
    Assert.Equal(["Deny", "Allow"], CloudChatRules.PermissionAnswers);
  }

  [Fact]
  public void CloudChatReadsThePersonAndTheAiOnlyInOrderOnce()
  {
    static JsonElement E(long sequence, string kind, string text) => JsonSerializer.SerializeToElement(new { version = 1, sequence, kind, value = new { text }, at = 1000 + sequence });
    var lines = CloudChatRules.Lines([E(2, "message", "I added three tests."), E(1, "user", "Add a test"), E(3, "tool", "ls"), E(2, "message", "I added three tests."), E(4, "user", "")]);
    Assert.Equal(2, lines.Count);
    Assert.True(lines[0].Person); Assert.Equal("Add a test", lines[0].Text);
    Assert.False(lines[1].Person); Assert.Equal("I added three tests.", lines[1].Text);
  }

  // ---- Your Cloud: the places and the top bar ----

  private static CloudContentsRow Item(string name, CloudItemState state = CloudItemState.InSync, bool canOpen = true) =>
    new("id-" + name, CloudContentsKind.Memory, name, [], 1, null, 10, state, CanOpen: canOpen);

  [Fact]
  public void PlacesFollowThePageOrderThenCodeThenTheBin()
  {
    var snapshot = new CloudContentsSnapshot([
      new(CloudContentsKind.Tasks, "Tasks", 4, false, true),
      new(CloudContentsKind.Memory, "Memory", 9, true, true),
      new(CloudContentsKind.Agents, "Agents", 0, false, true)
    ], [], 3);
    var places = YourCloudRules.Places(snapshot);
    Assert.Equal(["Memory", "Agents", "Tasks", "Code", "Bin"], places.Select(p => p.Title));
    Assert.Equal(["9", "", "4", "", "3"], places.Select(p => p.Count));   // no number when empty
    Assert.True(places[3].IsCode); Assert.True(places[4].IsBin);
  }

  [Fact]
  public void TopBarOffersOnlyWhatFitsTheSelection()
  {
    var memory = new CloudContentsPlace(CloudContentsKind.Memory, "Memory", 3, true, true);
    var none = YourCloudRules.For(memory, []);
    Assert.False(none.Open || none.BinCloud || none.BinEverywhere); Assert.True(none.ShowBins);   // drawn greyed
    var one = YourCloudRules.For(memory, [Item("Plan")]);
    Assert.True(one.Open && one.BinCloud && one.BinEverywhere); Assert.False(one.BringBack || one.PutInCloudAgain);
    var two = YourCloudRules.For(memory, [Item("Plan"), Item("Review")]);
    Assert.False(two.Open); Assert.True(two.BinCloud && two.BinEverywhere);
    var away = YourCloudRules.For(memory, [Item("Old", CloudItemState.NotOnThisPc)]);
    Assert.True(away.BringBack); Assert.False(away.ShowBins || away.BinCloud || away.BinEverywhere || away.PutInCloudAgain);
    var here = YourCloudRules.For(memory, [Item("Kept", CloudItemState.OnlyOnThisPc)]);
    Assert.True(here.PutInCloudAgain); Assert.False(here.ShowBins || here.BringBack);
    var mixed = YourCloudRules.For(memory, [Item("Plan"), Item("Old", CloudItemState.NotOnThisPc)]);
    Assert.False(mixed.BinCloud || mixed.BinEverywhere || mixed.BringBack || mixed.PutInCloudAgain);
  }

  [Fact]
  public void NoBinsWhereTheDeleteRuleIsNotOpenAndNoCloudBinForTasks()
  {
    var closed = YourCloudRules.For(new(CloudContentsKind.Projects, "Projects", 2, false, false), [Item("Site")]);
    Assert.False(closed.ShowBins || closed.BinCloud || closed.BinEverywhere);
    var tasks = YourCloudRules.For(new(CloudContentsKind.Tasks, "Tasks", 2, false, true), [Item("Write docs")]);
    Assert.False(tasks.BinCloud); Assert.True(tasks.BinEverywhere);
    Assert.False(YourCloudRules.For(null, [Item("x")]).ShowBins);
  }

  [Fact]
  public void TheBinShowsOnlyItsOwnBar()
  {
    Assert.False(YourCloudRules.ShowsListBar("Bin"));
    foreach (var kind in Enum.GetValues<CloudContentsKind>()) Assert.True(YourCloudRules.ShowsListBar(kind.ToString()));
  }

  [Fact]
  public void ANotOnThisPcRowGetsBringBackAndAnOnlyOnThisPcRowPutInCloudAgain()
  {
    var memory = new CloudContentsPlace(CloudContentsKind.Memory, "Memory", 3, true, true);
    var away = YourCloudRules.For(memory, [Item("Old pricing ideas", CloudItemState.NotOnThisPc)]);
    Assert.Equal((true, false, false, false), (away.BringBack, away.BinCloud, away.BinEverywhere, away.ShowBins));
    var here = YourCloudRules.For(memory, [Item("Kept notes", CloudItemState.OnlyOnThisPc)]);
    Assert.Equal((true, false, false), (here.PutInCloudAgain, here.BringBack, here.ShowBins));
  }

  [Fact]
  public void EachDeviceRowHasTheGlyphOfItsKind()
  {
    Assert.Equal(DeviceKind.Desktop, DeviceKinds.Of("macos", "Studio Mac"));
    Assert.Equal(DeviceKind.Laptop, DeviceKinds.Of("macos", "MacBook Air"));
    Assert.Equal(DeviceKind.Pc, DeviceKinds.Of("windows", "Office PC"));
    Assert.Equal(DeviceKind.Laptop, DeviceKinds.Of("windows", "Surface Laptop"));
    Assert.Equal(DeviceKind.Phone, DeviceKinds.Of("ios", "Sam's iPhone"));
    Assert.Equal(DeviceKind.Phone, DeviceKinds.Of("android", "Pixel 9"));
    Assert.Equal(DeviceKind.Web, DeviceKinds.Of("web", "Chrome"));
    Assert.Equal(DeviceKind.Phone, DeviceKinds.Of(null, "Galaxy S25"));
    var glyphs = new[] { DeviceKind.Desktop, DeviceKind.Laptop, DeviceKind.Pc, DeviceKind.Phone }.Select(DeviceKinds.Glyph).ToArray();
    Assert.Equal(glyphs.Length, glyphs.Distinct().Count());
  }

  [Fact]
  public void DatesAndSizesAreWords()
  {
    var now = new DateTimeOffset(2026, 11, 15, 12, 0, 0, TimeSpan.Zero).ToLocalTime();
    Assert.StartsWith("Today, ", YourCloudRules.Changed(now.AddHours(-1).ToUnixTimeMilliseconds(), now));
    Assert.StartsWith("Yesterday, ", YourCloudRules.Changed(now.AddDays(-1).ToUnixTimeMilliseconds(), now));
    Assert.Equal("", YourCloudRules.Changed(0, now));
    Assert.Equal("", YourCloudRules.Size(null));
    Assert.Equal("12 bytes", YourCloudRules.Size(12));
    Assert.Equal("2 KB", YourCloudRules.Size(2048));
    Assert.Equal("1.5 MB", YourCloudRules.Size(1_572_864).Replace(',', '.'));
    Assert.Equal(["Memory", "Deck Dev", "Lead"], YourCloudRules.Crumbs("Memory", ["Deck Dev", "Lead"]));
  }
}
