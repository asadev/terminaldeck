using System.Text.Json;
using TerminalDeck.Core.Computers;

namespace TerminalDeck.Core.Tests.Computers;

public sealed class RemoteSessionReadingTests
{
  private static JsonElement Json(string json) => JsonSerializer.Deserialize<JsonElement>(json);
  [Fact] public void HostChoicesAreUsedWithoutInventingModelsOrEffort()
  {
    var response = Json("""{"options":{"model":"offered-model","effort":"high","models":[{"id":"offered-model","name":"Offered model"}],"efforts":["high"]}}""");
    Assert.Equal("offered-model", RemoteSessionReading.ControlLabel(response, "model")); Assert.Equal("Offered model", Assert.Single(RemoteSessionReading.Choices(response, "model")).Name);
    Assert.Equal("high", Assert.Single(RemoteSessionReading.Choices(response, "effort")).Id); Assert.Empty(RemoteSessionReading.Choices(Json("{}"), "effort"));
    Assert.Equal("Effort", RemoteSessionReading.ControlLabel(Json("""{"reading":{"effort":{"value":"unknown"}}}"""), "effort"));
  }
  [Fact] public void AccountLabelsPreferTheChosenNameAndHideEmailAddresses()
  {
    Assert.Equal("Chosen", RemoteSessionReading.AccountName(Json("""{"name":"Chosen","email":"name@example.test"}""")));
    Assert.Equal("name", RemoteSessionReading.AccountName(Json("""{"name":"name@example.test"}""")));
  }
  [Fact] public void StreamedMessagesAppendAndFinalMessagesReplaceWithResolvedApprovals()
  {
    var rows = RemoteChatReading.Rows(new[]
    {
      Json("""{"sequence":1,"kind":"textDelta","messageId":"reply","value":{"text":"First "}}"""),
      Json("""{"sequence":2,"kind":"textDelta","messageId":"reply","value":{"text":"part"}}"""),
      Json("""{"sequence":3,"kind":"message","messageId":"reply","value":{"text":"Final answer"}}"""),
      Json("""{"sequence":4,"kind":"approval","messageId":"approval","value":{"requestId":"request","text":"Run tests?"}}"""),
      Json("""{"sequence":5,"kind":"approvalResolved","messageId":"approval","value":{"requestId":"request"}}""")
    });
    Assert.Equal("Final answer", rows[0].Text); Assert.DoesNotContain(rows, row => row.Kind == "approval");
  }
}
