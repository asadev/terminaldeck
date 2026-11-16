using System.Text;

namespace TerminalDeck.Core.Cloud;

/// Sessions and chats in the Cloud, the PC's driver (the Mac's NativeCloudChats.swift without its screens):
/// - Every 30 s: this PC's list (the sessions its side panel lists, Hoot's chat included) and what each session's chat
///   added since, in ONE call; nothing at all while nothing grew.
/// - In the background, one piece every 2 s: old histories catch up, readable copies first.
/// - Every minute: the account's sessions of his OTHER machines (for the side panel); every 5 minutes: the closed
///   sessions whose chats are kept ("Earlier chats").
/// - At start and every 6 hours: Terminal Deck's own past histories on this PC are looked for (earlier chats).
/// Quiet: signed out, Cloud off on this PC, or the service part not live: nothing is sent, nothing shows an error.
public sealed class CloudChatsDriver : IDisposable
{
  public const long ScanEveryMs = 6 * 3_600_000L, OthersEveryMs = 60_000, EarlierEveryMs = 300_000;
  private readonly Func<Task<IReadOnlyList<CloudChatsSession>>> list;
  private readonly Func<IReadOnlyList<TerminalDeck.Core.Projects.Project>> projects;
  private readonly CloudChatsLocator locator;
  private readonly Func<string, string?>? names;
  private readonly Func<Task<IReadOnlyDictionary<string, string>>>? knownNames;
  private readonly Func<bool> ready;
  private readonly object gate = new();
  private CancellationTokenSource? running;
  private long scannedAt, othersAt, earlierAt;
  private IReadOnlyList<CloudChats.Listed> listed = [];
  private string? hootId, salt;
  private CloudChatsSend? send;

  public CloudChatsUploader? Uploader { get; private set; }
  public CloudChatsDeleteOwner? DeleteOwner { get; private set; }
  /// Other machines' sessions of his account (never this PC's own), newest use first.
  public IReadOnlyList<CloudSessionsRead.Row> Others { get; private set; } = [];
  /// Every open session of the account, this PC's own included.
  public IReadOnlyList<CloudSessionsRead.Row> Open { get; private set; } = [];
  /// Closed sessions whose chat is kept, every machine's, by the project they were in ("" = Independent).
  public IReadOnlyDictionary<string, IReadOnlyList<CloudSessionsRead.Row>> Earlier { get; private set; } = new Dictionary<string, IReadOnlyList<CloudSessionsRead.Row>>();
  /// The account's machines by ref, with their current names and on/off.
  public IReadOnlyDictionary<string, CloudSessionsRead.Machine> Machines { get; private set; } = new Dictionary<string, CloudSessionsRead.Machine>();
  public event Action? Changed;
  public TimeSpan Tick { get; set; } = TimeSpan.FromSeconds(30);

  /// `list`: the sessions the side panel lists now (keeper terminals and the app's chats, as CloudChatsSession);
  /// `names`: the side panel's own title by session id; `knownNames`: kept titles by conversation id (earlier chats);
  /// `ready`: signed in, Cloud on here and this kind in sync on this PC.
  public CloudChatsDriver(Func<Task<IReadOnlyList<CloudChatsSession>>> list, Func<IReadOnlyList<TerminalDeck.Core.Projects.Project>> projects, CloudChatsLocator locator,
    Func<bool> ready, Func<string, string?>? names = null, Func<Task<IReadOnlyDictionary<string, string>>>? knownNames = null)
  {
    this.list = list; this.projects = projects; this.locator = locator; this.ready = ready; this.names = names; this.knownNames = knownNames;
  }

  /// Signed in: one uploader per identity, its state in `directory` (the account's `chats` folder).
  public void Attach(CloudChatsSend send, string directory, string deviceId, string? machineRef = null)
  {
    Detach();
    var uploader = new CloudChatsUploader(send, directory);
    var token = new CancellationTokenSource();
    lock (gate)
    {
      Uploader = uploader; this.send = send; running = token;
      DeleteOwner = new CloudChatsDeleteOwner(async (reference, session, action) =>
      {
        var done = await uploader.BinAsync(session, reference, action);
        othersAt = 0; earlierAt = 0; // the lists show the change at the next look
        return done;
      }, Path.Combine(directory, "bin.json"));
      // Hoot's chat: one per machine, under an id no other machine can have.
      hootId = "hoot-" + CloudChats.Hex(Encoding.UTF8.GetBytes(deviceId))[..24];
      salt = deviceId;
    }
    CloudChatsMachine.Shared.Set(machineRef);
    _ = Task.Run(async () =>
    {
      while (!token.IsCancellationRequested)
      {
        try { await RoundAsync(uploader); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
        try { await Task.Delay(Tick, token.Token); } catch (OperationCanceledException) { return; }
      }
    });
    _ = Task.Run(async () =>
    {
      try { await Task.Delay(TimeSpan.FromSeconds(20), token.Token); } catch (OperationCanceledException) { return; }
      while (!token.IsCancellationRequested)
      {
        var sent = false;
        try { sent = ready() && listed.Count > 0 && await uploader.CatchUpStepAsync(listed); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
        try { await Task.Delay(sent ? TimeSpan.FromSeconds(2) : TimeSpan.FromSeconds(60), token.Token); } catch (OperationCanceledException) { return; }
      }
    });
  }
  /// Sign-out: nothing more is read or sent for that identity; the other machines' rows leave the side panel.
  public void Detach()
  {
    lock (gate)
    {
      running?.Cancel(); running?.Dispose(); running = null;
      Uploader = null; DeleteOwner = null; send = null; hootId = null; salt = null; listed = [];
      scannedAt = 0; othersAt = 0; earlierAt = 0;
      Others = []; Open = []; Earlier = new Dictionary<string, IReadOnlyList<CloudSessionsRead.Row>>(); Machines = new Dictionary<string, CloudSessionsRead.Machine>();
    }
    CloudChatsMachine.Shared.Set(null);
  }

  private static long Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

  /// One round: the list and the new bytes, then (rarely) the earlier-chats scan and the other machines' rows.
  public async Task RoundAsync(CloudChatsUploader uploader)
  {
    if (!ReferenceEquals(Uploader, uploader) || !ready() || uploader.Missing) return;
    var sessions = await list();
    var known = projects();
    var made = sessions.Select(s => new CloudChats.Listed(CloudChats.RowFor(s, names?.Invoke(s.Id), known), locator.SourceFor(s))).ToList();
    if (hootId is { } hoot && locator.HootSource() is { } source && CloudChats.Look(source.Raw) is { } seen)
      made.Add(new(new CloudChats.Row(hoot, "Hoot", (long)(seen.Mtime * 1000), Kind: "hoot", Status: "idle"), source));
    if (!ReferenceEquals(Uploader, uploader) || !ready()) return;
    listed = made;
    if (await uploader.RoundAsync(made) == CloudChatsUploader.Outcome.Missing) return;
    await ScanEarlierAsync(uploader, made, known);
    await ReadOthersAsync(uploader);
  }

  private async Task ScanEarlierAsync(CloudChatsUploader uploader, IReadOnlyList<CloudChats.Listed> made, IReadOnlyList<TerminalDeck.Core.Projects.Project> known)
  {
    if (salt is not { } mine || Now() - scannedAt < ScanEveryMs) return;
    scannedAt = Now();
    var skip = await uploader.ArchiveSkipAsync();
    foreach (var item in made)
      foreach (var path in new[] { item.Source.Raw, item.Source.Snap }.OfType<string>().Concat(item.Source.ToolFiles)) skip.Add(path);
    var kept = knownNames is null ? new Dictionary<string, string>() : await knownNames();
    var found = await Task.Run(() => CloudChatsArchive.Scan(locator.OwnHomes(), locator.Chats, skip, kept));
    if (!ReferenceEquals(Uploader, uploader)) return;
    await uploader.AddArchiveAsync(found, mine, known);
  }

  private async Task ReadOthersAsync(CloudChatsUploader uploader)
  {
    if (send is not { } door || !ready() || uploader.Missing) return;
    var now = Now(); var changed = false;
    if (now - othersAt >= OthersEveryMs)
    {
      othersAt = now;
      if (await CloudSessionsRead.ListAsync(door, earlier: false) is { } read)
      {
        Machines = read.Machines.Where(m => m.Ref is not null).GroupBy(m => m.Ref!).ToDictionary(g => g.Key, g => g.First());
        Open = read.Rows.OrderByDescending(r => r.LastUsedAt ?? 0).ToArray();
        Others = Open.Where(r => r.Mine != true).ToArray();
        changed = true;
      }
    }
    if (now - earlierAt >= EarlierEveryMs)
    {
      earlierAt = now;
      if (await CloudSessionsRead.ListAsync(door, earlier: true) is { } read)
      {
        // Newest use first, by the history's own date (an earlier chat copied today is not "today").
        Earlier = read.Rows.OrderByDescending(r => r.LastUsedAt ?? 0).GroupBy(r => r.Project?.CloudRef ?? "")
          .ToDictionary(g => g.Key, g => (IReadOnlyList<CloudSessionsRead.Row>)g.ToArray());
        changed = true;
      }
    }
    if (changed) Changed?.Invoke();
  }

  public void Dispose() => Detach();
}
