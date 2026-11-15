using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

/// Sessions in the Cloud: deleting a chat under the delete rule (the Mac's BackendCloudChatsDelete.swift; owner, 15 Nov:
/// "kept until I delete it"). Only from the Your Cloud page's "Sessions and chats" (its rows and bin buttons) or an AI's
/// `cloud.delete`; no button anywhere else, and closing a session never deletes its chat.
/// - One scope, "Everywhere": the chat leaves the Cloud and every device's lists, into the Bin for 30 days (the service's
///   `POST /v1/chats/bin`); it is never uploaded again by itself. The AI's own history file on the PC that ran it is not
///   touched (it is the AI's working file, and its session may still be open there).
/// - The Bin: this owner keeps the removals made from this PC (name, who, when) so the Bin shows them with "Put back" and
///   "Put back all"; the service removes a binned chat 30 days after it was binned. "Remove now" is the person's alone.
/// The delete rule's own types (lane D's CloudDeleteRule.cs) are not on this branch: this owner speaks in its own small
/// records with the same fields, and the join adapts it to `ICloudDeleteOwning` in a few lines.
public sealed class CloudChatsDeleteOwner
{
  /// The delete rule's kind word for a chat: id = the service's session ref, place = the session id when it is this
  /// PC's own (so this PC stops copying it at once).
  public const string Kind = "chat";
  public const long RetentionMilliseconds = 30L * 24 * 3_600_000;
  public sealed record Item(string Id, string Kind, string Name, string? Place = null);
  /// One removal: who (person or ai), on which machine, from which session/agent, when, and what.
  public sealed record Group(string Id, string By, string MacName, string? Session, string? Agent, long At, IReadOnlyList<Item> Items);
  public delegate Task<bool> BinCall(string reference, string? session, string action);

  private readonly BinCall bin;
  private readonly string? file;
  private readonly Func<long> clock;
  private List<Group> groups;
  private readonly SemaphoreSlim gate = new(1, 1);

  public CloudChatsDeleteOwner(BinCall bin, string? file, Func<long>? clock = null)
  {
    this.bin = bin; this.file = file; this.clock = clock ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    List<Group>? saved = null;
    if (file is not null && File.Exists(file))
      try { saved = JsonSerializer.Deserialize<List<Group>>(File.ReadAllBytes(file)); } catch (Exception ex) when (ex is JsonException or IOException) { }
    groups = saved ?? [];
  }
  private void Save()
  {
    if (file is null) return;
    try { Directory.CreateDirectory(Path.GetDirectoryName(file)!); File.WriteAllBytes(file, JsonSerializer.SerializeToUtf8Bytes(groups)); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
  }
  /// The service sweeps a binned chat after 30 days; its Bin row goes with it.
  private void Sweep()
  {
    var now = clock();
    var kept = groups.Where(g => now - g.At < RetentionMilliseconds).ToList();
    if (kept.Count != groups.Count) { groups = kept; Save(); }
  }
  private void Forget(IReadOnlyCollection<Item> items)
  {
    var keys = items.Select(i => i.Kind + "|" + i.Id).ToHashSet(StringComparer.Ordinal);
    groups = groups.Select(g => g with { Items = g.Items.Where(i => !keys.Contains(i.Kind + "|" + i.Id)).ToArray() }).Where(g => g.Items.Count > 0).ToList();
    Save();
  }
  private async Task<T> Locked<T>(Func<Task<T>> work)
  {
    await gate.WaitAsync();
    try { return await work(); } finally { gate.Release(); }
  }

  /// Chats only, Everywhere only. `group`: the removal's group id (one press, one group).
  public Task<Group> DeleteItemsAsync(IReadOnlyList<Item> items, string by, string macName, string? session, string? agent, long at, string group) => Locked(async () =>
  {
    var chats = items.Where(i => i.Kind == Kind).ToList();
    if (chats.Count == 0 || chats.Count != items.Count) throw new CloudFailure("invalid_request");
    var binned = new List<Item>();
    foreach (var item in chats) if (await bin(item.Id, item.Place, "bin")) binned.Add(item);
    if (binned.Count == 0) throw new CloudFailure("unavailable", 0, true);
    var made = new Group(group, by, macName, session, agent, at, [.. groups.FirstOrDefault(g => g.Id == group)?.Items ?? [], .. binned]);
    groups.RemoveAll(g => g.Id == group);
    groups.Add(made);
    Save();
    return made;
  });
  public Task<IReadOnlyList<Item>> BringBackAsync(IReadOnlyList<Item> items) => Locked(() => BringBack(items));
  private async Task<IReadOnlyList<Item>> BringBack(IReadOnlyList<Item> items)
  {
    var restored = new List<Item>();
    foreach (var item in items.Where(i => i.Kind == Kind)) if (await bin(item.Id, item.Place, "restore")) restored.Add(item);
    Forget(restored);
    return restored;
  }
  /// Nothing is ever "Not on this PC": a chat is in the Cloud or in the Bin.
  public Task<IReadOnlyList<Item>> NotHereAsync() => Task.FromResult<IReadOnlyList<Item>>([]);
  public Task<IReadOnlyList<Group>> BinGroupsAsync() => Locked(() => { Sweep(); return Task.FromResult<IReadOnlyList<Group>>(groups.ToArray()); });
  public Task<IReadOnlyList<Item>> PutBackGroupAsync(string group) => Locked(async () =>
    groups.FirstOrDefault(g => g.Id == group) is { } found ? await BringBack(found.Items) : (IReadOnlyList<Item>)[]);
  /// "Remove now": the person's alone (no AI tool reaches it).
  public Task DeleteForGoodAsync(IReadOnlyList<Item> items) => Locked(async () =>
  {
    var removed = new List<Item>();
    foreach (var item in items.Where(i => i.Kind == Kind)) if (await bin(item.Id, item.Place, "remove")) removed.Add(item);
    Forget(removed);
    if (removed.Count != items.Count) throw new CloudFailure("unavailable", 0, true);
    return true;
  });
}

/// The Your Cloud page's "Sessions and chats": every session's and earlier chat's copy in the Cloud, as plain rows
/// (name; its project, "Earlier chat" for a closed one; which machine; its date) with the one delete item each carries.
/// The page itself is the screens lane's.
public static class CloudChatsContents
{
  public sealed record Entry(string Id, string Name, string? Place, string Machine, long ChangedAt, IReadOnlyList<string> Folder,
    CloudChatsDeleteOwner.Item DeleteItem);
  public const string NoProject = "Independent";
  public const string EarlierChats = "Earlier chats";
  public static IReadOnlyList<Entry> Items(IEnumerable<CloudSessionsRead.Row> rows) => rows.Select(row =>
  {
    var name = Plain(row.Name) ?? "Session";
    var machine = Plain(row.MachineName) ?? "another computer";
    var place = new[] { row.Project is { Name.Length: > 0 } p ? p.Name : null, row.ClosedAt is not null ? "Earlier chat" : null }.OfType<string>().ToArray();
    var project = Plain(row.Project?.Name) ?? NoProject;
    return new Entry("sessions|" + row.Ref, name, place.Length == 0 ? null : string.Join(" · ", place), machine, (long)(row.LastUsedAt ?? row.ClosedAt ?? 0),
      row.ClosedAt is not null ? [project, EarlierChats] : [project], new CloudChatsDeleteOwner.Item(row.Ref, CloudChatsDeleteOwner.Kind, name, row.Mine == true ? row.SessionId : null));
  }).ToArray();
  private static string? Plain(string? text)
  {
    var line = string.Join(' ', new string((text ?? "").Select(c => char.IsControl(c) ? ' ' : c).ToArray()).Split(' ', StringSplitOptions.RemoveEmptyEntries));
    return line.Length == 0 ? null : line;
  }
}
