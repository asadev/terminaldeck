using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// Lane F: the Cloud folder, case for case the Mac's CloudFolderTests.swift (suites Travel, Safety, Cost, OlderBuild,
// ReviewFix, StatusLine, NoEcho, HisWork). Two "devices" (two owners, each with its own scratch "home" folder, state and
// keeper) and the records passed between them as the Windows sync passes them (capture -> TravelOperations -> ApplyAsync
// one record at a time -> SettleAsync). Every folder lives under this test run's own output folder and is removed at the
// end. No real home, account or network.
public sealed class CloudFolderClock
{
  private long value = 1_900_000_000_000;
  public long Ms => Interlocked.Read(ref value);
  public void Advance(long by) => Interlocked.Add(ref value, by);
}

public sealed class CloudFolderCursor { public long Seq; }

public sealed class CloudFolderFixture : IDisposable
{
  public readonly string Base = Path.Combine(AppContext.BaseDirectory, "cloud-files-scratch", "f-" + Guid.NewGuid().ToString("N"));
  public readonly string DeviceA = Guid.NewGuid().ToString("D"), DeviceB = Guid.NewGuid().ToString("D");
  public readonly CloudFolderClock Clock = new();
  public CloudFolderFixture() => Directory.CreateDirectory(Base);
  public void Dispose() { try { Directory.Delete(Base, recursive: true); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { } }

  public string Folder(string mac) => Path.Combine(Base, mac, "home", "Terminal Deck Cloud");
  public CloudBin Keeper(string mac) => CloudBin.Shared(Path.Combine(Base, mac, "data", "archive", "versions"));
  /// `announced`: whether the OTHER devices announced the delete rule. These fixtures default to "an older build sent
  /// it", so a removal without an about-record is the old-format Everywhere, as on the Mac.
  public CloudFolderOwner Mac(string name, string device, bool understands = true, bool read = true, bool makeFolder = true, long freeDisk = 500_000_000_000,
    bool announced = false)
  {
    if (makeFolder) Directory.CreateDirectory(Folder(name));
    var clock = Clock;
    var owner = new CloudFolderOwner(device, Folder(name), Path.Combine(Base, name, "data", "cloud-folder"), Keeper(name), () => understands,
      freeDisk: () => freeDisk, now: () => clock.Ms);
    owner.SetDeleteRuleAnnounced(_ => announced);
    if (read) owner.MarkCloudRead();
    return owner;
  }
  public void Write(string mac, string path, string text, long? modified = null) => WriteAt(Folder(mac), path, text, modified ?? Clock.Ms);
  public static void WriteAt(string root, string path, string text, long modified)
  {
    var full = CloudFolderDisk.Full(root, path);
    Directory.CreateDirectory(Path.GetDirectoryName(full)!);
    File.WriteAllBytes(full, Encoding.UTF8.GetBytes(text));
    File.SetLastWriteTimeUtc(full, DateTime.UnixEpoch.AddMilliseconds(modified));
  }
  public string? Text(string mac, string path) => File.Exists(CloudFolderDisk.Full(Folder(mac), path)) ? File.ReadAllText(CloudFolderDisk.Full(Folder(mac), path)) : null;
  public void Remove(string mac, string path) => File.Delete(CloudFolderDisk.Full(Folder(mac), path));
  /// Two looks 4 s apart: a change that stayed still for the quiet time is recorded.
  public async Task Settle(CloudFolderOwner owner)
  {
    await owner.LookAsync();
    Clock.Advance(4_000);
    await owner.LookAsync();
  }
  /// Everything `from` journaled since `cursor`, each record applied on `to` as the Windows sync does. Returns the records.
  public async Task<IReadOnlyList<CloudOperation>> Send(CloudFolderOwner from, string device, CloudFolderOwner to, CloudFolderCursor cursor)
  {
    var engine = from.Core();
    var raw = new List<CloudOperation>();
    foreach (var row in engine.JournalAfter(cursor.Seq)) { raw.AddRange(engine.Operations(row)); cursor.Seq = row.Seq; }
    if (raw.Count == 0) return [];
    var operations = from.TravelOperations(raw);
    await Apply(to, operations, device);
    return operations;
  }
  public async Task Apply(CloudFolderOwner to, IReadOnlyList<CloudOperation> operations, string device)
  {
    foreach (var op in operations)
    {
      try { await to.ApplyAsync(op, new CloudImportOrigin(device, (ulong)Clock.Ms, null, false), CancellationToken.None); }
      catch (CloudFailure refused) when (refused.Code is "id_reused" or "invalid_request") { }
    }
    await to.SettleAsync(CancellationToken.None);
  }
  public static IReadOnlyList<CloudOperation> Journal(CloudFolderOwner owner)
  {
    var engine = owner.Core();
    return engine.JournalAfter(0).SelectMany(engine.Operations).ToArray();
  }
  public static string Hash(string text) => CloudMemoryFormat.Hash(Encoding.UTF8.GetBytes(text));

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool DeviceIoControl(SafeFileHandle handle, uint code, IntPtr inBuffer, uint inSize, IntPtr outBuffer, uint outSize, out uint returned, IntPtr overlapped);
  /// A large file that takes no real room (sparse on NTFS; nothing real is written).
  public static void Sparse(string full, long size)
  {
    Directory.CreateDirectory(Path.GetDirectoryName(full)!);
    using var file = new FileStream(full, FileMode.Create, FileAccess.ReadWrite);
    if (OperatingSystem.IsWindows()) DeviceIoControl(file.SafeFileHandle, 0x000900C4, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero);
    file.SetLength(size);
  }
  /// A link to a folder: a symbolic link where this account may make one, otherwise a junction (both reparse points).
  public static void LinkFolder(string link, string target)
  {
    try { Directory.CreateSymbolicLink(link, target); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException)
    {
      using var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("cmd.exe", "/c mklink /J \"" + link + "\" \"" + target + "\"") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true })!;
      p.WaitForExit();
    }
  }
}

public sealed class CloudFolderTravelTests
{
  [Fact]
  public async Task A_file_travels_to_the_other_device()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    f.Write("a", "Plans/plan.md", "the plan");
    await f.Settle(a);
    var cursor = new CloudFolderCursor();
    var sent = await f.Send(a, f.DeviceA, b, cursor);
    Assert.All(sent, op => Assert.Equal("cloud-folder", op.Domain));
    Assert.Equal("the plan", f.Text("b", "Plans/plan.md"));
    Assert.Equal(1, b.Counts().Files);
    // Nothing echoes back: B's look records nothing of its own for a file that arrived.
    await f.Settle(b);
    Assert.Empty(CloudFolderFixture.Journal(b));
  }

  [Fact]
  public async Task The_same_name_on_two_devices_keeps_both_the_newer_is_used()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    var t = f.Clock.Ms;
    f.Write("a", "notes.txt", "from A", t - 60_000);
    f.Write("b", "notes.txt", "from B", t - 30_000);
    await f.Settle(a); await f.Settle(b);
    CloudFolderCursor fromA = new(), fromB = new();
    await f.Send(a, f.DeviceA, b, fromA);
    await f.Send(b, f.DeviceB, a, fromB);
    await f.Settle(a); await f.Settle(b);
    await f.Send(a, f.DeviceA, b, fromA);
    Assert.Equal("from B", f.Text("a", "notes.txt"));
    Assert.Equal("from B", f.Text("b", "notes.txt"));
    // The older one is a version he can open, on both devices.
    var keptA = a.Versions("notes.txt"); var keptB = b.Versions("notes.txt");
    Assert.NotEmpty(keptA); Assert.NotEmpty(keptB);
    var url = a.Openable("notes.txt", keptA[0].Sha256);
    Assert.NotNull(url);
    Assert.Equal("from A", File.ReadAllText(url!));
    Assert.NotEmpty(a.ReplacedLines(new Dictionary<string, string>()));
  }

  [Fact]
  public async Task A_delete_goes_to_both_bins_and_comes_back_with_put_back()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    f.Write("a", "keep.md", "stays"); f.Write("a", "gone.md", "goes");
    await f.Settle(a);
    CloudFolderCursor fromA = new(), fromB = new();
    await f.Send(a, f.DeviceA, b, fromA);
    Assert.Equal("goes", f.Text("b", "gone.md"));
    await a.StoreRemoveAsync("gone.md", CloudFolderFixture.Hash("goes"));
    await f.Settle(a);
    Assert.Equal(["gone.md"], a.Bin().Select(k => k.Path));
    var removal = await f.Send(a, f.DeviceA, b, fromA);
    Assert.Contains(removal, op => op.Kind == "archive");
    Assert.Null(f.Text("b", "gone.md"));
    Assert.Equal("stays", f.Text("b", "keep.md"));
    Assert.Equal(["gone.md"], b.Bin().Select(k => k.Path));
    // Put back on B: it comes back on A too, and leaves both Bins.
    Assert.True(await b.PutBackAsync("gone.md"));
    await f.Settle(b);
    await f.Send(b, f.DeviceB, a, fromB);
    Assert.Equal("goes", f.Text("a", "gone.md"));
    Assert.Empty(a.Bin());
    Assert.Empty(b.Bin());
  }

  [Fact]
  public async Task An_edit_beats_a_removal()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    f.Write("a", "keep.md", "k"); f.Write("a", "doc.md", "v1");
    await f.Settle(a);
    CloudFolderCursor fromA = new(), fromB = new();
    await f.Send(a, f.DeviceA, b, fromA);
    await a.StoreRemoveAsync("doc.md", CloudFolderFixture.Hash("v1")); await f.Settle(a);
    f.Clock.Advance(1_000);
    f.Write("b", "doc.md", "v2 edited on B"); await f.Settle(b);
    await f.Send(a, f.DeviceA, b, fromA);
    Assert.Equal("v2 edited on B", f.Text("b", "doc.md"));
    await f.Send(b, f.DeviceB, a, fromB);
    Assert.Equal("v2 edited on B", f.Text("a", "doc.md"));
  }
}

public sealed class CloudFolderSafetyTests
{
  [Fact]
  public async Task An_emptied_folder_sends_nothing_and_offers_make_it_again()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    foreach (var name in new[] { "1.md", "2.md", "3.md" }) f.Write("a", name, name);
    await f.Settle(a);
    var before = CloudFolderFixture.Journal(a).Count;
    foreach (var name in new[] { "1.md", "2.md", "3.md" }) f.Remove("a", name);
    await f.Settle(a);
    Assert.Equal(before, CloudFolderFixture.Journal(a).Count);
    Assert.Empty(await a.NotHereAsync());
    Assert.True(a.WaitingAnswer()?.FolderMissing);
    Assert.Null(f.Text("a", "2.md"));
    await a.MakeFolderAgainAsync();
    Assert.Equal("2.md", f.Text("a", "2.md"));
    Assert.Equal(before, CloudFolderFixture.Journal(a).Count);
  }

  [Fact]
  public async Task A_missing_folder_sends_nothing()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    f.Write("a", "x.md", "x"); await f.Settle(a);
    var before = CloudFolderFixture.Journal(a).Count;
    Directory.Delete(f.Folder("a"), recursive: true);
    await f.Settle(a); f.Clock.Advance(4_000); await a.LookAsync();
    Assert.Equal(before, CloudFolderFixture.Journal(a).Count);
    Assert.True(a.WaitingAnswer()?.FolderMissing);
  }

  [Fact]
  public async Task A_large_explicit_removal_applies_without_holding()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    for (var i = 0; i < 30; i++) f.Write("a", "f" + i + ".md", "file " + i);
    await f.Settle(a);
    var cursor = new CloudFolderCursor();
    await f.Send(a, f.DeviceA, b, cursor);
    var items = Enumerable.Range(0, 12).Select(i => new CloudDeleteItem("f" + i + ".md", "cloudFolder", "f" + i + ".md")).ToArray();
    var actor = new CloudDeleteActor(CloudDeleteBy.Person, f.DeviceA, "Mac mini", null, null, f.Clock.Ms, Guid.NewGuid().ToString("D"));
    await a.DeleteItemsAsync(items, CloudDeleteScope.Everywhere, actor);
    var sent = await f.Send(a, f.DeviceA, b, cursor);
    Assert.Equal(12, sent.Count(op => op.Kind == "archive"));
    Assert.Null(b.WaitingAnswer());
    Assert.Equal(12, b.Bin().Count);
    Assert.All(Enumerable.Range(0, 12), i => Assert.Null(f.Text("b", "f" + i + ".md")));
  }

  [Fact]
  public async Task A_fresh_device_sends_nothing_before_it_has_read_the_cloud()
  {
    using var f = new CloudFolderFixture();
    var b = f.Mac("b", f.DeviceB, read: false);
    f.Write("b", "mine.md", "local");
    await f.Settle(b);
    Assert.Empty(CloudFolderFixture.Journal(b));
    b.MarkCloudRead();
    await f.Settle(b);
    Assert.NotEmpty(CloudFolderFixture.Journal(b));
  }

  [Fact]
  public async Task A_link_a_secret_and_packages_never_leave()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    var outside = Path.Combine(f.Base, "outside");
    Directory.CreateDirectory(outside);
    File.WriteAllText(Path.Combine(outside, "private.txt"), "private");
    // Windows: a folder link (a file link needs a privilege this account may not hold; both are reparse points).
    CloudFolderFixture.LinkFolder(Path.Combine(f.Folder("a"), "link"), outside);
    foreach (var path in new[] { ".env", "id_rsa", "api_token.txt", "server.pem", ".hidden/x.md", "node_modules/m/index.js", "DerivedData/a.o", "draft.md~", "ok.md" })
      f.Write("a", path, "x");
    // A file above the limit (sparse: no real 26 MB written).
    CloudFolderFixture.Sparse(Path.Combine(f.Folder("a"), "big.bin"), 26_000_000);
    await f.Settle(a);
    var keys = CloudFolderFixture.Journal(a).Select(op => op.Source.RecordId).ToHashSet();
    Assert.Equal(["file/folder/ok.md"], keys);
    Assert.Contains(CloudFolderFormat.TooLargeLine(1), a.Coverage().Exclusions);
    // The files kept back by the never-send list are NAMED on the page.
    Assert.Contains(CloudFolderFormat.SecretLine(["api_token.txt", "id_rsa", "server.pem"]), a.PageLines());
  }

  /// Windows (Decker, 15 Nov): Explorer's own files never leave this PC; one that arrives from another device is kept.
  [Fact]
  public async Task Explorers_own_files_are_never_sent_but_one_that_arrives_is_kept()
  {
    using var f = new CloudFolderFixture();
    var mac = f.Mac("mac", f.DeviceA); var pc = f.Mac("pc", f.DeviceB);
    // A Mac's file of that name, as the Mac's own engine records it (its rule does not leave it out).
    CloudFolderFixture.WriteAt(mac.CopyRoot, "Pictures/Thumbs.db", "made on a Mac", f.Clock.Ms);
    mac.Core().ReconcileAll();
    await f.Send(mac, f.DeviceA, pc, new CloudFolderCursor());
    Assert.Equal("made on a Mac", f.Text("pc", "Pictures/Thumbs.db"));
    f.Write("pc", "thumbs.DB", "explorer"); f.Write("pc", "Plans/Desktop.ini", "explorer"); f.Write("pc", "ok.md", "ok");
    await f.Settle(pc);
    Assert.Equal(["file/folder/ok.md"], CloudFolderFixture.Journal(pc).Select(op => op.Source.RecordId).Distinct());
    Assert.Equal("made on a Mac", f.Text("pc", "Pictures/Thumbs.db"));
    Assert.Empty(await pc.NotHereAsync());
  }

  [Fact]
  public void An_arriving_secret_is_refused_before_a_byte_is_kept()
  {
    Assert.NotNull(CloudFolderRules.Refusal(".env"));
    Assert.NotNull(CloudFolderRules.Refusal("keys/credentials.json"));
    Assert.NotNull(CloudFolderRules.Refusal("../x"));
    Assert.Null(CloudFolderRules.Refusal("Plans/plan.md"));
  }
}

public sealed class CloudFolderCostTests
{
  [Fact]
  public async Task An_AI_rewriting_a_file_every_second_is_sent_once_per_window()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    // 60 rewrites, one a second, with a look after each: never still for 3 s, so nothing is sent meanwhile.
    for (var second = 0; second < 60; second++)
    {
      f.Write("a", "live.md", "version " + second);
      await a.LookAsync();
      f.Clock.Advance(1_000);
    }
    Assert.Empty(CloudFolderFixture.Journal(a));
    f.Clock.Advance(4_000); await a.LookAsync();
    Assert.Single(CloudFolderFixture.Journal(a));
    // It keeps changing after that: at most one more within the next minute.
    for (var second = 0; second < 50; second++)
    {
      f.Write("a", "live.md", "again " + second, f.Clock.Ms);
      f.Clock.Advance(1_000);
      if (second % 5 == 4) { f.Clock.Advance(4_000); await a.LookAsync(); }
    }
    Assert.True(CloudFolderFixture.Journal(a).Count <= 2);
  }

  [Fact]
  public void Deletion_retention_is_thirty_days()
  {
    Assert.Equal(30L * 86_400_000, CloudBinGroup.RetentionMilliseconds);
    Assert.Equal(3_000, CloudFolderFormat.Quiet);
  }
}

/// An older build next to this one: it never announced that it understands Cloud folder records, so this PC sends none.
public sealed class CloudFolderOlderBuildTests
{
  [Fact]
  public async Task With_a_device_that_does_not_understand_nothing_is_sent()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA, understands: false);
    a.SetWhoWaits(() => ["MacBook Pro"]);
    f.Write("a", "x.md", "x");
    await f.Settle(a);
    Assert.Empty(CloudFolderFixture.Journal(a));
    // One line names the device that keeps it closed.
    Assert.Contains(CloudFolderFormat.GateLine(["MacBook Pro"]), a.PageLines());
  }
  [Fact]
  public void An_announcement_counts_only_while_fresh_and_of_this_format()
  {
    const long now = 1_900_000_000_000;
    Assert.True(CloudAnnounce.Fresh("v1:" + (now - 1_000), 1, now));
    Assert.False(CloudAnnounce.Fresh("v1:" + (now - 4 * 86_400_000L), 1, now));
    Assert.False(CloudAnnounce.Fresh("1", 1, now));
    Assert.False(CloudAnnounce.Fresh(null, 1, now));
    Assert.Equal("onerule.understands.cloudfolder.abc", CloudAnnounce.FeatureKey("cloudfolder", "ABC"));
  }
  [Fact]
  public void The_kind_has_its_own_domain()
  {
    Assert.Equal("cloud-folder", CloudFolderFormat.Domain);
    Assert.DoesNotContain(CloudFolderFormat.Domain, CloudMemoryFormat.InventoryRows.Select(CloudMemoryFormat.Domain).Append(CloudBootFilesFormat.Domain));
  }
}

/// The five fixes of the Mac's review and the smaller ones, each on two scratch devices.
public sealed class CloudFolderReviewFixTests
{
  /// B's "Linked" is a link to a folder outside. A file arriving under it writes NOTHING outside the folder.
  [Fact]
  public async Task An_arrival_under_a_linked_folder_writes_nothing_outside()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    var outside = Path.Combine(f.Base, "outside");
    Directory.CreateDirectory(outside);
    CloudFolderFixture.LinkFolder(Path.Combine(f.Folder("b"), "Linked"), outside);
    f.Write("a", "Linked/new.md", "should never land outside");
    f.Write("a", "Linked/Deeper/also.md", "nor this");
    await f.Settle(a);
    await f.Send(a, f.DeviceA, b, new CloudFolderCursor());
    await f.Settle(b);
    Assert.Empty(Directory.EnumerateFileSystemEntries(outside));
    // The disk helper itself: no write, no folder made, no removal through a link on the way.
    Assert.ThrowsAny<CloudFailure>(() => CloudFolderDisk.Write(f.Folder("b"), "Linked/x.md", "x"u8.ToArray(), null));
    Assert.Equal(CloudFolderDisk.Kind.Blocked, CloudFolderDisk.Read(f.Folder("b"), "Linked/x.md").Kind);
    Assert.Empty(Directory.EnumerateFileSystemEntries(outside));
  }

  /// Separate incoming packs use the same exact-version rule, with no per-window removal limit.
  [Fact]
  public async Task Removals_in_separate_packs_apply_without_a_question()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    for (var i = 0; i < 30; i++) f.Write("a", "f" + i + ".md", "file " + i);
    await f.Settle(a);
    var cursor = new CloudFolderCursor();
    await f.Send(a, f.DeviceA, b, cursor);
    for (var i = 0; i < 13; i++) await a.StoreRemoveAsync("f" + i + ".md", CloudFolderFixture.Hash("file " + i));
    var engine = a.Core();
    foreach (var row in engine.JournalAfter(cursor.Seq))
      foreach (var op in engine.Operations(row)) await f.Apply(b, [op], f.DeviceA);
    Assert.Null(b.WaitingAnswer());
    Assert.Equal(13, b.Bin().Count);
  }

  /// 200 MB a day per device. Past it nothing more is recorded (Sync now too) and the page says so.
  [Fact]
  public async Task The_daily_budget_holds_sends_and_says_its_line()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    f.Write("a", "first.md", "first"); await f.Settle(a);
    var before = CloudFolderFixture.Journal(a).Count;
    // Today's sends so far: 10 bytes short of the budget.
    a.SetControl("daySent", (CloudFolderFormat.DailySendBytes - 10).ToString(System.Globalization.CultureInfo.InvariantCulture));
    f.Write("a", "second.md", "more than ten bytes"); await f.Settle(a);
    await a.SendNowAsync();
    Assert.Equal(before, CloudFolderFixture.Journal(a).Count);
    Assert.Contains(CloudFolderFormat.DayFullLine, a.PageLines());
    // The next day it goes.
    f.Clock.Advance(CloudFolderFormat.Day); await f.Settle(a);
    Assert.Equal(before + 1, CloudFolderFixture.Journal(a).Count);
  }

  /// At most 6 versions of one file a day; the 7th waits until the file has been still for an hour.
  [Fact]
  public async Task The_seventh_version_of_a_file_waits_for_an_hour_of_stillness()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    for (var version = 0; version < 6; version++)
    {
      f.Write("a", "busy.md", "version " + version); await f.Settle(a);
      f.Clock.Advance(11 * 60_000);
    }
    Assert.Equal(6, CloudFolderFixture.Journal(a).Count);
    f.Write("a", "busy.md", "version 6"); await f.Settle(a);
    Assert.Equal(6, CloudFolderFixture.Journal(a).Count);
    Assert.Contains(CloudFolderFormat.BusyLine(1), a.PageLines());
    f.Clock.Advance(CloudFolderFormat.StillAfterLimit); await a.LookAsync();
    Assert.Equal(7, CloudFolderFixture.Journal(a).Count);
  }

  /// Below 3 GB of room left in the account the folder sends nothing, and says so.
  [Fact]
  public async Task The_lifetime_floor_holds_sends_and_says_its_line()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    a.SetRoomLeft(() => 2_000_000_000);
    f.Write("a", "x.md", "x"); await f.Settle(a);
    Assert.Empty(CloudFolderFixture.Journal(a));
    Assert.Contains(CloudFolderFormat.RoomLowLine, a.PageLines());
    a.SetRoomLeft(() => 9_000_000_000);
    await a.LookAsync();
    Assert.Single(CloudFolderFixture.Journal(a));
    Assert.DoesNotContain(CloudFolderFormat.RoomLowLine, a.PageLines());
  }

  /// Below 2 GB free on this PC nothing that arrives is kept or written; it waits, with a line.
  [Fact]
  public async Task The_free_disk_floor_holds_arrivals_and_says_its_line()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB, freeDisk: 1_000_000_000);
    f.Write("a", "x.md", "x"); await f.Settle(a);
    var operations = CloudFolderFixture.Journal(a);
    await Assert.ThrowsAsync<CloudFailure>(() => b.ApplyAsync(operations[0], new CloudImportOrigin(f.DeviceA, 1, null, false), CancellationToken.None));
    Assert.Null(f.Text("b", "x.md"));
    Assert.Contains(CloudFolderFormat.DiskLowLine, b.PageLines());
  }

  /// Past 1 GB new and changed files stay here (sparse files: nothing real is written).
  [Fact]
  public async Task The_one_gigabyte_cap_holds_sends_and_says_its_line()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    for (var i = 0; i < 41; i++) CloudFolderFixture.Sparse(Path.Combine(f.Folder("a"), "big" + i + ".bin"), 25_000_000);
    f.Write("a", "small.md", "small"); await f.Settle(a);
    Assert.Empty(CloudFolderFixture.Journal(a));
    Assert.Contains(CloudFolderFormat.FolderFullLine, a.PageLines());
  }

  /// Once a file has arrived and is placed, its part bodies are gone from the receiving device.
  [Fact]
  public async Task Part_bodies_are_gone_after_assembly()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    f.Write("a", "doc.md", string.Concat(Enumerable.Repeat("words ", 20_000))); await f.Settle(a);
    await f.Send(a, f.DeviceA, b, new CloudFolderCursor());
    Assert.Equal(120_000, f.Text("b", "doc.md")?.Length);
    Assert.Equal(0, b.Core().StoredPartBytes());
    // The same records again are still known: applying them twice changes nothing.
    await f.Apply(b, CloudFolderFixture.Journal(a), f.DeviceA);
    Assert.Equal(120_000, f.Text("b", "doc.md")?.Length);
  }

  /// A removed Cloud folder file is in the ONE Bin's groups (name, which device, when); the folder's "newer one is in
  /// use" lines stay where they are. Put back all brings the file back. (The page itself is lane U's.)
  [Fact]
  public async Task The_bin_rows_and_put_back_all()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    f.Write("a", "keep.md", "k"); f.Write("a", "gone.md", "goes"); await f.Settle(a);
    await a.StoreRemoveAsync("gone.md", CloudFolderFixture.Hash("goes")); await f.Settle(a);
    var groups = await a.BinGroupsAsync();
    var group = groups.First(g => g.Items.Any(i => i.Id == "gone.md"));
    Assert.True(groups.Count == 1 && group.Count == 1 && group.By == CloudDeleteBy.Person);
    Assert.Equal("gone.md", group.Items[0].Name);
    Assert.Equal("cloudFolder", group.Items[0].Kind);
    Assert.Equal(["gone.md"], (await a.PutBackGroupAsync(group.Id)).Select(i => i.Id));
    Assert.Equal("goes", f.Text("a", "gone.md"));
    Assert.Empty(await a.BinGroupsAsync());
  }

  /// Each later by-hand disappearance remains device-only, with no answer path.
  [Fact]
  public async Task Later_by_hand_removals_stay_local_without_an_answer()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    for (var i = 0; i < 30; i++) f.Write("a", "f" + i + ".md", "file " + i);
    await f.Settle(a);
    var before = CloudFolderFixture.Journal(a).Count;
    for (var i = 0; i < 12; i++) f.Remove("a", "f" + i + ".md");
    await f.Settle(a);
    f.Remove("a", "f20.md"); await f.Settle(a);
    Assert.Equal(13, (await a.NotHereAsync()).Count);
    Assert.Null(a.WaitingAnswer());
    Assert.Equal(before, CloudFolderFixture.Journal(a).Count);
  }

  /// "Plan.md" on one device and "plan.md" on the other: both files stay; the arrival is kept beside under a plain new
  /// name; nothing is replaced and no removal is sent.
  [Fact]
  public async Task Names_differing_only_by_capitals_keep_both_files()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    b.SetDeviceName(_ => "Mac mini");
    f.Write("a", "Plan.md", "from A");
    f.Write("b", "plan.md", "from B");
    await f.Settle(a); await f.Settle(b);
    CloudFolderCursor fromA = new(), fromB = new();
    await f.Send(a, f.DeviceA, b, fromA);
    await f.Settle(b);
    var names = Directory.EnumerateFileSystemEntries(f.Folder("b")).Select(Path.GetFileName).ToArray();
    var caseBlind = !names.Contains("Plan.md") || !names.Contains("plan.md");
    Assert.Equal("from B", f.Text("b", "plan.md"));
    if (caseBlind) Assert.Equal("from A", f.Text("b", "Plan (from Mac mini).md"));
    var sentByB = await f.Send(b, f.DeviceB, a, fromB);
    Assert.DoesNotContain(sentByB, op => op.Kind == "archive");
    Assert.Equal("from A", f.Text("a", "Plan.md"));
  }

  /// A file still being written while it is read waits (nothing is recorded from a half-written file).
  [Fact]
  public async Task A_half_written_file_waits()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    f.Write("a", "growing.log", "part one");
    await a.LookAsync(); f.Clock.Advance(4_000);
    var full = Path.Combine(f.Folder("a"), "growing.log");
    a.AfterReadForTests = _ => File.AppendAllText(full, " and part two");
    await a.LookAsync();
    Assert.Empty(CloudFolderFixture.Journal(a));
    a.AfterReadForTests = null;
    f.Clock.Advance(4_000); await a.LookAsync(); f.Clock.Advance(4_000); await a.LookAsync();
    Assert.Single(CloudFolderFixture.Journal(a));
  }
}

public sealed class CloudFolderStatusLineTests
{
  [Fact]
  public void A_missing_root_has_a_quiet_line()
  {
    Assert.Equal("Your Cloud folder is not on this PC", CloudFolderWords.WaitingAnswer(new CloudFolderAnswer(true)));
    Assert.Equal("Make it again", CloudFolderWords.MakeItAgain);
  }
}

/// An arrival written by sync is never captured as a local change: ten passes each way with every journal passed on.
public sealed class CloudFolderNoEchoTests
{
  /// Every version a device journaled: one upload of a file's bytes (its first part counts it once).
  private static int Versions(CloudFolderOwner owner) => CloudFolderFixture.Journal(owner).Count(op => op.Kind == "put" && (op.Source.Offset ?? 0) == 0);
  private static async Task Passes(CloudFolderFixture f, CloudFolderOwner a, CloudFolderOwner b, CloudFolderCursor fromA, CloudFolderCursor fromB)
  {
    for (var i = 0; i < 10; i++)
    {
      await f.Settle(a); await f.Settle(b);
      await f.Send(a, f.DeviceA, b, fromA);
      await f.Send(b, f.DeviceB, a, fromB);
    }
  }

  [Fact]
  public async Task A_file_sent_once_stays_sent_once()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    f.Write("a", "plan.md", "the plan"); await f.Settle(a);
    CloudFolderCursor fromA = new(), fromB = new();
    await f.Send(a, f.DeviceA, b, fromA);
    Assert.Equal("the plan", f.Text("b", "plan.md"));
    await Passes(f, a, b, fromA, fromB);
    Assert.Equal(1, Versions(a));
    Assert.Equal(0, Versions(b));
    Assert.Empty(a.Versions("plan.md"));
    Assert.Empty(b.Versions("plan.md"));
  }

  /// The same name made apart on both devices, the arrived one newer on B: B uses it WITHOUT recording it again.
  [Fact]
  public async Task The_newer_arrival_is_never_sent_back()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    var t = f.Clock.Ms;
    f.Write("b", "notes.txt", "from B", t - 60_000);
    f.Write("a", "notes.txt", "from A", t - 30_000);
    await f.Settle(a); await f.Settle(b);
    CloudFolderCursor fromA = new(), fromB = new();
    await f.Send(b, f.DeviceB, a, fromB);
    await f.Send(a, f.DeviceA, b, fromA);
    Assert.Equal("from A", f.Text("a", "notes.txt"));
    Assert.Equal("from A", f.Text("b", "notes.txt"));
    var keptA = a.Versions("notes.txt").Count; var keptB = b.Versions("notes.txt").Count;
    await Passes(f, a, b, fromA, fromB);
    Assert.Equal(1, Versions(a));
    Assert.Equal(1, Versions(b));
    Assert.Equal(keptA, a.Versions("notes.txt").Count);
    Assert.Equal(keptB, b.Versions("notes.txt").Count);
    Assert.True(f.Text("a", "notes.txt") == "from A" && f.Text("b", "notes.txt") == "from A");
  }
}

/// His own work set aside by sync is never trimmed, and nothing is swept on a clock the service has not confirmed.
public sealed class CloudFolderHisWorkTests
{
  /// B's edit loses to A's newer one (it never left B), then A saves again on top: B's edit is still kept and opens.
  [Fact]
  public async Task An_edit_that_lost_is_still_kept_after_a_second_arrival()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    f.Write("a", "plan.md", "v1"); await f.Settle(a);
    var fromA = new CloudFolderCursor();
    await f.Send(a, f.DeviceA, b, fromA);
    f.Clock.Advance(60_000);
    var t = f.Clock.Ms;
    f.Write("b", "plan.md", "B's edit", t - 30_000);
    f.Write("a", "plan.md", "A's edit", t - 10_000);
    await f.Settle(a);
    await f.Send(a, f.DeviceA, b, fromA);
    Assert.Equal("A's edit", f.Text("b", "plan.md"));
    f.Clock.Advance(120_000);
    f.Write("a", "plan.md", "A's second save"); await f.Settle(a);
    await f.Send(a, f.DeviceA, b, fromA);
    Assert.Equal("A's second save", f.Text("b", "plan.md"));
    var mine = b.Versions("plan.md").First(k => k.Sha256 == CloudFolderFixture.Hash("B's edit"));
    Assert.Equal("B's edit", File.ReadAllText(b.Openable("plan.md", mine.Sha256)!));
  }

  /// Put back over a different file of the same name: that file is kept (his), and opens.
  [Fact]
  public async Task The_file_put_back_displaces_is_kept()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    f.Write("a", "keep.md", "k"); f.Write("a", "gone.md", "old text"); await f.Settle(a);
    await a.StoreRemoveAsync("gone.md", CloudFolderFixture.Hash("old text")); await f.Settle(a);
    f.Write("a", "gone.md", "new text written meanwhile");
    Assert.True(await a.PutBackAsync("gone.md"));
    Assert.Equal("old text", f.Text("a", "gone.md"));
    var displaced = a.Versions("gone.md").First(k => k.Sha256 == CloudFolderFixture.Hash("new text written meanwhile"));
    Assert.Equal("new text written meanwhile", File.ReadAllText(a.Openable("gone.md", displaced.Sha256)!));
  }

  /// No service clock: the daily sweep never runs, however far this PC's clock moves.
  [Fact]
  public async Task Nothing_is_swept_while_the_service_clock_is_unknown()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    f.Write("a", "keep.md", "k"); f.Write("a", "gone.md", "goes"); await f.Settle(a);
    await a.StoreRemoveAsync("gone.md", CloudFolderFixture.Hash("goes")); await f.Settle(a);
    Assert.Single(a.Bin());
    f.Clock.Advance(40 * CloudFolderFormat.Day);
    Assert.False(await a.SweepDailyAsync());
    await a.SendNowAsync();
    Assert.Single(a.Bin());
  }
}
