using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.ProjectsAgents.Tests;

public sealed class AgentTests
{
  [Theory]
  [InlineData("👩‍💻")]
  [InlineData("🧑🏽‍🚀")]
  [InlineData("🇦🇪")]
  [InlineData("1️⃣")]
  public void EmojiPicturesKeepOneWholeGraphemeAndColour(string emoji)
  {
    var value = AgentPictures.Emoji(emoji, "teal"); var picture = AgentPictures.Parse(value);
    Assert.Equal("emoji:" + emoji, picture.Picture); Assert.Equal("teal", picture.Colour);
  }
  [Theory]
  [InlineData("")]
  [InlineData("person")]
  [InlineData("A")]
  [InlineData("👍👍")]
  public void PicturePickerRejectsNonEmojiAndMultiplePictures(string value) => Assert.Throws<ArgumentException>(() => AgentPictures.Emoji(value, "blue"));
  [Fact] public async Task DuplicateGetsNewIdentitySeatAndInstructionFileWithoutPriorRuns()
  {
    using var f = await Fixture.ReadyAsync(); var source = f.Agent(); source = f.Agents.SaveInstructions(source.Id, "Read these instructions.");
    var seat = f.Agents.SeatOf(source.Id); f.Agents.SaveSeatMemory(seat.Key, "Useful card", "Useful notes"); await f.Agents.StartAsync(new(source.Id));
    var copy = f.Agents.Duplicate(source.Id); Assert.NotEqual(source.Id, copy.Id); Assert.NotEqual(source.Seat, copy.Seat); Assert.Equal(source.ProjectId, copy.ProjectId);
    Assert.Equal("Read these instructions.", f.Agents.ReadInstructions(copy.Id)); Assert.NotEqual(source.InstructionsFile, copy.InstructionsFile); Assert.DoesNotContain(f.Agents.Runs(), r => r.AgentId == copy.Id);
    Assert.Equal("Useful card", f.Agents.Seats().Single(s => s.SeatKey == f.Agents.SeatOf(copy.Id).Key).Card);
    f.Agents.SaveInstructions(source.Id, "Original changed"); Assert.Equal("Read these instructions.", f.ReloadAgents().ReadInstructions(copy.Id));
  }
  [Fact] public async Task HireSavesTheChosenPictureInItsFirstProfileWrite()
  {
    using var f = await Fixture.ReadyAsync(); var agent = f.Agents.Hire("Picture", "codex", "", AgentCategory.Agent, "sample", icon: "emoji:🛠️@teal");
    Assert.Equal("emoji:🛠️@teal", f.ReloadAgents().Get(agent.Id).Icon);
  }
  [Fact] public async Task UnavailableSavedChoicesCanBeReadAndRenamedWithoutResettingThem()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent();
    var store = new TerminalDeck.Core.Storage.JsonStateStore<AgentState>(f.Root, "agents"); var state = store.Load()!;
    var saved = state.Agents.Single(row => row.Id == a.Id); var uncommon = saved with { Provider = "future-ai", Effort = "uncommon", Model = "kept-model" };
    store.Save(state with { Agents = state.Agents.Replace(saved, uncommon) }); var loaded = f.ReloadAgents();
    var renamed = loaded.Save(loaded.Get(a.Id) with { Name = "Renamed" }); Assert.Equal("future-ai", renamed.Provider); Assert.Equal("uncommon", renamed.Effort);
    await Assert.ThrowsAsync<ArgumentException>(async () => await loaded.StartAsync(new(a.Id)));
    Assert.Empty(loaded.Runs()); Assert.Empty(f.Gateway.Plans);
  }
  [Fact] public async Task SavedSkillsAreAdviceInTheBriefAndTurningThemOffRemovesThatAdvice()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); f.Agents.Save(a with { Skills = ["review-security", "missing-saved-skill"] });
    var run = await f.Agents.StartAsync(new(a.Id)); Assert.Contains("Saved skill references (advice", f.Gateway.Plans[0].Instructions); Assert.Contains("missing-saved-skill", f.Gateway.Plans[0].Instructions);
    f.Agents.EndHand(run.SessionId); f.Agents.Save(f.Agents.Get(a.Id) with { Skills = [] }); await f.Agents.StartAsync(new(a.Id)); Assert.DoesNotContain("Saved skill references", f.Gateway.Plans[1].Instructions);
  }
  [Fact] public async Task SavedProfileAndInstructionsRoundTripInTheChosenRoot()
  {
    using var f = await Fixture.ReadyAsync(); var agent = f.Agent(); agent = f.Agents.SaveInstructions(agent.Id, "Read the diff before reviewing it.");
    var loaded = f.ReloadAgents(); Assert.Equal("example-model", loaded.Get(agent.Id).Model); Assert.Equal("high", loaded.Get(agent.Id).Effort); Assert.Equal("Read the diff before reviewing it.", loaded.ReadInstructions(agent.Id)); Assert.StartsWith(f.Root.DirectoryPath, loaded.Get(agent.Id).InstructionsFile);
  }
  [Fact] public async Task ChangedInstructionFileCannotBeSilentlyOverwritten()
  {
    using var f = await Fixture.ReadyAsync(); var agent = f.Agent(); agent = f.Agents.SaveInstructions(agent.Id, "Original");
    var baseline = f.Agents.ReadInstructions(agent.Id); File.WriteAllText(agent.InstructionsFile!, "Changed outside the editor");
    Assert.Throws<InvalidOperationException>(() => f.Agents.SaveInstructions(agent.Id, "Unsaved draft", baseline));
    Assert.Equal("Changed outside the editor", f.Agents.ReadInstructions(agent.Id));
    f.Agents.SaveInstructions(agent.Id, "Explicit Keep mine"); Assert.Equal("Explicit Keep mine", f.Agents.ReadInstructions(agent.Id));
  }
  [Fact] public async Task CreateOnlySaveCannotOverwriteAnotherHire()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent();
    Assert.Throws<InvalidOperationException>(() => f.Agents.Save(a with { Name = "Collision" }, createOnly: true));
    Assert.Equal(a.Name, f.Agents.Get(a.Id).Name);
    f.Agents.Save(a with { Status = SavedAgentStatus.Archived }); f.Agents.Remove(a.Id);
    Assert.NotEqual(a.Id, f.Agents.NewId(a.Name));
  }
  [Fact] public async Task StaleMemoryAndTemplateEditorsCannotEraseNewerEdits()
  {
    using var f = await Fixture.ReadyAsync(); var agent = f.Agent(); var seat = f.Agents.SeatOf(agent.Id);
    var memory = f.Agents.SaveSeatMemory(seat.Key, "Card", "Notes"); f.Agents.SaveSeatMemory(seat.Key, "Card", "New notes");
    Assert.Throws<InvalidOperationException>(() => f.Agents.SaveSeatMemory(seat.Key, "Stale card draft", memory.Notes, memory));
    Assert.Equal("New notes", f.Agents.Seats().Single(s => s.SeatKey == seat.Key).Notes);
    var template = f.Agents.Templates().Single(t => t.Category == AgentCategory.Agent); f.Agents.SaveTemplate(template with { Instructions = "New template" });
    Assert.Throws<InvalidOperationException>(() => f.Agents.SaveTemplate(template with { Instructions = "Stale template" }, template));
    Assert.Equal("New template", f.Agents.Templates().Single(t => t.Category == AgentCategory.Agent).Instructions);
  }
  [Fact] public async Task AgentSettingsCannotOverwriteAChangedProfile()
  {
    using var f = await Fixture.ReadyAsync(); var original = f.Agent(); f.Agents.Save(original with { Description = "Saved elsewhere" });
    Assert.Throws<InvalidOperationException>(() => f.Agents.Save(original with { Name = "Stale editor" }, original));
    Assert.Equal("Saved elsewhere", f.Agents.Get(original.Id).Description); Assert.Equal(original.Name, f.Agents.Get(original.Id).Name);
  }
  [Fact] public async Task SelfReportsAndLongerLoopsAreRefused()
  {
    using var f = await Fixture.ReadyAsync(); var one = f.Agent("one"); var two = f.Agent("two");
    f.Agents.Save(one with { ReportsTo = two.Id }); Assert.Throws<ArgumentException>(() => f.Agents.Save(two with { ReportsTo = one.Id }));
    Assert.Throws<ArgumentException>(() => f.Agents.Save(two with { ReportsTo = two.Id })); Assert.Null(f.Agents.Get(two.Id).ReportsTo);
  }
  [Fact] public async Task OrgChartHasHootReportsAndIndependentRoots()
  {
    using var f = await Fixture.ReadyAsync(); var lead = f.Agent("lead"); f.Agents.Save(lead with { ReportsTo = AgentSeats.HootId }); var worker = f.Agent(); f.Agents.Save(worker with { ReportsTo = lead.Id });
    var independent = f.Agent("independent-worker"); var chart = f.Agents.OrgChart(); Assert.Equal(2, chart.Count); Assert.Equal(worker.Id, Assert.Single(chart.Single(t => t.Agent.Id == lead.Id).Reports).Agent.Id); Assert.Contains(chart, r => r.Agent.Id == independent.Id);
  }
  [Fact] public async Task RemovingAHireKeepsSeatMemoryForTheNextHire()
  {
    using var f = await Fixture.ReadyAsync(); var first = f.Agent("first", "review"); var seat = f.Agents.SeatOf(first.Id); f.Agents.SaveSeatMemory(seat.Key, "Check failure paths.", "Keep useful evidence."); f.Agents.Save(f.Agents.Get(first.Id) with { Status = SavedAgentStatus.Archived }); f.Agents.Remove(first.Id);
    var second = f.Agents.Hire("Next reviewer", "codex", "Reviews", AgentCategory.Agent, "sample", "review");
    await f.Agents.StartAsync(new(second.Id)); var plan = Assert.Single(f.Gateway.Plans); Assert.Contains("Check failure paths.", plan.Instructions); Assert.Contains("Keep useful evidence.", plan.Instructions);
    Assert.Equal(seat.Key, f.ReloadAgents().SeatOf(second.Id).Key);
  }
  [Fact] public async Task RehiringTheSameNameDoesNotInheritRunsOrInstructions()
  {
    using var f = await Fixture.ReadyAsync();
    var first = f.Agents.Hire("Reviewer", "codex", "", AgentCategory.Agent, "sample", "review");
    f.Agents.SaveInstructions(first.Id, "Private to this hire.");
    var run = await f.Agents.StartAsync(new(first.Id)); f.Agents.EndHand(run.SessionId); f.Agents.Save(f.Agents.Get(first.Id) with { Status = SavedAgentStatus.Archived }); f.Agents.Remove(first.Id);
    var loaded = f.ReloadAgents();
    var second = loaded.Hire("Reviewer", "codex", "", AgentCategory.Agent, "sample", "review");
    Assert.NotEqual(first.Id, second.Id); Assert.Empty(loaded.ReadInstructions(second.Id));
    Assert.DoesNotContain(loaded.Runs(), r => r.AgentId == second.Id);
    Assert.Contains(loaded.Runs(), r => r.AgentId == first.Id);
    Assert.Throws<ArgumentException>(() => loaded.Save(first));
  }
  [Fact] public async Task PermanentDeletionRequiresArchiveAndKeepsTheSeat()
  {
    using var f = await Fixture.ReadyAsync(); var agent = f.Agent(); var seat = f.Agents.SeatOf(agent.Id);
    Assert.Throws<ArgumentException>(() => f.Agents.Remove(agent.Id));
    f.Agents.Save(agent with { Status = SavedAgentStatus.Archived }); f.Agents.Remove(agent.Id);
    Assert.Empty(f.Agents.List()); Assert.Contains(f.Agents.Seats(), s => s.SeatKey == seat.Key);
  }
  [Fact] public async Task RetiredIdentityIsReservedEvenWithoutRuns()
  {
    using var f = await Fixture.ReadyAsync();
    var first = f.Agents.Hire("Reviewer", "codex", "", AgentCategory.Agent, "sample", "review");
    f.Agents.Save(f.Agents.Get(first.Id) with { Status = SavedAgentStatus.Archived }); f.Agents.Remove(first.Id);
    Assert.NotEqual(first.Id, f.ReloadAgents().Hire("Reviewer", "codex", "", AgentCategory.Agent, "sample", "review").Id);
  }
  [Fact] public async Task OccupiedRoleMustUseAnotherHandRatherThanAnotherProfile()
  {
    using var f = await Fixture.ReadyAsync(); f.Agent("one", "review"); Assert.Throws<ArgumentException>(() => f.Agent("two", "review")); Assert.Single(f.Agents.List());
  }
  [Fact] public async Task LeadSeatChangesWithProjectLeadAndRoleReturnsWhenDemoted()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); f.Agents.SetProjectLead("sample", a.Id); Assert.Equal("lead:sample", f.Agents.SeatOf(a.Id).Key);
    f.Agents.SetProjectLead("sample", null); Assert.Equal("role:sample/reviewer", f.Agents.SeatOf(a.Id).Key); Assert.Contains(f.Agents.Seats(), s => s.SeatKey == "lead:sample");
  }
  [Fact] public async Task HootIsTheOneOrchestratorAndFreshTemplatesHaveNoWorkCeilings()
  {
    using var f = await Fixture.ReadyAsync(); Assert.Equal(3, f.Agents.Templates().Count);
    Assert.Equal(0, f.Agents.Templates().Single(t => t.Category == AgentCategory.Lead).MaxHandsPerSeat); Assert.Equal(0, f.Agents.Templates().Single(t => t.Category == AgentCategory.Agent).MaxHandsPerSeat);
    Assert.Equal(0, f.Agents.Templates().Single(t => t.Category == AgentCategory.Agent).MaxHandsPerProject);
    Assert.Throws<ArgumentException>(() => f.Agents.Hire("Another Hoot", "codex", "", AgentCategory.Orchestrator, "sample"));
  }
  [Fact] public async Task NewTemplateAppliesToExistingAgentNextStart()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); var t = f.Agents.Templates().Single(t => t.Category == AgentCategory.Agent); f.Agents.SaveTemplate(t with { Instructions = "Use the shared review rules." });
    await f.Agents.StartAsync(new(a.Id)); Assert.Contains("Use the shared review rules.", Assert.Single(f.Gateway.Plans).Instructions);
  }
  [Theory] [InlineData("../unsafe")] [InlineData("Review Role")] [InlineData("role/slash")]
  public void RoleKeysCannotEscapeTheirMemoryFolder(string role) => Assert.Throws<ArgumentException>(() => AgentSeats.Role("sample", role));
  [Fact] public async Task SessionAndChatPlansCarryTheCompleteAgentChoice()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); f.Agents.SaveInstructions(a.Id, "Keep the scope small.");
    var terminal = await f.Agents.StartAsync(new(a.Id, Job: "Review one change")); var chat = await f.Agents.StartAsync(new(a.Id, Mode: "chat", Job: "Discuss it"));
    Assert.Equal(2, f.Gateway.Plans.Count);
    foreach (var plan in f.Gateway.Plans) { Assert.Equal(a.Id, plan.AgentId); Assert.Equal("codex", plan.Provider); Assert.Equal(a.Model, plan.Model); Assert.Equal(a.Effort, plan.Effort); Assert.Equal(f.Home, plan.Folder); Assert.Contains("Keep the scope small.", plan.Instructions); Assert.NotEmpty(plan.AccountId); }
    Assert.Equal("terminal", terminal.Mode); Assert.Equal("chat", chat.Mode); Assert.Equal(2, chat.HandNumber);
    Assert.Equal(a.Id, f.ReloadAgents().SessionFace(terminal.SessionId)?.Id);
  }
  [Fact] public async Task NoAgentShowsOnlyItsAIEvenWhenTheProjectHasALead()
  {
    using var f = await Fixture.ReadyAsync(); var lead = f.Agent(); f.Agents.SetProjectLead("sample", lead.Id);
    var run = await f.Agents.StartAsync(new(null, "sample", Provider: "codex")); Assert.Null(run.AgentId); Assert.Null(run.SeatKey); Assert.Null(f.Agents.SessionFace(run.SessionId)); Assert.Equal("Codex", f.Agents.SessionLabel(run.SessionId, "codex"));
    Assert.Empty(Assert.Single(f.Gateway.Plans).Instructions);
  }
  [Fact] public async Task ProjectAIAndAccountDefaultsAreActuallyUsed()
  {
    using var f = await Fixture.ReadyAsync(); var account = Assert.Single(f.Accounts.List("claude")); f.Projects.SetWhoUsesWhat("sample", [new("chats", "claude", account.Id)]);
    await f.Agents.StartAsync(new(null, "sample", Mode: "chat")); var plan = Assert.Single(f.Gateway.Plans); Assert.Equal("claude", plan.Provider); Assert.Equal(account.Id, plan.AccountId);
  }
  [Fact] public async Task SignedOutAccountCannotStartAProcess()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); f.Providers.Single(p => p.Provider == "codex").SignedIn = false;
    await Assert.ThrowsAsync<TerminalDeck.Core.Accounts.SignInRequiredException>(async () => await f.Agents.StartAsync(new(a.Id))); Assert.Empty(f.Gateway.Plans); Assert.Empty(f.Agents.Runs());
  }
  [Fact] public async Task WrongProviderAccountAndOutsideFolderAreRefused()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); var wrong = Assert.Single(f.Accounts.List("claude"));
    await Assert.ThrowsAsync<ArgumentException>(async () => await f.Agents.StartAsync(new(a.Id, AccountId: wrong.Id)));
    await Assert.ThrowsAsync<ArgumentException>(async () => await f.Agents.StartAsync(new(a.Id, Folder: f.Directory))); Assert.Empty(f.Gateway.Plans);
  }
  [Fact] public async Task LimitsStartOffAndAnExplicitLimitCountsExistingHands()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); Assert.Null(a.MaxConcurrentTasks);
    for (var i = 0; i < 5; i++) await f.Agents.StartAsync(new(a.Id));
    f.Agents.Save(f.Agents.Get(a.Id) with { MaxConcurrentTasks = 5 });
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Agents.StartAsync(new(a.Id)));
    f.Agents.Save(f.Agents.Get(a.Id) with { MaxConcurrentTasks = null }); await f.Agents.StartAsync(new(a.Id)); Assert.Equal(6, f.Gateway.Plans.Count);
  }
  [Fact] public async Task UncertainStartConsumesAnExplicitAgentSlot()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); f.Agents.Save(a with { MaxConcurrentTasks = 1 }); f.Gateway.LoseReply = true;
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Agents.StartAsync(new(a.Id)));
    Assert.Equal(AgentRunState.Uncertain, Assert.Single(f.Agents.Runs()).State); f.Gateway.LoseReply = false;
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Agents.StartAsync(new(a.Id))); Assert.Single(f.Gateway.Plans);
  }
  [Fact] public async Task HandLimitsCountPendingAndUncertainStartsAndExitFreesOneSlot()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent();
    f.Agents.SaveTemplate(f.Agents.Templates().Single(t => t.Category == AgentCategory.Agent) with { MaxHandsPerSeat = 3, MaxHandsPerProject = 12 });
    var first = await f.Agents.StartAsync(new(a.Id)); await f.Agents.StartAsync(new(a.Id)); await f.Agents.StartAsync(new(a.Id));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Agents.StartAsync(new(a.Id))); Assert.Equal(3, f.Gateway.Plans.Count);
    f.Agents.ReconcileSessions([new(first.SessionId, "Finished", "codex", f.Home, "Exited")]); var next = await f.Agents.StartAsync(new(a.Id)); Assert.Equal(4, next.HandNumber);
  }
  [Fact] public async Task LostStartReplyIsKeptAndProviderErrorIsNotShown()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); f.Gateway.LoseReply = true;
    var error = await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Agents.StartAsync(new(a.Id)));
    Assert.DoesNotContain("SYNTHETIC_PRIVATE_VALUE", error.Message); Assert.Equal(AgentRunState.Uncertain, Assert.Single(f.ReloadAgents().Runs()).State);
  }
  [Fact] public async Task PausedAgentAndActiveHireRemovalAreRefused()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); f.Agents.Save(a with { Status = SavedAgentStatus.Paused });
    await Assert.ThrowsAsync<ArgumentException>(async () => await f.Agents.StartAsync(new(a.Id))); f.Agents.Save(a); await f.Agents.StartAsync(new(a.Id));
    Assert.Throws<ArgumentException>(() => f.Agents.Remove(a.Id));
  }
  [Fact] public async Task HelperGetsASeparateShortLivedSeat()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); var hand = await f.Agents.StartAsync(new(a.Id, Helper: true)); Assert.Contains("--helper-", hand.SeatKey); Assert.NotEqual(f.Agents.SeatOf(a.Id).Key, hand.SeatKey);
  }
  [Fact] public async Task HelperNotesFoldIntoTheOriginalParentSeatOnlyOnce()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); var parent = f.Agents.SeatOf(a.Id).Key;
    var hand = await f.Agents.StartAsync(new(a.Id, Helper: true)); f.Agents.SaveSeatMemory(hand.SeatKey!, "", "A useful helper finding.");
    f.Agents.EndHand(hand.SessionId); f.Agents.EndHand(hand.SessionId);
    Assert.Equal("A useful helper finding.", f.Agents.Seats().Single(s => s.SeatKey == parent).Notes);
  }
  [Fact] public async Task NewLeadInheritsVacantLeadMemory()
  {
    using var f = await Fixture.ReadyAsync(); f.Agents.SaveSeatMemory("lead:sample", "Keep the project goals.", "Prior findings.");
    var a = f.Agents.Hire("New lead", "codex", "Leads", AgentCategory.Lead, "sample"); await f.Agents.StartAsync(new(a.Id));
    Assert.Contains("Keep the project goals.", Assert.Single(f.Gateway.Plans).Instructions); Assert.Contains("Prior findings.", f.Gateway.Plans[0].Instructions);
  }
  [Fact] public async Task ConcurrentHiresDoNotOverwriteOneAnother()
  {
    using var f = await Fixture.ReadyAsync(); await Task.WhenAll(Enumerable.Range(0, 5).Select(_ => Task.Run(() => f.Agents.Hire("Reviewer", "codex", "", AgentCategory.Agent, "sample"))));
    Assert.Equal(5, f.Agents.List().Count); Assert.Equal(5, f.Agents.List().Select(a => a.Id).Distinct().Count());
  }
  [Fact] public async Task PhonePictureSourceHasSavedAgentsAndNoLeadFallbackForPlainSessions()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); f.Agents.SetProjectLead("sample", a.Id);
    var explicitRun = await f.Agents.StartAsync(new(a.Id)); var plain = await f.Agents.StartAsync(new(null, "sample", Provider: "codex"));
    var picture = new ProjectsAgentsPictures(f.Projects, f.Agents).Read(_ => true, _ => true, [explicitRun.SessionId, plain.SessionId]);
    Assert.Equal(2, picture.Agents.Count); Assert.Equal(a.Id, Assert.Single(picture.Sessions).Value.Id); Assert.DoesNotContain(plain.SessionId, picture.Sessions.Keys);
  }
  [Fact] public async Task RevocationAfterAccountCheckStillStopsLaunch()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent();
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Agents.StartAsync(new(a.Id), beforeStart: (_, _) => throw new InvalidOperationException("Permission changed.")));
    Assert.Empty(f.Gateway.Plans);
  }
  [Fact] public async Task ProfileChangedDuringAccountCheckCannotLaunchOldSettings()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); var entered = new TaskCompletionSource(); var release = new TaskCompletionSource();
    f.Providers.Single(p => p.Provider == "codex").WaitForStatus = async ct => { entered.SetResult(); await release.Task.WaitAsync(ct); };
    var pending = f.Agents.StartAsync(new(a.Id)).AsTask(); await entered.Task; f.Agents.Save(a with { Model = "changed-model" }); release.SetResult();
    await Assert.ThrowsAsync<InvalidOperationException>(() => pending); Assert.Empty(f.Gateway.Plans);
  }
  [Fact] public async Task KeeperAdapterPassesRealSessionFieldsWithoutDroppingAgentSettings()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); await f.Agents.StartAsync(new(a.Id, Job: "Review this change")); var plan = Assert.Single(f.Gateway.Plans);
    TerminalDeck.Core.Sessions.SessionDefinition? captured = null;
    var adapter = new KeeperAgentSessionGateway((definition, _) =>
    {
      captured = definition; return ValueTask.FromResult(new TerminalDeck.Core.Sessions.SessionRecord(definition, "example", TerminalDeck.Core.Sessions.SessionState.Running));
    });
    var result = await adapter.StartAsync(plan, default);
    Assert.Equal(plan.SessionId, result.SessionId); Assert.Equal(plan.Model, captured?.Model); Assert.Equal("high", captured?.Effort); Assert.Contains("Review this change", captured?.InitialPrompt);
    Assert.Equal(plan.AccountHome, captured?.AccountHome);
  }
  [Fact] public async Task HelpersUseTheCategoryHelperAIModelAndChecklist()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); var t = f.Agents.Templates().Single(t => t.Category == AgentCategory.Agent);
    f.Agents.SaveTemplate(t with { HelperAI = "gemini", HelperModel = "example-helper", Checklist = "Bring back one concrete finding." });
    await f.Agents.StartAsync(new(a.Id, Helper: true)); var plan = Assert.Single(f.Gateway.Plans);
    Assert.Equal("gemini", plan.Provider); Assert.Equal("example-helper", plan.Model); Assert.Contains("Bring back one concrete finding.", plan.Instructions);
  }
  [Fact] public async Task KeeperAdapterRefusesUnsupportedSettingsBeforeStartingAnything()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); await f.Agents.StartAsync(new(a.Id)); var plan = Assert.Single(f.Gateway.Plans); var calls = 0;
    var adapter = new KeeperAgentSessionGateway((_, _) => { calls++; throw new InvalidOperationException(); });
    adapter.Validate(plan with { Effort = "max" }); // claude --effort and Codex accept max since 30 Oct
    Assert.Throws<ArgumentException>(() => adapter.Validate(plan with { Provider = "gemini", Effort = "high" }));
    Assert.Throws<ArgumentException>(() => adapter.Validate(plan with { Instructions = new string('x', 8001) }));
    Assert.Throws<InvalidOperationException>(() => adapter.Validate(plan with { Mode = "chat" })); Assert.Equal(0, calls);
  }
}
