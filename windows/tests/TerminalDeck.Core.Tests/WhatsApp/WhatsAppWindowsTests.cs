using System.Text.Json.Nodes;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.WhatsApp;

namespace TerminalDeck.Core.Tests.WhatsApp;

/// What Windows adds around the Mac's engine: the synced record is the Mac's own JSON (golden lines printed by the Mac's
/// Swift Codable), the records travel as the Mac's settings `setting:whatsapp.agent.<id>`, and a terminal's replay is read
/// as plain text.
public sealed class WhatsAppWindowsTests
{
  // Printed by swiftc from the Mac's WhatsAppAgentRecord / WhatsAppReceiver shapes (sorted keys).
  private static readonly string[] Golden =
  [
    """{"addedAt":1763200000000,"creator":"user:1","endedSession":false,"id":"wa-1","keyID":"0123456789abcdef","lastMessageAt":1763200000123,"name":"Phone","offset":7,"readerID":"a","readerName":"Mac A","receiver":{"hoot":{}},"refused":false,"removed":false,"sending":true,"takenOver":false}""",
    """{"addedAt":5,"endedSession":true,"id":"wa-2","name":"Build","receiver":{"session":{"id":"s1","name":"CRM"}},"refused":true,"removed":true,"sending":false,"takenOver":true}""",
    """{"addedAt":0,"endedSession":false,"id":"wa-3","name":"N","receiver":{"nowhere":{}},"refused":false,"removed":false,"takenOver":false}""",
    // 16 Nov: the session's Cloud id (lane/mac-whatsapp-follow aabe9266c, BackendWhatsAppPorts.swift `cloudSessionID`).
    """{"addedAt":1763200000000,"cloudSessionID":"cloud-s-1","creator":"user:1","endedSession":false,"id":"wa-5","keyID":"0123456789abcdef","lastMessageAt":1763200000123,"name":"Phone","offset":7,"readerID":"a","readerName":"Mac A","receiver":{"session":{"id":"s1","name":"CRM"}},"refused":false,"removed":false,"sending":false,"takenOver":false}""",
  ];

  [Fact]
  public void TheSessionsCloudIdIsReadAndSavedAsTheMacWritesIt()
  {
    var mac = WhatsAppAgentRecord.FromJson(Golden[3])!;
    Assert.Equal("cloud-s-1", mac.CloudSessionId);
    var saved = mac.ToJson();
    // The Mac's own field order (Codable declaration order: cloudSessionID last, after keyID); the same bytes on every re-save.
    Assert.EndsWith(",\"keyID\":\"0123456789abcdef\",\"cloudSessionID\":\"cloud-s-1\"}", saved);
    Assert.Equal(saved, WhatsAppAgentRecord.FromJson(saved)!.ToJson());
    // Without it: absent, never null or empty, and the old bytes unchanged.
    var plain = WhatsAppAgentRecord.FromJson(Golden[0])!;
    Assert.Null(plain.CloudSessionId);
    Assert.DoesNotContain("cloudSessionID", plain.ToJson());
    Assert.Equal(plain.ToJson(), (plain with { CloudSessionId = "c" }).ToJson().Replace(",\"cloudSessionID\":\"c\"", ""));
  }

  [Fact]
  public void TheSyncedRecordIsTheMacsOwnJson()
  {
    foreach (var line in Golden)
    {
      var record = WhatsAppAgentRecord.FromJson(line);
      Assert.NotNull(record);
      Assert.True(JsonNode.DeepEquals(JsonNode.Parse(line), JsonNode.Parse(record!.ToJson())), line);
    }
    var first = WhatsAppAgentRecord.FromJson(Golden[0])!;
    Assert.True(first.Receiver == WhatsAppReceiver.Hoot && first.Offset == 7 && first.KeyId == "0123456789abcdef" && first.IsSending);
    var second = WhatsAppAgentRecord.FromJson(Golden[1])!;
    Assert.True(second.Receiver.SameTarget(WhatsAppReceiver.Session("s1", "")) && second.Receiver.Name == "CRM" && !second.IsSending && second.Creator is null);
    Assert.True(WhatsAppAgentRecord.FromJson(Golden[2])!.IsSending);       // no "sending" = on, as on the Mac
    Assert.Null(WhatsAppAgentRecord.FromJson("""{"id":"wa-4","name":"x","receiver":{"hoot":{}}}"""));   // required fields missing
  }

  [Fact]
  public async Task TheRecordsTravelAsTheMacsSettings()
  {
    var here = new WhatsAppSettingsFile(null);
    await here.SaveAsync(WhatsAppAgentRecord.FromJson(Golden[0])!);
    var owner = new CloudSettingsOwner([], families: [here.CloudFamily()]);
    var records = owner.CloudRecords();
    var mine = Assert.Single(records);
    Assert.Equal("setting:whatsapp.agent.wa-1", mine.Key);
    Assert.Equal("whatsapp.agent.wa-1", CloudRecordJson.Text(CloudRecordJson.Get(mine.Value, "key")));

    // A newer value from the Mac is taken; one that is not a record of this key is not.
    var newer = WhatsAppAgentRecord.FromJson(Golden[0])! with { Name = "Work phone" };
    var cloud = CloudRecordJson.Object([("key", (CloudJson)CloudJson.From("whatsapp.agent.wa-1")), ("value", (CloudJson)CloudJson.From(newer.ToJson()))]);
    var plan = owner.CloudPlan("setting:whatsapp.agent.wa-1", cloud);
    Assert.NotNull(plan);
    owner.CloudWrite("setting:whatsapp.agent.wa-1", cloud, mine.Value);
    Assert.Equal("Work phone", Assert.Single(await here.RecordsAsync()).Name);
    var wrong = CloudRecordJson.Object([("key", (CloudJson)CloudJson.From("whatsapp.agent.wa-9")), ("value", (CloudJson)CloudJson.From(newer.ToJson()))]);
    Assert.False(WhatsAppSettingsFile.CloudAccepts("whatsapp.agent.wa-9", CloudJson.From(newer.ToJson())));
    Assert.Throws<CloudRecordRefusal>(() => owner.CloudWrite("setting:whatsapp.agent.wa-9", wrong, null));
  }

  [Fact]
  public void ATerminalsReplayIsReadAsPlainText()
  {
    var replay = "\u001b[?2004h\u001b[32mPS C:\\>\u001b[0m ls\r\n\u001b]0;title\u0007README.md\r\nsrc\r\n";
    Assert.Equal("PS C:\\> ls\nREADME.md\nsrc\n", WhatsAppWindowsReceivers.PlainText(replay));
  }
}
