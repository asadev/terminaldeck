using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.WhatsApp;

namespace TerminalDeck.Core.Tests.WhatsApp;

/// The Mac's WhatsAppEngineTests.swift (31 cases), case for case: the engine against WhatsAppFakeTransport, fake receivers
/// and a fake pair of computers sharing one synced settings store. No network, no Credential Manager, no screen. Keys are
/// made up.
public sealed class WhatsAppEngineTests : IDisposable
{
  private const string KeyA = "made-up-whatsapp-key-aaaaaaaaaaaaaaaa";
  private const string KeyB = "made-up-whatsapp-key-bbbbbbbbbbbbbbbb";
  private const string Refused = "made-up-whatsapp-key-refused";
  private const string Him = "user:1555000111";
  private readonly World w = new();
  public void Dispose() => w.Dispose();

  // ---- Profiles ----

  [Fact]
  public async Task ARefusedKeyAddsNothingAndTheFirstAcceptedOneIsReceivedByHoot()
  {
    var a = w.Engine(w.PcA);
    var refused = await Assert.ThrowsAsync<WhatsAppProblem>(() => a.AddAsync("Phone", Refused));
    Assert.Equal(WhatsAppProblem.KeyRefused.Message, refused.Message);
    Assert.Empty(await a.AgentsAsync());
    var first = await a.AddAsync("", KeyA);
    Assert.True(first.Name == "WhatsApp agent" && first.Receiver == WhatsAppReceiver.Hoot && first.State == WhatsAppAgentState.Waiting && first.Sending);
    var second = await a.AddAsync("", KeyB);
    Assert.True(second.Name == "WhatsApp agent 2" && second.Receiver == WhatsAppReceiver.Nowhere);
    a.Stop();
  }

  [Fact]
  public async Task AnyNumberOfAgentsCanBeAdded()
  {
    var a = w.Engine(w.PcA);
    for (var n = 0; n < 7; n++) await a.AddAsync("Agent " + n, "made-up-whatsapp-key-number-" + n);
    Assert.Equal(7, (await a.AgentsAsync()).Count);
    Assert.True(new WhatsAppAgentsStore().CanAdd);
    a.Stop();
  }

  [Fact]
  public async Task TheKeyIsNeverInTheSyncedRecordTheListOrAToolAnswer()
  {
    var a = w.Engine(w.PcA);
    var added = await a.AddAsync("Phone", KeyA);
    Assert.Equal(KeyA, await w.Keys.KeyAsync(added.Id));
    Assert.DoesNotContain(KeyA, string.Join("\n", (await w.Settings.RecordsAsync()).Select(r => r.ToJson())));
    Assert.DoesNotContain(KeyA, JsonSerializer.Serialize(await a.AgentsAsync()));
    Assert.DoesNotContain(KeyA, WhatsAppTools.Wire((await a.AgentsAsync())[0]).ToJsonString());
    using var args = JsonDocument.Parse("{\"apiKey\":\"" + KeyA + "\",\"name\":\"Phone\"}");
    Assert.DoesNotContain(KeyA, McpCallerAuthority.Describe(WhatsAppTools.AddId, args.RootElement));
    a.Stop();
  }

  // ---- Messages (the link, driven directly) ----

  [Fact]
  public async Task TheFirstConnectAnswersNothingFromTheBacklog()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Hoot, creator: null, offset: null));
    w.Wa.AddBacklog([w.Text("old-1", "hello from last week", ago: 3600), w.Text("old-2", "and this", ago: 60)]);
    var link = w.Link(box);
    link.Start();
    // The fake numbers its log from 1 (the Mac's scripted fake said next: 2): the head is the fake's next offset.
    await World.Until(() => box.Record.Offset == w.Wa.NextOffset);
    link.Stop();
    Assert.Equal(Him, box.Record.Creator);
    Assert.Empty(w.Wa.Sent);
    Assert.Empty(w.Receivers.Said);
  }

  [Fact]
  public async Task ATextBecomesAMessageInTheReceiverAndTheAnswerGoesBackFormattedAndSplit()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Hoot));
    var link = w.Link(box);
    w.Receivers.Turn = WhatsAppTurn.Done("t0", "an old answer");
    await link.TakeAsync(w.Text("m1", "what is running?"));
    Assert.Equal(new[] { "what is running?" }, w.Receivers.Said.Select(s => s.Text));
    Assert.Contains(w.Wa.Reads, r => r.MessageId == "m1" && r.Typing);
    w.Receivers.Turn = WhatsAppTurn.Working("t1");
    await link.LookAsync();
    var longText = new string('a', 5000);
    w.Receivers.Turn = WhatsAppTurn.Done("t1", longText);
    await link.LookAsync(); await link.LookAsync();
    await link.FlushedAsync();
    var sent = w.Wa.Sent;
    Assert.All(sent, s => Assert.Equal(Him, s.To));
    Assert.Equal(2, sent.Count);
    Assert.Equal(longText, string.Concat(sent.Select(s => s.Text)));
    Assert.DoesNotContain(sent, s => s.Text.Contains("an old answer"));
  }

  [Fact]
  public async Task EveryFinalAnswerGoesBackAlsoForAQuestionTypedOnThePc()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Session("s1", "CRM")));
    w.Receivers.Open(new("s1", false));
    w.Receivers.Turn = WhatsAppTurn.Idle("t0");
    var link = w.Link(box);
    await link.LookAsync();                                              // seeds: nothing old is sent
    w.Receivers.Turn = WhatsAppTurn.Done("t-pc", "Built.");
    await link.LookAsync(); await link.FlushedAsync();
    Assert.Equal(new[] { "Built." }, w.Wa.SentTexts);
  }

  [Fact]
  public async Task AnApprovalIsAskedOnceAndAnsweredWithOneOrTwo()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Hoot));
    var link = w.Link(box);
    w.Receivers.Turn = WhatsAppTurn.Idle("t0");
    await link.TakeAsync(w.Text("m1", "deploy it"));
    w.Receivers.Turn = WhatsAppTurn.Asking("t1", new WhatsAppApproval("r1", "It asks to use Bash.", "./deploy.sh prod"));
    await link.LookAsync(); await link.LookAsync(); await link.FlushedAsync();
    var asked = w.Wa.SentTexts;
    Assert.Single(asked);
    Assert.Contains("./deploy.sh prod", asked[0]);
    Assert.EndsWith("Reply 1 to allow, 2 to deny.", asked[0]);
    await link.TakeAsync(w.Text("m2", " 1 "));
    Assert.Equal(new[] { ("r1", true) }, w.Receivers.Approvals);
    Assert.Equal(new[] { "deploy it" }, w.Receivers.Said.Select(s => s.Text));   // "1" is not a message
    // Anything else is a normal message and the question stays open in Terminal Deck.
    w.Receivers.Turn = WhatsAppTurn.Asking("t1", new WhatsAppApproval("r2", "Write a file.", "a.txt"));
    await link.LookAsync();
    await link.TakeAsync(w.Text("m3", "what does it do?"));
    Assert.Equal("what does it do?", w.Receivers.Said[^1].Text);
    Assert.True(WhatsAppLink.ApprovalAnswer("deny") == false && WhatsAppLink.ApprovalAnswer("Allow") == true && WhatsAppLink.ApprovalAnswer("ok") is null);
  }

  [Fact]
  public async Task OneQuestionAtATimeAndAOneWrittenBeforeTheQuestionIsNotAnAnswer()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Hoot));
    var link = w.Link(box);
    w.Receivers.Turn = WhatsAppTurn.Idle("t0");
    await link.TakeAsync(w.Text("m1", "deploy and clean up"));
    var early = w.Text("m-early", "1", ago: 30);                         // written before any question was asked
    w.Receivers.Turn = WhatsAppTurn.Asking("t1", new WhatsAppApproval("r1", "Deploy.", "./deploy.sh"), new WhatsAppApproval("r2", "Delete.", "rm -rf build"));
    await link.LookAsync(); await link.LookAsync(); await link.FlushedAsync();
    Assert.Single(w.Wa.Sent);
    Assert.Contains("./deploy.sh", w.Wa.SentTexts[0]);                   // only the first
    await link.TakeAsync(early);
    Assert.Empty(w.Receivers.Approvals);                                 // too old: a normal message
    await link.TakeAsync(w.Text("m2", "1"));
    Assert.Equal(new[] { ("r1", true) }, w.Receivers.Approvals);
    w.Receivers.Turn = WhatsAppTurn.Asking("t1", new WhatsAppApproval("r2", "Delete.", "rm -rf build"));
    await link.LookAsync(); await link.FlushedAsync();
    Assert.Equal(2, w.Wa.Sent.Count);
    Assert.Contains("rm -rf build", w.Wa.SentTexts[1]);                  // the second, after the first
  }

  [Fact]
  public async Task APictureOrDocumentToATerminalIsNeverTyped()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Session("t1", "Shell")));
    w.Receivers.Open(new("t1", true));
    w.Wa.SetMedia("doc", new WhatsAppMedia(Encoding.UTF8.GetBytes("rm -rf ~\n"), "text/plain", "x.sh"));
    var link = w.Link(box);
    await link.TakeAsync(new WhatsAppInbound("m1", Him, w.Clock.Now, WhatsAppInboundKind.Document, Caption: "run this", MediaId: "doc", MimeType: "text/plain", FileName: "x.sh"));
    await link.FlushedAsync();
    Assert.Empty(w.Receivers.Typed);
    Assert.Equal(new[] { "A terminal takes text only here." }, w.Wa.SentTexts);
  }

  [Fact]
  public void ARedirectCarriesTheKeyOnlyToWhatsAppsAndMetasOwnHosts()
  {
    var hosts = WhatsAppHttpTransport.DefaultMediaHosts;
    Assert.True(WhatsAppRedirectGuard.Allowed(new Uri("https://lookaside.fbsbx.com/media/1"), hosts));
    Assert.True(WhatsAppRedirectGuard.Allowed(new Uri("https://api.whatsapp.com/agent/v1/x"), hosts));
    Assert.False(WhatsAppRedirectGuard.Allowed(new Uri("https://evil.example/collect"), hosts));
    Assert.False(WhatsAppRedirectGuard.Allowed(new Uri("http://lookaside.fbsbx.com/media/1"), hosts));
    Assert.False(WhatsAppRedirectGuard.Allowed(new Uri("https://whatsapp.com.evil.example/"), hosts));
  }

  [Fact]
  public async Task VoiceVideoAndStickerGetTheOnePlainLineAndAReactionIsIgnored()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Hoot));
    var link = w.Link(box);
    foreach (var (id, kind) in new[] { ("v", WhatsAppInboundKind.Audio), ("x", WhatsAppInboundKind.Video), ("s", WhatsAppInboundKind.Sticker), ("r", WhatsAppInboundKind.Reaction) })
      await link.TakeAsync(new WhatsAppInbound(id, Him, w.Clock.Now, kind, MediaId: "media-" + id));
    await link.FlushedAsync();
    Assert.Equal(Enumerable.Repeat("I read text, pictures and documents here.", 3), w.Wa.SentTexts);
    Assert.Empty(w.Receivers.Said);
  }

  [Fact]
  public async Task AMessageOlderThanADayIsMarkedReadAndAnsweredWithTheLateLine()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Hoot));
    var link = w.Link(box);
    await link.TakeAsync(w.Text("old", "are you there?", ago: 25 * 3600));
    await link.FlushedAsync();
    Assert.Equal(new[] { "This reached me late; send it again if you still need it." }, w.Wa.SentTexts);
    Assert.Contains(w.Wa.Reads, r => r.MessageId == "old" && !r.Typing);
    Assert.Empty(w.Receivers.Said);
  }

  [Fact]
  public async Task APictureArrivesAsAnAttachmentAndAnOtherDocumentKindIsSaidPlainly()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Hoot));
    var link = w.Link(box);
    w.Wa.SetMedia("pic", new WhatsAppMedia([0x89, 0x50, 0x4e, 0x47], "image/png"));
    await link.TakeAsync(new WhatsAppInbound("m1", Him, w.Clock.Now, WhatsAppInboundKind.Image, Caption: "this screen", MediaId: "pic", MimeType: "image/png"));
    var said = Assert.Single(w.Receivers.Said);
    Assert.Equal("this screen", said.Text);
    Assert.Equal("image/png", said.Attachments[0].MimeType);
    w.Wa.SetMedia("doc", new WhatsAppMedia([1, 2], "application/zip", "a.zip"));
    await link.TakeAsync(new WhatsAppInbound("m2", Him, w.Clock.Now, WhatsAppInboundKind.Document, MediaId: "doc", MimeType: "application/zip"));
    await link.FlushedAsync();
    Assert.Equal(new[] { "I read pictures, PDF and text documents here." }, w.Wa.SentTexts);
  }

  [Fact]
  public async Task OnlyTheCreatorIsEverWrittenTo()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Hoot));
    var link = w.Link(box);
    await link.TakeAsync(new WhatsAppInbound("x", "user:someone-else", w.Clock.Now, WhatsAppInboundKind.Text, Text: "hi"));
    await link.FlushedAsync();
    Assert.Empty(w.Wa.Sent);
    Assert.Empty(w.Receivers.Said);
  }

  // ---- The switch ----

  [Fact]
  public async Task WithTheSwitchOffNothingIsSentAndAMessageFromWhatsAppTurnsItOn()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Session("s1", "CRM")) with { Sending = false });
    w.Receivers.Open(new("s1", false));
    w.Receivers.Turn = WhatsAppTurn.Idle("t0");
    var link = w.Link(box);
    await link.LookAsync();
    w.Receivers.Turn = WhatsAppTurn.Asking("t1", new WhatsAppApproval("r1", "Run it.", "make"));
    await link.LookAsync();
    w.Receivers.Turn = WhatsAppTurn.Done("t1", "Done on the PC.");
    await link.LookAsync(); await link.FlushedAsync();
    Assert.Empty(w.Wa.Sent);                                             // off: no answer, no approval
    await link.TakeAsync(w.Text("m1", "and now?"));
    Assert.True(box.Record.IsSending);                                   // his WhatsApp message turned it on
    w.Receivers.Turn = WhatsAppTurn.Done("t2", "Now on WhatsApp.");
    await link.LookAsync(); await link.FlushedAsync();
    Assert.Equal(new[] { "Now on WhatsApp." }, w.Wa.SentTexts);
  }

  [Fact]
  public async Task AttachingTurnsTheSwitchOnAndTheSwitchIsSynced()
  {
    var a = w.Engine(w.PcA); var b = w.Engine(w.PcB);
    var added = await a.AddAsync("Phone", KeyA);
    await a.SetSendingAsync(false, added.Id);
    Assert.False((await b.AgentsAsync())[0].Sending);                    // the other computer reads the same setting
    await a.SetReceiverAsync(added.Id, WhatsAppReceiver.Session("s1", "CRM"));
    Assert.True((await b.AgentsAsync())[0].Sending);
    a.Stop(); b.Stop();
  }

  // ---- Sessions and terminals ----

  [Fact]
  public async Task AnEndedSessionGoesNowhereAndTheNextMessageIsAnsweredOnce()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Session("s1", "CRM")));
    w.Receivers.Open(new("s1", false));
    var link = w.Link(box);
    await link.LookAsync();
    w.Receivers.Close("s1");
    await link.LookAsync();
    Assert.True(box.Record.Receiver == WhatsAppReceiver.Nowhere && box.Record.EndedSession);
    await link.TakeAsync(w.Text("m1", "status?"));
    await link.TakeAsync(w.Text("m2", "status??"));
    await link.FlushedAsync();
    var sent = w.Wa.SentTexts;
    Assert.Equal("That session has ended. Choose where I should answer in Terminal Deck.", sent[0]);
    Assert.Single(sent, s => s.Contains("session has ended"));
  }

  [Fact]
  public async Task ATerminalSessionTakesTheTextAsTypedInputAndSendsBackWhatItPrinted()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Session("t1", "Shell")));
    w.Receivers.Open(new("t1", true));
    w.Receivers.Screens = ["$ ", "$ ls\nREADME.md\nsrc\n$ "];
    var link = w.Link(box);
    await link.TakeAsync(w.Text("m1", "ls"));
    await link.FlushedAsync();
    Assert.Equal(new[] { "ls\r" }, w.Receivers.Typed);
    var sent = w.Wa.SentTexts[0];
    Assert.True(sent.Contains("README.md") && sent.Contains("src") && sent.StartsWith("```", StringComparison.Ordinal));
    Assert.Equal(40, WhatsAppLink.NewLines("a\n", "a\n" + string.Join("\n", Enumerable.Range(1, 60))).Split('\n').Length);
  }

  // ---- One reader per agent across computers ----

  [Fact]
  public async Task OnlyTheComputerWhereItWasAttachedReadsIt()
  {
    var a = w.Engine(w.PcA); var b = w.Engine(w.PcB);
    var added = await a.AddAsync("Phone", KeyA);
    await a.ReconcileAsync(); await b.ReconcileAsync();
    Assert.Equal(new[] { added.Id }, a.ReadHere()); Assert.Empty(b.ReadHere());
    Assert.Equal("Answered by PC A", (await b.AgentsAsync())[0].AnsweredElsewhereWords);
    // Moving the receiver moves the reader.
    await b.SetReceiverAsync(added.Id, WhatsAppReceiver.Hoot);
    await a.ReconcileAsync(); await b.ReconcileAsync();
    Assert.Empty(a.ReadHere()); Assert.Equal(new[] { added.Id }, b.ReadHere());
    a.Stop(); b.Stop();
  }

  [Fact]
  public async Task TwoAgentsWithDifferentReceiversAreReadByTheirOwnComputers()
  {
    var a = w.Engine(w.PcA); var b = w.Engine(w.PcB);
    var one = await a.AddAsync("Work", KeyA);
    var two = await b.AddAsync("Home", KeyB);
    await b.SetReceiverAsync(two.Id, WhatsAppReceiver.Session("s9", "Notes"));
    await a.ReconcileAsync(); await b.ReconcileAsync();
    Assert.Equal(new[] { one.Id }, a.ReadHere()); Assert.Equal(new[] { two.Id }, b.ReadHere());
    a.Stop(); b.Stop();
  }

  [Fact]
  public async Task AHootReceiverIsTakenOverAfterTenMinutesButASessionNever()
  {
    var a = w.Engine(w.PcA); var b = w.Engine(w.PcB);
    var hoot = await a.AddAsync("Phone", KeyA);
    var session = await a.AddAsync("Build", KeyB);
    await a.SetReceiverAsync(session.Id, WhatsAppReceiver.Session("s1", "CRM"));
    a.Stop();
    w.Seen["a"] = w.Clock.Now.AddMinutes(-9);
    await b.ReconcileAsync();
    Assert.Empty(b.ReadHere());                                          // 9 minutes: not yet
    w.Seen["a"] = w.Clock.Now.AddMinutes(-11);
    await b.ReconcileAsync();
    Assert.Equal(new[] { hoot.Id }, b.ReadHere());                       // Hoot moves; the session does not
    var row = (await b.AgentsAsync()).Single(p => p.Id == hoot.Id);
    Assert.True(row.AnsweredHere && row.TakenOver);
    b.Stop();
  }

  [Fact]
  public async Task A409WhileStillTheReaderPollsAgainAndAnotherNamedReaderStopsIt()
  {
    var a = w.Engine(w.PcA);
    var added = await a.AddAsync("Phone", KeyA);
    await w.Settings.EditAsync(added.Id, r => r with { Offset = 7, Creator = Him });
    w.Wa.ReplaceNextPoll();
    var before = w.Wa.Polls.Count;
    await World.Until(() => w.Wa.Polls.Count > before + 3);              // review fault 2: it polls again, never held forever
    Assert.Equal(new[] { added.Id }, a.ReadHere());
    await w.Settings.EditAsync(added.Id, r => r with { ReaderId = "b", ReaderName = "PC B" });
    w.Wa.ReplaceNextPoll();
    await World.Until(() => a.ReadHere().Count == 0);                    // the record names B: this one stops
    a.Stop();
  }

  [Fact]
  public async Task ABatchIsNotAnsweredOnceTheRecordNamesAnotherComputer()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Hoot) with { ReaderId = "b" });
    var stops = new List<WhatsAppLink.StopReason>();
    var link = new WhatsAppLink("wa-1", KeyA, w.Wa, w.Receivers, w.Clock,
      read: () => Task.FromResult<WhatsAppAgentRecord?>(box.Record), update: change => { box.Edit(change); return Task.CompletedTask; },
      stopped: why => { lock (stops) stops.Add(why); return Task.CompletedTask; },
      stillReader: () => Task.FromResult(box.Record.ReaderId == "a"));
    w.Wa.ScriptPolls([new WhatsAppPoll.Messages([w.Text("m1", "run the deploy")], 6)]);
    link.Start();
    await World.Until(() => { lock (stops) return stops.Count == 1; });
    Assert.Empty(w.Receivers.Said); Assert.Empty(w.Wa.Sent);
    Assert.Equal(5, box.Record.Offset);
    link.Stop();
  }

  [Fact]
  public async Task AReplacedKeyIsReadOnlyWithTheNewKeyAndStartsFresh()
  {
    var keysA = new WhatsAppKeysInMemory(); var keysB = new WhatsAppKeysInMemory();
    var a = w.Engine(w.PcA, keysA); var b = w.Engine(w.PcB, keysB);
    var added = await a.AddAsync("Phone", KeyA);
    await w.Settings.EditAsync(added.Id, r => r with { Offset = 7, Creator = Him });
    await keysB.SetKeyAsync(KeyA, added.Id);
    Assert.Equal(WhatsAppAgentIds.Fingerprint(KeyA), a.Link(added.Id)?.KeyId);
    await b.ReplaceKeyAsync(added.Id, KeyB);                             // pressed on the other PC
    var record = Assert.Single(await w.Settings.RecordsAsync());
    Assert.True(record.KeyId == WhatsAppAgentIds.Fingerprint(KeyB) && record.Creator is null && record.Offset is null);
    Assert.DoesNotContain(KeyB, record.ToJson());
    await a.ReconcileAsync();
    Assert.Empty(a.ReadHere());                                          // the new key has not arrived here: not read
    await keysA.SetKeyAsync(KeyB, added.Id);                             // it arrives through saved passwords
    await a.ReconcileAsync();
    Assert.Equal(WhatsAppAgentIds.Fingerprint(KeyB), a.Link(added.Id)?.KeyId);
    a.Stop(); b.Stop();
  }

  [Fact]
  public async Task ARefusedKeyWhileReadingTurnsTheRowOrangeUntilANewKey()
  {
    var a = w.Engine(w.PcA);
    var added = await a.AddAsync("Phone", KeyA);
    await w.Settings.EditAsync(added.Id, r => r with { Offset = 7 });
    w.Wa.ScriptPolls([WhatsAppPoll.Refused]);
    await a.ReconcileAsync();
    await World.Until(async () => (await a.AgentsAsync())[0].State == WhatsAppAgentState.Refused);
    var refused = await Assert.ThrowsAsync<WhatsAppProblem>(() => a.ReplaceKeyAsync(added.Id, Refused));
    Assert.Equal(WhatsAppProblem.KeyRefused.Message, refused.Message);
    await a.ReplaceKeyAsync(added.Id, KeyB);
    Assert.Equal(WhatsAppAgentState.Waiting, (await a.AgentsAsync())[0].State);
    Assert.Equal(KeyB, await w.Keys.KeyAsync(added.Id));
    a.Stop();
  }

  [Fact]
  public async Task SendsGoOneAfterAnotherInOrder()
  {
    var box = new RecordBox(Rec(WhatsAppReceiver.Hoot));
    var slow = new SlowTransport(w.Wa);
    var link = new WhatsAppLink("wa-1", KeyA, slow, w.Receivers, w.Clock,
      read: () => Task.FromResult<WhatsAppAgentRecord?>(box.Record), update: change => { box.Edit(change); return Task.CompletedTask; }, stopped: _ => Task.CompletedTask);
    for (var n = 1; n <= 5; n++) link.Send("piece " + n, Him, format: false);
    await link.FlushedAsync();
    Assert.Equal(Enumerable.Range(1, 5).Select(n => "piece " + n), w.Wa.SentTexts);
    Assert.Equal(1, slow.MostAtOnce);
  }

  // ---- The store "whatsapp" (keys travel) ----

  [Fact]
  public async Task AKeyTravelsIsOneItemWhenTheSameAndHisStaysWhenDifferent()
  {
    var keysA = new WhatsAppKeysInMemory(new Dictionary<string, string> { ["wa-aaaa"] = KeyA }); var keysB = new WhatsAppKeysInMemory();
    var a = w.Wrap(new WhatsAppKeysStore(keysA, _ => Task.FromResult<string?>("Phone")).DeleteRuleOwner(w.State("A"), () => true, now: w.NowMs));
    var b = w.Wrap(new WhatsAppKeysStore(keysB).DeleteRuleOwner(w.State("B"), () => true, now: w.NowMs));
    var record = Assert.Single(await a.CaptureAsync());
    Assert.Equal(CloudApplyStatus.Applied, await b.MergeAsync(record));
    Assert.Equal(KeyA, await keysB.KeyAsync("wa-aaaa"));
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await b.MergeAsync(record));
    var other = new WhatsAppKeysInMemory(new Dictionary<string, string> { ["wa-aaaa"] = KeyB });
    var c = w.Wrap(new WhatsAppKeysStore(other).DeleteRuleOwner(w.State("C"), () => true, now: w.NowMs));
    Assert.Equal(CloudApplyStatus.KeptBoth, await c.MergeAsync(record));
    Assert.Equal(KeyB, await other.KeyAsync("wa-aaaa"));                 // never overwritten
  }

  [Fact]
  public async Task AKeyReplacedOnOneComputerReplacesTheUnchangedOneOnTheOther()
  {
    var keysA = new WhatsAppKeysInMemory(new Dictionary<string, string> { ["wa-aaaa"] = KeyA }); var keysB = new WhatsAppKeysInMemory();
    var a = w.Wrap(new WhatsAppKeysStore(keysA).DeleteRuleOwner(w.State("A"), () => true, now: w.NowMs));
    var b = w.Wrap(new WhatsAppKeysStore(keysB).DeleteRuleOwner(w.State("B"), () => true, now: w.NowMs));
    foreach (var record in await a.CaptureAsync()) _ = await b.MergeAsync(record);
    _ = await b.CaptureAsync();
    await keysA.SetKeyAsync(KeyB, "wa-aaaa");
    var changed = Assert.Single(await a.CaptureAsync());
    Assert.Equal(CloudApplyStatus.Applied, await b.MergeAsync(changed));
    Assert.Equal(KeyB, await keysB.KeyAsync("wa-aaaa"));
  }

  [Fact]
  public async Task AKeyRemovedInTheAppIsRemovedEverywhere()
  {
    var keysA = new WhatsAppKeysInMemory(new Dictionary<string, string> { ["wa-aaaa"] = KeyA }); var keysB = new WhatsAppKeysInMemory();
    var a = w.Wrap(new WhatsAppKeysStore(keysA, _ => Task.FromResult<string?>("Phone")).DeleteRuleOwner(w.State("A"), () => true, now: w.NowMs));
    var b = w.Wrap(new WhatsAppKeysStore(keysB).DeleteRuleOwner(w.State("B"), () => true, now: w.NowMs));
    foreach (var record in await a.CaptureAsync()) _ = await b.MergeAsync(record);
    _ = await b.CaptureAsync();
    var item = Assert.Single(await a.ItemsAsync());
    Assert.Equal("WhatsApp · Phone", item.Name);
    Assert.DoesNotContain(KeyA, item.Name);
    await a.DeleteItemsAsync([item], CloudDeleteScope.Everywhere, w.Actor());
    Assert.Equal(CloudApplyStatus.Applied, await b.MergeRemovalAsync(Assert.Single(await a.CaptureRemovalsAsync())));
    Assert.Null(await keysB.KeyAsync("wa-aaaa"));
  }

  [Fact]
  public async Task AKeeperThatIsNotReadySaysLockedNeverEmpty()
  {
    var keys = new WhatsAppKeysInMemory(new Dictionary<string, string> { ["wa-aaaa"] = KeyA }, ready: false);
    var store = new WhatsAppKeysStore(keys);
    var locked = await Assert.ThrowsAsync<CloudFailure>(() => store.CaptureAsync());
    Assert.Equal("secrets_locked", locked.Code);
    Assert.True(CloudSecretsDomains.Admitted(WhatsAppKeysStore.Source, CloudSecretsDomains.WhatsApp));
    var line = CloudShelfSealed.Password(new CloudShelfSealedRecord("whatsapp", "wa-aaaa", "whatsapp", new WhatsAppKeyValue(KeyA, "Phone").ToJson()));
    Assert.NotNull(line);
    Assert.Equal("WhatsApp · Phone", line!.Name);
    Assert.All(line.Fields, f => Assert.True(f.Label != "Key" || f.Secret));
  }

  [Fact]
  public void TheToolsAreSuppliedWholeAndAskWhereTheyShould()
  {
    Assert.Equal(8, WhatsAppTools.Specs.Count);
    var tiers = WhatsAppTools.Specs.ToDictionary(s => s.Id, s => s.Tier);
    Assert.Equal(McpTier.Read, tiers[WhatsAppTools.AgentsId]);
    foreach (var id in new[] { WhatsAppTools.AddId, WhatsAppTools.RemoveId, WhatsAppTools.RenameId, WhatsAppTools.ReplaceKeyId }) Assert.Equal(McpTier.Alter, tiers[id]);
    foreach (var id in new[] { WhatsAppTools.ReceiveId, WhatsAppTools.SendId, WhatsAppTools.SendingId }) Assert.Equal(McpTier.Act, tiers[id]);
    // In the app's one catalogue, so the door can register them.
    var catalogue = McpCatalogue.Load().Select(s => s.Id).ToHashSet();
    Assert.All(WhatsAppTools.Specs, s => Assert.Contains(s.Id, catalogue));
  }

  // ---- helpers ----

  private static WhatsAppAgentRecord Rec(WhatsAppReceiver receiver, string? creator = Him, long? offset = 5) => new()
  {
    Id = "wa-1", Name = "Phone", Receiver = receiver, ReaderId = "a", Creator = creator, Offset = offset, AddedAt = 0,
  };
}

// ---- Fakes ----

/// Virtual time that also yields a moment of real time on every wait, so the background loops never spin.
internal sealed class TestClock : IWhatsAppClock
{
  private readonly Lock gate = new();
  private DateTimeOffset now = DateTimeOffset.FromUnixTimeSeconds(1_900_000_000);
  public DateTimeOffset Now { get { lock (gate) return now; } }
  public void Advance(TimeSpan by) { lock (gate) now += by; }
  public async Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
  {
    if (delay > TimeSpan.Zero) Advance(delay);
    await Task.Delay(1, cancellationToken);
  }
}

/// The fake WhatsApp with each send taking a moment of real time, counting how many run at once.
internal sealed class SlowTransport(WhatsAppFakeTransport inner) : IWhatsAppTransport
{
  private int sending, most;
  public int MostAtOnce => Volatile.Read(ref most);
  public Task<WhatsAppKeyCheck> CheckAsync(string key, CancellationToken ct = default) => inner.CheckAsync(key, ct);
  public Task<WhatsAppPoll> PollAsync(string key, long? offset, int timeout, CancellationToken ct = default) => inner.PollAsync(key, offset, timeout, ct);
  public Task<WhatsAppSent> MarkReadAsync(string key, string messageId, bool typing, CancellationToken ct = default) => inner.MarkReadAsync(key, messageId, typing, ct);
  public Task<WhatsAppMedia?> MediaAsync(string key, string id, long limit, CancellationToken ct = default) => inner.MediaAsync(key, id, limit, ct);
  public async Task<WhatsAppSent> SendAsync(string key, string to, string text, CancellationToken ct = default)
  {
    var now = Interlocked.Increment(ref sending);
    int seen; do { seen = Volatile.Read(ref most); } while (now > seen && Interlocked.CompareExchange(ref most, now, seen) != seen);
    await Task.Delay(3, ct);
    try { return await inner.SendAsync(key, to, text, ct); } finally { Interlocked.Decrement(ref sending); }
  }
}

internal sealed class FakeReceivers : IWhatsAppReceiverPort
{
  public sealed record SaidMessage(string Text, IReadOnlyList<WhatsAppAttachment> Attachments);
  private readonly Lock gate = new();
  private readonly List<SaidMessage> said = [];
  private readonly List<(string, bool)> approvals = [];
  private readonly List<string> typed = [];
  private readonly Dictionary<string, WhatsAppTarget> open = new(StringComparer.Ordinal);
  public WhatsAppTurn Turn { get; set; } = WhatsAppTurn.Idle(null);
  public string[] Screens { get; set; } = [];
  public IReadOnlyList<SaidMessage> Said { get { lock (gate) return said.ToArray(); } }
  public IReadOnlyList<(string, bool)> Approvals { get { lock (gate) return approvals.ToArray(); } }
  public IReadOnlyList<string> Typed { get { lock (gate) return typed.ToArray(); } }
  public void Open(WhatsAppTarget target) { lock (gate) open[target.SessionId] = target; }
  public void Close(string id) { lock (gate) open.Remove(id); }

  public Task<WhatsAppTarget?> TargetAsync(WhatsAppReceiver receiver, string conversationName, string agentId)
  {
    lock (gate)
      return Task.FromResult<WhatsAppTarget?>(receiver.Kind switch
      {
        WhatsAppReceiverKind.Hoot => new("hoot-" + agentId, false),
        WhatsAppReceiverKind.Agent => new("agent-" + receiver.Id, false),
        WhatsAppReceiverKind.Session => open.GetValueOrDefault(receiver.Id),
        _ => null,
      });
  }
  public Task SayAsync(WhatsAppTarget target, string text, IReadOnlyList<WhatsAppAttachment> attachments) { lock (gate) said.Add(new(text, attachments)); return Task.CompletedTask; }
  public Task<WhatsAppTurn?> TurnAsync(WhatsAppTarget target) => Task.FromResult<WhatsAppTurn?>(Turn);
  public Task<bool> ApproveAsync(WhatsAppTarget target, string approvalId, bool allow)
  {
    if (Turn.Kind != WhatsAppTurnKind.NeedsApproval || Turn.Waiting.All(a => a.Id != approvalId)) return Task.FromResult(false);
    lock (gate) approvals.Add((approvalId, allow));
    return Task.FromResult(true);
  }
  public Task TypeAsync(WhatsAppTarget target, string text) { lock (gate) typed.Add(text); return Task.CompletedTask; }
  /// Before anything is typed: the first screen; after: the last (what the command printed).
  public Task<string?> ScreenAsync(WhatsAppTarget target) { lock (gate) return Task.FromResult<string?>(typed.Count == 0 ? Screens.FirstOrDefault() : Screens.LastOrDefault()); }
  public Task<bool> IsOpenAsync(WhatsAppTarget target)
  {
    lock (gate) return Task.FromResult(target.SessionId.StartsWith("hoot-", StringComparison.Ordinal) || target.SessionId.StartsWith("agent-", StringComparison.Ordinal) || open.ContainsKey(target.SessionId));
  }
  public Task<bool> IsToolSessionAsync(WhatsAppTarget target, string sessionId) => Task.FromResult(false);
}

/// The synced settings both computers share, through the Mac's JSON (as the synced setting is).
internal sealed class SharedSettings : IWhatsAppSettingsPort
{
  private readonly WhatsAppSettingsFile file = new(null);
  public Task<IReadOnlyList<WhatsAppAgentRecord>> RecordsAsync() => file.RecordsAsync();
  public Task SaveAsync(WhatsAppAgentRecord record) => file.SaveAsync(record);
  public void Observe(Action changed) => file.Observe(changed);
  /// Changes a record without telling anyone (as the Mac's test settings' edit).
  public async Task EditAsync(string id, Func<WhatsAppAgentRecord, WhatsAppAgentRecord> change)
  {
    var record = (await file.RecordsAsync()).Single(r => r.Id == id);
    var key = WhatsAppSettingsFile.Prefix + id;
    file.CloudWrite(key, CloudJson.From(change(record).ToJson()));
  }
}

internal sealed class Presence(WhatsAppComputer me, Dictionary<string, DateTimeOffset> seen) : IWhatsAppPresencePort
{
  public WhatsAppComputer ThisComputer() => me;
  public Task<DateTimeOffset?> LastSeenAsync(string computerId) { lock (seen) return Task.FromResult<DateTimeOffset?>(seen.TryGetValue(computerId, out var at) ? at : null); }
  public Task<string?> NameAsync(string computerId) => Task.FromResult(computerId switch { "a" => (string?)"PC A", "b" => "PC B", _ => null });
}

internal sealed class RecordBox(WhatsAppAgentRecord record)
{
  private readonly Lock gate = new();
  private WhatsAppAgentRecord current = record;
  public WhatsAppAgentRecord Record { get { lock (gate) return current; } }
  public void Edit(Func<WhatsAppAgentRecord, WhatsAppAgentRecord> change) { lock (gate) current = change(current); }
}

internal sealed class World : IDisposable
{
  public readonly TestClock Clock = new();
  public readonly WhatsAppFakeTransport Wa;
  public readonly FakeReceivers Receivers = new();
  public readonly SharedSettings Settings = new();
  public readonly WhatsAppKeysInMemory Keys = new();
  public readonly Dictionary<string, DateTimeOffset> Seen = [];
  public readonly WhatsAppComputer PcA = new("a", "PC A"), PcB = new("b", "PC B");
  private readonly string root = Path.Combine(Path.GetTempPath(), "td-whatsapp-keys-" + Guid.NewGuid().ToString("N"));
  private long ms = 1_900_000_000_000;
  private static readonly CloudSecretsStoreKeys StoreKeys = new(1, RandomNumberGenerator.GetBytes(32), RandomNumberGenerator.GetBytes(32));

  public World()
  {
    Wa = new WhatsAppFakeTransport("user:1555000111");
    Wa.Refuse("made-up-whatsapp-key-refused");
  }
  public void Dispose() { try { Directory.Delete(root, true); } catch (Exception) { } }

  public WhatsAppAgents Engine(WhatsAppComputer me, WhatsAppKeysInMemory? keys = null) =>
    new(Wa, Settings, keys ?? Keys, new Presence(me, Seen), Receivers, Clock);
  public WhatsAppLink Link(RecordBox box) =>
    new("wa-1", "made-up-whatsapp-key-aaaaaaaaaaaaaaaa", Wa, Receivers, Clock,
      read: () => Task.FromResult<WhatsAppAgentRecord?>(box.Record), update: change => { box.Edit(change); return Task.CompletedTask; }, stopped: _ => Task.CompletedTask);
  public WhatsAppInbound Text(string id, string body, double ago = 0) =>
    new(id, "user:1555000111", Clock.Now.AddSeconds(-ago), WhatsAppInboundKind.Text, Text: body);

  /// Waits (real time, at most 4 s) for something the background loop does.
  public static async Task Until(Func<bool> condition)
  {
    for (var i = 0; i < 800; i++) { if (condition()) return; await Task.Delay(5); }
    Assert.Fail("The condition was not reached in time.");
  }
  public static async Task Until(Func<Task<bool>> condition)
  {
    for (var i = 0; i < 800; i++) { if (await condition()) return; await Task.Delay(5); }
    Assert.Fail("The condition was not reached in time.");
  }

  public string State(string pc) => Path.Combine(root, pc, "state");
  public long NowMs() => ms += 1000;
  public CloudSecretsDeleteOwner Wrap(CloudSecretsDeleteOwner owner) { owner.UseKeys(StoreKeys); return owner; }
  public CloudDeleteActor Actor() => new(CloudDeleteBy.Person, "a", "PC A", null, null, NowMs(), Guid.NewGuid().ToString("D"));
}
