using TerminalDeck.Core.Integration;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Integration;

public sealed class W9ReceiverDeliveryTests
{
  private static ReceiverItem Item => new("item", "source", "project", DateTimeOffset.UnixEpoch,
    "Shared note", "Outside text", null, [], "fingerprint");
  private static readonly ReceiverTarget Chat = new(RouteKind.Chat, "chat");
  private static readonly ReceiverTarget Terminal = new(RouteKind.Session, "terminal");
  private static string Id() => Guid.NewGuid().ToString("N");

  [Fact] public async Task SavedReceiptSurvivesRestartWithoutAnotherSend()
  {
    var state = new Store(); var sends = 0;
    W9ReceiverDelivery Open() => Delivery(state, Chat, (_, _, _, _) => { sends++; return ValueTask.FromResult(new DeliveryReceipt("saved", "Delivered.")); });
    var id = Id(); var first = await Open().DeliverAsync(Item, Chat, id, default);
    var again = await Open().DeliverAsync(Item, Chat, id, default);
    Assert.Equal(first, again); Assert.Equal(1, sends); Assert.Single(state.Value!.Rows);
  }
  [Fact] public async Task LostTerminalAcknowledgementCannotReplayAfterRestart()
  {
    var state = new Store(); var sends = 0;
    W9ReceiverDelivery Open() => Delivery(state, Terminal, (_, _, _, _) => { sends++; throw new IOException("Lost reply"); });
    var id = Id();
    await Assert.ThrowsAsync<IOException>(async () => await Open().DeliverAsync(Item, Terminal, id, default));
    await Assert.ThrowsAsync<IOException>(async () => await Open().DeliverAsync(Item, Terminal, id, default));
    Assert.Equal(1, sends); Assert.Null(state.Value!.Rows.Single().Receipt);
  }
  [Fact] public async Task NativeReceiptRecoversLostReplyWithoutAnotherSend()
  {
    var state = new Store(); var sends = 0; DeliveryReceipt? native = null;
    W9ReceiverDelivery Open() => Delivery(state, Chat, (_, _, _, _) =>
    {
      sends++; native = new("native", "Queued in chat."); throw new IOException("Lost reply");
    }, (_, _, _, _) => ValueTask.FromResult(native));
    var id = Id();
    await Assert.ThrowsAsync<IOException>(async () => await Open().DeliverAsync(Item, Chat, id, default));
    Assert.Equal(native, await Open().DeliverAsync(Item, Chat, id, default)); Assert.Equal(1, sends);
    Assert.NotNull(state.Value!.Rows.Single().Receipt);
  }
  [Fact] public async Task AgentRecoveryKeepsTheOriginallyPreparedConversation()
  {
    var state = new Store(); var agent = new ReceiverTarget(RouteKind.Agent, "agent");
    var current = Chat; ReceiverTarget? recovered = null; var id = Id();
    W9ReceiverDelivery Open() => new(state, () => [new(agent, "Agent", "project")], (_, _) => current,
      (_, target, _, _) => { recovered = target; return ValueTask.FromResult<DeliveryReceipt?>(new("native", "Saved.")); },
      (_, _, _, _) => throw new IOException("Lost reply"));
    await Assert.ThrowsAsync<IOException>(async () => await Open().DeliverAsync(Item, agent, id, default));
    current = new(RouteKind.Chat, "a-different-chat");
    await Open().DeliverAsync(Item, agent, id, default); Assert.Equal(Chat, recovered);
  }
  [Fact] public async Task DeliveryReferenceCannotBeReusedForAnotherPayload()
  {
    var state = new Store(); var delivery = Delivery(state, Chat, (_, _, _, _) => ValueTask.FromResult(new DeliveryReceipt("saved", "Delivered.")));
    var id = Id(); await delivery.DeliverAsync(Item, Chat, id, default);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await delivery.DeliverAsync(Item with { Text = "Changed" }, Chat, id, default));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await delivery.DeliverAsync(Item, Terminal, id, default));
  }
  [Fact] public async Task UnavailableOrCrossProjectTargetNeverStartsDelivery()
  {
    var state = new Store(); var sends = 0;
    var delivery = Delivery(state, Chat, (_, _, _, _) => { sends++; return ValueTask.FromResult(new DeliveryReceipt("saved", "Delivered.")); });
    await Assert.ThrowsAsync<ArgumentException>(async () => await delivery.DeliverAsync(Item with { ProjectId = "other" }, Chat, Id(), default));
    await Assert.ThrowsAsync<ArgumentException>(async () => await delivery.DeliverAsync(Item, Terminal, Id(), default));
    Assert.Equal(0, sends); Assert.Null(state.Value);
  }
  [Fact] public async Task FailedJournalSaveHappensBeforeTheDestinationIsTouched()
  {
    var state = new Store { Fail = true }; var sends = 0;
    var delivery = Delivery(state, Chat, (_, _, _, _) => { sends++; return ValueTask.FromResult(new DeliveryReceipt("saved", "Delivered.")); });
    await Assert.ThrowsAsync<IOException>(async () => await delivery.DeliverAsync(Item, Chat, Id(), default));
    Assert.Equal(0, sends); Assert.Null(state.Value);
  }
  [Fact] public async Task ConcurrentSameReferenceHasOnlyOneDestinationSend()
  {
    var state = new Store(); var sends = 0; var pause = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var delivery = Delivery(state, Chat, async (_, _, _, _) => { Interlocked.Increment(ref sends); await pause.Task; return new("saved", "Delivered."); });
    var id = Id(); var first = delivery.DeliverAsync(Item, Chat, id, default).AsTask();
    var second = delivery.DeliverAsync(Item, Chat, id, default).AsTask(); pause.SetResult();
    var receipts = await Task.WhenAll(first, second); Assert.Equal(1, sends); Assert.Equal(receipts[0], receipts[1]);
  }
  private static W9ReceiverDelivery Delivery(Store state, ReceiverTarget target,
    Func<ReceiverItem, ReceiverTarget, string, CancellationToken, ValueTask<DeliveryReceipt>> send,
    Func<ReceiverItem, ReceiverTarget, string, CancellationToken, ValueTask<DeliveryReceipt?>>? recover = null) =>
    new(state, () => [new(target, "Destination", "project")], (_, requested) => requested,
      recover ?? ((_, _, _, _) => ValueTask.FromResult<DeliveryReceipt?>(null)), send);
  private sealed class Store : IStateStore<W9ReceiverReceipts>
  {
    public W9ReceiverReceipts? Value;
    public bool Fail;
    public W9ReceiverReceipts? Load() => Value;
    public void Save(W9ReceiverReceipts state) { if (Fail) throw new IOException("Disk unavailable"); Value = state; }
  }
}
