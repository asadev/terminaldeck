using TerminalDeck.App.Views.WhatsApp;
using TerminalDeck.Core.WhatsApp;

namespace TerminalDeck.Core.Tests.WhatsAppScreens;

// WhatsApp agents, the screens' rules (DESIGN-WHATSAPP sections 2 and 3), against the engine's WhatsAppAgentsFixture.
// What each Settings row shows in each state, the submenu's contents and what choosing does, the chip only when attached.
// Made-up data only; nothing here reaches WhatsApp.
public sealed class WhatsAppScreensTests
{
  private static readonly WhatsAppReceiver Login = WhatsAppReceiver.Session("s-login", "Fix the login page");

  private static WhatsAppAgentProfile Agent(string id, string name, WhatsAppAgentState state, WhatsAppReceiver receiver, bool sending = true, string? computer = "This PC", bool here = true) =>
    new(id, name, state, receiver, computer, here, Sending: sending);

  private static async Task<WhatsAppAgentsStore> Store(params WhatsAppAgentProfile[] agents)
  {
    var store = new WhatsAppAgentsStore();
    await store.ConnectAsync(new WhatsAppAgentsFixture(agents));
    return store;
  }

  private static WhatsAppReceiverChoices Choices() => WhatsAppReceiverChoices.From(
    [("a-lead", "Lead", "Website"), ("a-solo", "Helper", ""), ("a-review", "Reviewer", "Website"), ("a-store", "Store writer", "Mobile app")],
    [("s-login", "Fix the login page"), ("s-notes", "Write the release notes"), ("s-login", "Fix the login page")]);

  // ---- Settings > AI apps: one row per WhatsApp agent ----

  [Fact]
  public void AConnectedRowShowsAGreenDotItsNameAndWhereItIsReceivedAndNothingElse()
  {
    var look = WhatsAppRowLook.For(Agent("w1", "Office", WhatsAppAgentState.Connected, WhatsAppReceiver.Hoot));
    Assert.Equal(WhatsAppDot.Green, look.Dot);
    Assert.Equal("Office", look.Name);
    Assert.Null(look.Secondary);
    Assert.Null(look.Refused);
    Assert.True(look.ShowsReceiver);
    Assert.Equal("Hoot", look.ReceiverTitle);
    Assert.Equal(["Pause", "Rename", "Replace key", "-", "Remove"], look.Menu);
  }

  [Fact]
  public void AWaitingRowHasNoDotAndSaysItWaitsBesideThePopUp()
  {
    var look = WhatsAppRowLook.For(Agent("w1", "Phone", WhatsAppAgentState.Waiting, Login));
    Assert.Equal(WhatsAppDot.None, look.Dot);
    Assert.Equal("Waiting for your first message", look.Secondary);
    Assert.True(look.ShowsReceiver);
    Assert.Equal("Fix the login page", look.ReceiverTitle);
  }

  [Fact]
  public void ARefusedRowIsOrangeAndTheRefusalReplacesThePopUp()
  {
    var look = WhatsAppRowLook.For(Agent("w1", "Old number", WhatsAppAgentState.Refused, WhatsAppReceiver.Hoot));
    Assert.Equal(WhatsAppDot.Orange, look.Dot);
    Assert.Equal("The key was refused", look.Refused);
    Assert.False(look.ShowsReceiver);
    Assert.Null(look.Secondary);
    Assert.Contains("Replace key", look.Menu);
  }

  [Fact]
  public void APausedRowSaysPausedAndItsMenuOffersResumeFirst()
  {
    var look = WhatsAppRowLook.For(Agent("w1", "Weekend", WhatsAppAgentState.Connected, WhatsAppReceiver.Agent("a-review", "Reviewer"), sending: false));
    Assert.Equal("Paused", look.Secondary);
    Assert.True(look.ShowsReceiver);
    Assert.Equal("Resume", look.Menu[0]);
    // Even a waiting row that is paused says Paused (the switch is what he set last).
    Assert.Equal("Paused", WhatsAppRowLook.For(Agent("w2", "Phone", WhatsAppAgentState.Waiting, Login, sending: false)).Secondary);
  }

  [Fact]
  public void ARowAnsweredByAnotherComputerSaysWhichOne()
  {
    Assert.Equal("Answered by Studio Mac", WhatsAppRowLook.For(Agent("w1", "Second phone", WhatsAppAgentState.Connected, WhatsAppReceiver.Hoot, computer: "Studio Mac", here: false)).Secondary);
    Assert.Null(WhatsAppRowLook.For(Agent("w2", "Travel", WhatsAppAgentState.Connected, WhatsAppReceiver.Nowhere, computer: "Studio Mac", here: false)).Secondary);
  }

  [Fact]
  public void TheWordsAreTheMacsWithThisPcForWindows()
  {
    Assert.Equal("WhatsApp", WhatsAppWords.GroupTitle);
    Assert.StartsWith("1. In WhatsApp open Settings > Agents and create an agent.", WhatsAppWords.Steps);
    Assert.EndsWith("3. Add it here.", WhatsAppWords.Steps);
    Assert.Equal("WhatsApp does not encrypt these chats end to end.", WhatsAppWords.NotEncrypted);
    Assert.Equal("Paste the key from WhatsApp", WhatsAppWords.KeyPrompt);
    Assert.Equal("Send to WhatsApp", WhatsAppWords.Send);
    Assert.Equal("outside-ai-apps", WhatsAppWords.SettingsSection);
    Assert.DoesNotContain("Mac", WhatsAppWords.Steps + WhatsAppWords.NotEncrypted);
  }

  // ---- the add row: always there, names prefilled, a refused key keeps the fields ----

  [Fact]
  public async Task TheAddRowNamesComeInOrderAndThereIsNoLimit()
  {
    var store = await Store();
    Assert.Equal("WhatsApp agent", store.NextDefaultName);
    Assert.True(await store.AddAsync(store.NextDefaultName, "key-1"));
    Assert.Equal("WhatsApp agent 2", store.NextDefaultName);
    for (var i = 2; i <= 9; i++) Assert.True(await store.AddAsync("", "key-" + i));
    Assert.Equal(9, store.Agents.Count);
    Assert.True(store.CanAdd);
    // The first one he adds is received by Hoot; later ones nowhere.
    Assert.Equal(WhatsAppReceiverKind.Hoot, store.Agents[0].Receiver.Kind);
    Assert.All(store.Agents.Skip(1), a => Assert.Equal(WhatsAppReceiverKind.Nowhere, a.Receiver.Kind));
  }

  [Fact]
  public async Task ARefusedKeyIsSaidInOneLineAndAddsNothing()
  {
    var store = await Store();
    Assert.False(await store.AddAsync("WhatsApp agent", "refused-test-key"));
    Assert.Empty(store.Agents);
    Assert.Equal(WhatsAppProblem.KeyRefused.Message, store.Problem);
    Assert.DoesNotContain("\n", store.Problem!);
    Assert.False(store.Checking);
  }

  // ---- the row pop-up: Hoot · agents under their project · Sessions · Nowhere ----

  [Fact]
  public void ThePopUpListsHootTheAgentsUnderTheirProjectTheSessionsAndNowhere()
  {
    var lines = Choices().Lines(WhatsAppReceiver.Agent("a-review", "Reviewer"));
    Assert.Equal(
      ["Hoot", "[Website]", "Lead", "Reviewer", "[Independent]", "Helper", "[Mobile app]", "Store writer", "[Sessions]", "Fix the login page", "Write the release notes", "-", "Nowhere"],
      lines.Select(l => l.Kind switch { WhatsAppPopUpLineKind.Header => "[" + l.Text + "]", WhatsAppPopUpLineKind.Separator => "-", _ => l.Text }));
    Assert.Equal(["Reviewer"], lines.Where(l => l.Checked).Select(l => l.Text));
  }

  [Fact]
  public void ThePopUpChoosesByIdAndKeepsAReceiverNoLongerListed()
  {
    var lists = Choices();
    var gone = WhatsAppReceiver.Session("s-old", "Old session");
    Assert.True(lists.Lacks(gone));
    var lines = lists.Lines(gone);
    Assert.Contains(lines, l => l.Text == "Old session" && l.Checked);
    Assert.Equal(gone, lists.Receiver("session:s-old", gone));
    Assert.Equal(WhatsAppReceiver.Session("s-notes", "Write the release notes"), lists.Receiver("session:s-notes", gone));
    Assert.Equal(WhatsAppReceiver.Agent("a-lead", "Lead"), lists.Receiver("agent:a-lead", gone));
    Assert.Equal(WhatsAppReceiver.Hoot, lists.Receiver("hoot", gone));
    Assert.Equal(WhatsAppReceiver.Nowhere, lists.Receiver("nowhere", gone));
    // A renamed session is still the one chosen.
    Assert.Equal("session:s-login", WhatsAppReceiverChoices.Tag(WhatsAppReceiver.Session("s-login", "New name")));
    Assert.DoesNotContain(WhatsAppReceiverChoices.Empty.Lines(WhatsAppReceiver.Hoot), l => l.Kind == WhatsAppPopUpLineKind.Header);
  }

  [Fact]
  public async Task ChoosingInThePopUpMovesTheAgentAtOnce()
  {
    var store = await Store(Agent("w1", "Office", WhatsAppAgentState.Connected, WhatsAppReceiver.Hoot));
    Assert.True(await store.SetReceiverAsync("w1", Choices().Receiver("session:s-notes", store.Agents[0].Receiver)));
    Assert.Equal(WhatsAppReceiver.Session("s-notes", "Write the release notes"), store.Agents[0].Receiver);
  }

  // ---- the "WhatsApp" submenu ----

  [Fact]
  public void TheSubmenuListsHisAgentsByNameWithACheckOnTheOneHereThenSendAndOff()
  {
    var agents = new[] { Agent("w1", "Office", WhatsAppAgentState.Connected, WhatsAppReceiver.Hoot), Agent("w2", "Phone", WhatsAppAgentState.Waiting, Login, sending: false) };
    var entries = WhatsAppMenu.Entries(agents, WhatsAppReceiver.Session("s-login", "renamed"));
    Assert.Equal(["Office", "Phone", "", "Send to WhatsApp", "Off"], entries.Select(e => e.Text));
    Assert.Equal([false, true], entries.Where(e => e.Kind == WhatsAppMenuEntryKind.Agent).Select(e => e.Checked));
    var send = entries.Single(e => e.Kind == WhatsAppMenuEntryKind.Sending);
    Assert.Equal("w2", send.AgentId); Assert.False(send.Checked);
    Assert.True(entries.Single(e => e.Kind == WhatsAppMenuEntryKind.Off).Enabled);
  }

  [Fact]
  public void WithNothingAttachedHereTheSubmenuHasNoSwitchAndOffIsGreyed()
  {
    var entries = WhatsAppMenu.Entries([Agent("w1", "Office", WhatsAppAgentState.Connected, WhatsAppReceiver.Hoot)], WhatsAppReceiver.Agent("a-lead", "Lead"));
    Assert.DoesNotContain(entries, e => e.Kind == WhatsAppMenuEntryKind.Sending);
    Assert.False(entries.Single(e => e.Kind == WhatsAppMenuEntryKind.Off).Enabled);
  }

  [Fact]
  public void WithNoWhatsAppAgentTheSubmenuOffersToAddOne()
  {
    var entries = WhatsAppMenu.Entries([], Login);
    Assert.Equal([WhatsAppMenuEntryKind.AddAgent], entries.Select(e => e.Kind));
    Assert.Equal("Add a WhatsApp agent…", entries[0].Text);
  }

  [Fact]
  public async Task ChoosingAnAgentAttachesItHereTakingItFromWhereItWasAndTurnsSendingOn()
  {
    var store = await Store(Agent("w1", "Office", WhatsAppAgentState.Connected, WhatsAppReceiver.Hoot, sending: false));
    var entry = WhatsAppMenu.Entries(store.Agents, Login).First(e => e.AgentId == "w1");
    Assert.True(await WhatsAppMenu.PerformAsync(entry, Login, store));
    Assert.True(store.Agents[0].Receiver.SameTarget(Login));
    Assert.True(store.Agents[0].Sending);
    Assert.Empty(store.AttachedToHoot);
    Assert.Single(store.AttachedToSession("s-login"));
  }

  [Fact]
  public async Task SendToWhatsAppTurnsSendingOffAndOnAndKeepsTheAgentAttached()
  {
    var store = await Store(Agent("w1", "Phone", WhatsAppAgentState.Connected, Login));
    var send = WhatsAppMenu.Entries(store.Agents, Login).Single(e => e.Kind == WhatsAppMenuEntryKind.Sending);
    Assert.True(send.Checked);
    Assert.True(await WhatsAppMenu.PerformAsync(send, Login, store));
    Assert.False(store.Agents[0].Sending);
    Assert.True(store.Agents[0].Receiver.SameTarget(Login));
    send = WhatsAppMenu.Entries(store.Agents, Login).Single(e => e.Kind == WhatsAppMenuEntryKind.Sending);
    Assert.False(send.Checked);
    Assert.True(await WhatsAppMenu.PerformAsync(send, Login, store));
    Assert.True(store.Agents[0].Sending);
  }

  [Fact]
  public async Task OffSendsEveryAgentAttachedHereToNowhereAndLeavesTheOthers()
  {
    var store = await Store(Agent("w1", "Phone", WhatsAppAgentState.Connected, Login), Agent("w2", "Office", WhatsAppAgentState.Connected, WhatsAppReceiver.Hoot));
    var off = WhatsAppMenu.Entries(store.Agents, Login).Single(e => e.Kind == WhatsAppMenuEntryKind.Off);
    Assert.True(await WhatsAppMenu.PerformAsync(off, Login, store));
    Assert.Equal(WhatsAppReceiverKind.Nowhere, store.Agents[0].Receiver.Kind);
    Assert.Equal(WhatsAppReceiverKind.Hoot, store.Agents[1].Receiver.Kind);
  }

  // ---- the heading chip and its switch ----

  [Fact]
  public async Task TheChipShowsOnlyWhileAnAgentIsAttachedHere()
  {
    var store = await Store(Agent("w1", "Phone", WhatsAppAgentState.Waiting, Login), Agent("w2", "Office", WhatsAppAgentState.Connected, WhatsAppReceiver.Agent("a-lead", "Lead")));
    Assert.Equal(new WhatsAppChipLook("w1", "Phone", true), WhatsAppChipLook.For(store.Agents, WhatsAppReceiver.Session("s-login", "")));
    Assert.Equal("Office", WhatsAppChipLook.For(store.Agents, WhatsAppReceiver.Agent("a-lead", ""))!.Name);
    Assert.Null(WhatsAppChipLook.For(store.Agents, WhatsAppReceiver.Hoot));
    Assert.Null(WhatsAppChipLook.For(store.Agents, WhatsAppReceiver.Session("s-notes", "Write the release notes")));
    Assert.Equal("Received on WhatsApp: Phone", WhatsAppChipLook.For(store.Agents, Login)!.Help);
    await store.OffAsync(Login);
    Assert.Null(WhatsAppChipLook.For(store.Agents, Login));
  }

  [Fact]
  public async Task TheChipFollowsTheSwitch()
  {
    var store = await Store(Agent("w1", "Phone", WhatsAppAgentState.Connected, WhatsAppReceiver.Hoot));
    Assert.True(WhatsAppChipLook.For(store.Agents, WhatsAppReceiver.Hoot)!.Sending);
    Assert.True(await store.SetSendingAsync(false, "w1"));
    var off = WhatsAppChipLook.For(store.Agents, WhatsAppReceiver.Hoot);
    Assert.NotNull(off);   // still attached: one flick brings it back
    Assert.False(off!.Sending);
  }

  [Fact]
  public void SessionRowsAndTheNewSessionPageGetNothing()
  {
    // DESIGN-SESSION-ROWS: a session row is an icon and a name. The row builder and the New session page never read WhatsApp.
    var root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "src", "TerminalDeck.App"));
    if (!Directory.Exists(root)) return;   // the source tree is not beside this build
    foreach (var file in new[] { "Views/Windows/ShellSidebar.cs", "Views/Windows/SidebarCloudRows.cs", "Views/Agents/NewSessionPage.cs" })
      Assert.DoesNotContain("WhatsApp", File.ReadAllText(Path.Combine(root, file)));
    // The submenu sits in the existing menus, the chip in the existing heading line.
    Assert.Contains("WhatsAppMenus.Submenu", File.ReadAllText(Path.Combine(root, "Views/Windows/ShellSessionMenu.cs")));
    Assert.Contains("WhatsAppChip", File.ReadAllText(Path.Combine(root, "Views/Windows/WorkspaceSurface.cs")));
    Assert.Contains("WhatsAppSettingsGroup", File.ReadAllText(Path.Combine(root, "Views/Settings/Connections/CallerManagement.cs")));
  }
}
