using TerminalDeck.Core.Chats;

namespace TerminalDeck.Core.Tests.Integration;

public sealed class W7ApprovalStateTests
{
  [Fact] public void FinalApprovalDecisionWinsWhenWorkerSendingReceiptArrivesLater()
  {
    var definition = new ChatDefinition(Guid.NewGuid().ToString(), "claude", Path.GetTempPath(), "Approval", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), new());
    var chat = new ChatRecord(1, definition, "fixture", [new(8, "approval", "request", "Write"), new(9, "approvalResolved", "request", "Refused"), new(10, "approvalSending", "request", "Sending answer.")], []);
    var row = Assert.Single(ChatProjection.Rows(chat));
    Assert.Equal("approval", row.Kind); Assert.False(row.Waiting); Assert.Equal("Refused", row.Status);
  }
}
