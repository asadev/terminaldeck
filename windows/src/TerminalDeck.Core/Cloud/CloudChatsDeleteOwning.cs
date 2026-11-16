namespace TerminalDeck.Core.Cloud;

/// Lane C's chats as one of the delete rule's owners (lane D's `ICloudDeleteOwning`), for the Your Cloud page: the same
/// four item fields, Bin groups by person or AI. A chat is removed Everywhere only (the Cloud-only scope is refused, as
/// on the Mac); nothing is ever "Not on this PC".
public sealed class CloudChatsDeleteOwning(Func<CloudChatsDeleteOwner?> owner) : ICloudDeleteOwning
{
  private CloudChatsDeleteOwner Owner => owner() ?? throw new CloudFailure("unavailable", 0, true);
  private static CloudChatsDeleteOwner.Item Item(CloudDeleteItem i) => new(i.Id, i.Kind, i.Name, i.Place);
  private static CloudDeleteItem Item(CloudChatsDeleteOwner.Item i) => new(i.Id, i.Kind, i.Name, i.Place);
  private static CloudBinGroup Group(CloudChatsDeleteOwner.Group g) =>
    new(g.Id, g.By == "ai" ? CloudDeleteBy.Ai : CloudDeleteBy.Person, g.MacName, g.Session, g.Agent, g.At, g.Items.Select(Item).ToArray());

  public async Task<CloudBinGroup> DeleteItemsAsync(IReadOnlyList<CloudDeleteItem> items, CloudDeleteScope scope, CloudDeleteActor by)
  {
    if (scope != CloudDeleteScope.Everywhere) throw new CloudFailure("invalid_request");
    return Group(await Owner.DeleteItemsAsync(items.Select(Item).ToArray(), by.By == CloudDeleteBy.Ai ? "ai" : "person", by.MacName, by.Session, by.Agent, by.At, by.Group));
  }
  public async Task<IReadOnlyList<CloudDeleteItem>> BringBackAsync(IReadOnlyList<CloudDeleteItem> items, CloudBringBackDestination to) =>
    (await Owner.BringBackAsync(items.Select(Item).ToArray())).Select(Item).ToArray();
  public Task<IReadOnlyList<CloudNotHereItem>> NotHereAsync() => Task.FromResult<IReadOnlyList<CloudNotHereItem>>([]);
  public async Task<IReadOnlyList<CloudBinGroup>> BinGroupsAsync() => owner() is { } o ? (await o.BinGroupsAsync()).Select(Group).ToArray() : [];
  public async Task<IReadOnlyList<CloudDeleteItem>> PutBackGroupAsync(string group) => (await Owner.PutBackGroupAsync(group)).Select(Item).ToArray();
  public Task DeleteForGoodAsync(IReadOnlyList<CloudDeleteItem> items) => Owner.DeleteForGoodAsync(items.Select(Item).ToArray());
  public Task<bool> CanDeleteEverywhereAsync() => Task.FromResult(owner() is not null);
}
