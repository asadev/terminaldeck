using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Integration;

public sealed record W9ReceiverReceipt(string Id, string Fingerprint, ReceiverTarget Destination, DeliveryReceipt? Receipt = null);
public sealed record W9ReceiverReceipts(ImmutableArray<W9ReceiverReceipt> Rows);

// Destination engines with their own saved request ids can reconcile a lost
// reply. A terminal has no such receipt, so an interrupted write stays uncertain.
public sealed class W9ReceiverDelivery(
  IStateStore<W9ReceiverReceipts> store,
  Func<IReadOnlyList<ReceiverDestination>> destinations,
  Func<ReceiverItem, ReceiverTarget, ReceiverTarget> prepare,
  Func<ReceiverItem, ReceiverTarget, string, CancellationToken, ValueTask<DeliveryReceipt?>> recover,
  Func<ReceiverItem, ReceiverTarget, string, CancellationToken, ValueTask<DeliveryReceipt>> send) : IReceiverDelivery
{
  private readonly SemaphoreSlim gate = new(1);
  private W9ReceiverReceipts state = Load(store);
  public IReadOnlyList<ReceiverDestination> Destinations() => destinations();
  public async ValueTask<DeliveryReceipt> DeliverAsync(ReceiverItem item, ReceiverTarget target, string deliveryId, CancellationToken ct)
  {
    if (!Guid.TryParseExact(deliveryId, "N", out _)) throw new ArgumentException("Keep the saved delivery reference.");
    var fingerprint = Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new
    {
      item.Id, item.ProjectId, item.Title, item.Text, item.Url, item.Files, Target = target
    }, ReceiverJson.Options)));
    await gate.WaitAsync(ct);
    try
    {
      var row = state.Rows.FirstOrDefault(r => r.Id == deliveryId);
      if (row is not null)
      {
        if (row.Fingerprint != fingerprint) throw new InvalidOperationException("This delivery reference already belongs to another item or destination.");
        if (row.Receipt is { } saved) return saved;
        var found = await recover(item, row.Destination, deliveryId, ct);
        if (found is not null) { Complete(row, found); return found; }
        if (row.Destination.Kind == RouteKind.Session)
          throw new IOException("The earlier terminal send could not be confirmed. Check the session; it will not be sent twice.");
      }
      else
      {
        if (!destinations().Any(d => d.ProjectId == item.ProjectId && d.Target == target))
          throw new ArgumentException("Choose an available destination in this item's project.");
        if (state.Rows.Length >= 10000) throw new IOException("The saved delivery history is full. Keep this item for review.");
        row = new(deliveryId, fingerprint, prepare(item, target));
        Save(new(state.Rows.Add(row)));
      }
      ct.ThrowIfCancellationRequested();
      var receipt = await send(item, row.Destination, deliveryId, ct);
      if (string.IsNullOrWhiteSpace(receipt.Reference)) throw new IOException("The destination did not acknowledge this item.");
      Complete(row, receipt); return receipt;
    }
    finally { gate.Release(); }
  }
  private void Complete(W9ReceiverReceipt row, DeliveryReceipt receipt) => Save(new(state.Rows.Replace(row, row with { Receipt = receipt })));
  private void Save(W9ReceiverReceipts next) { store.Save(next); state = next; }
  private static W9ReceiverReceipts Load(IStateStore<W9ReceiverReceipts> store)
  {
    var saved = store.Load() ?? new([]);
    if (saved.Rows.IsDefault || saved.Rows.Length > 10000 || saved.Rows.Select(r => r.Id).Distinct().Count() != saved.Rows.Length)
      throw new IOException("The saved Receiver delivery history could not be read safely.");
    return saved;
  }
}
