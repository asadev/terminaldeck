using System.Text;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Receiver;

namespace TerminalDeck.Core.Tests.Cloud;

// Lane F: artifacts that travel, case for case the Mac's CloudArtifactsTests.swift (suites Travel, Safety, Limit,
// OlderBuild). Two "devices" (each with its own scratch project folder, store, state and keeper) and the records passed
// between them as the Windows sync passes them. Everything lives under this test run's own output folder.
public sealed class CloudArtifactsFixture : IDisposable
{
  private readonly CloudFolderFixture inner = new();
  public string Base => inner.Base;
  public string DeviceA => inner.DeviceA;
  public string DeviceB => inner.DeviceB;
  public CloudFolderClock Clock => inner.Clock;
  public void Dispose() => inner.Dispose();
  /// The project folder "site" on one device (its files are only ever read).
  public string Project(string mac) => Path.Combine(Base, mac, "projects", "site");
  public string Store(string mac) => Path.Combine(Base, mac, "data", "cloud", "subject", "artifacts-files");
  public CloudArtifacts Mac(string name, string device, bool understands = true, bool read = true, long freeDisk = 500_000_000_000, bool announced = false)
  {
    Directory.CreateDirectory(Project(name));
    var clock = Clock;
    var made = new CloudArtifacts(device, Store(name), Path.Combine(Base, name, "data", "cloud", "subject", "artifacts"), inner.Keeper(name), () => understands,
      () => freeDisk, () => clock.Ms);
    made.PrepareStore();
    made.Owner.SetDeleteRuleAnnounced(_ => announced);
    if (read) made.Owner.MarkCloudRead();
    return made;
  }
  /// An artifact a session made in the project folder.
  public CloudArtifactEntry Make(string mac, string relPath, string text, long? modified = null)
  {
    CloudFolderFixture.WriteAt(Project(mac), relPath, text, modified ?? Clock.Ms - 10_000);
    return Entry(mac, relPath);
  }
  public CloudArtifactEntry Entry(string mac, string relPath, string project = "site") =>
    new(project, "Site", Project(mac), relPath, CloudArtifactRules.LastComponent(relPath), "Reviewer", Clock.Ms - 60_000);
  public Task Settle(CloudArtifacts owner) => inner.Settle(owner.Owner);
  public Task<IReadOnlyList<CloudOperation>> Send(CloudArtifacts from, string device, CloudArtifacts to, CloudFolderCursor cursor) => inner.Send(from.Owner, device, to.Owner, cursor);
  public static IReadOnlyList<CloudOperation> Journal(CloudArtifacts owner) => CloudFolderFixture.Journal(owner.Owner);
  /// Uploads of one file's bytes (its first part counts it once).
  public static int Uploads(CloudArtifacts owner, string key) => Journal(owner).Count(op => op.Kind == "put" && op.Source.RecordId == key && (op.Source.Offset ?? 0) == 0);
}

public sealed class CloudArtifactsTravelTests
{
  [Fact]
  public async Task An_artifact_made_on_one_device_is_on_the_other_with_its_name_project_maker_and_date_and_opens()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    const string page = "<html><head><title>Weekly</title></head><body>report</body></html>";
    var made = f.Make("a", "out/report.html", page);
    await a.FeedAsync([made]);
    await f.Settle(a);
    var sent = await f.Send(a, f.DeviceA, b, new CloudFolderCursor());
    Assert.All(sent, op => Assert.Equal("artifacts", op.Domain));
    var arrived = b.Items().First(i => i.RelPath == "out/report.html");
    Assert.Equal("report.html", arrived.Name);
    Assert.Equal("Site", arrived.Project);
    Assert.Equal("site", arrived.ProjectId);
    Assert.Equal("Reviewer", arrived.MadeBy);
    Assert.Equal(f.DeviceA, arrived.Device);
    Assert.Equal("Web page", arrived.Type);
    Assert.Equal(made.CreatedAt, arrived.CreatedAt);
    // It opens: the file is in B's store, exactly the bytes made on A; B's project folder is never written.
    Assert.Equal(page, File.ReadAllText(arrived.File));
    Assert.StartsWith(f.Store("b") + Path.DirectorySeparatorChar, arrived.File, StringComparison.Ordinal);
    Assert.False(File.Exists(Path.Combine(f.Project("b"), "out", "report.html")));
    Assert.Equal(1, b.Counts().Artifacts);
  }

  /// Never sent back: one upload after ten passes on both devices, B's own feed running each time.
  [Fact]
  public async Task An_arrived_artifact_is_never_sent_back()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    var made = f.Make("a", "notes/summary.md", "# Summary");
    CloudFolderCursor fromA = new(), fromB = new();
    for (var i = 0; i < 10; i++)
    {
      await a.FeedAsync([made]); await b.FeedAsync([]);
      await f.Settle(a); await f.Settle(b);
      await f.Send(a, f.DeviceA, b, fromA);
      await f.Send(b, f.DeviceB, a, fromB);
    }
    Assert.Equal(1, CloudArtifactsFixture.Uploads(a, "file/artifacts/site/notes/summary.md"));
    Assert.Equal(0, CloudArtifactsFixture.Uploads(b, "file/artifacts/site/notes/summary.md"));
    Assert.Empty(CloudArtifactsFixture.Journal(b));
  }

  /// Both devices have the project: a file this device never copied before only replaces a newer arrival when newer.
  [Fact]
  public async Task An_older_copy_of_the_same_project_never_replaces_a_newer_arrival()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    var t = f.Clock.Ms;
    await a.FeedAsync([f.Make("a", "plan.md", "newer from A", t - 1_000)]);
    await f.Settle(a);
    await f.Send(a, f.DeviceA, b, new CloudFolderCursor());
    await b.FeedAsync([f.Make("b", "plan.md", "older on B", t - 600_000)]);
    await f.Settle(b);
    Assert.Empty(CloudArtifactsFixture.Journal(b));
    var item = b.Items().First(i => i.RelPath == "plan.md");
    Assert.Equal("newer from A", File.ReadAllText(item.File));
  }

  /// Windows: the catalogue's entries come from the Receiver's recorded outputs, inside the project's one folder only.
  [Fact]
  public void The_catalogue_feeds_only_artifacts_inside_their_projects_folder()
  {
    using var f = new CloudArtifactsFixture();
    var root = f.Project("a");
    var at = DateTimeOffset.FromUnixTimeMilliseconds(1_900_000_000_000);
    var artifacts = new[]
    {
      new ReceiverArtifact("1", "site", root, "out/report.html", "s1", at),
      new ReceiverArtifact("2", "site", Path.Combine(f.Base, "elsewhere"), "x.html", "s1", at),
      new ReceiverArtifact("3", "site", root, "hidden.html", "s1", at, Hidden: true),
      new ReceiverArtifact("4", "other", root, "y.html", "s1", at)
    };
    var entries = CloudArtifacts.EntriesFrom(artifacts, id => id == "site" ? ("Site", root) : null);
    var entry = Assert.Single(entries);
    Assert.Equal("out/report.html", entry.RelPath);
    Assert.Equal("Site", entry.ProjectName);
    Assert.Equal(1_900_000_000_000, entry.CreatedAt);
  }
}

public sealed class CloudArtifactsSafetyTests
{
  [Fact]
  public async Task A_removal_goes_to_both_bins_and_put_back_brings_it_back_on_both()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    await a.FeedAsync([f.Make("a", "keep.html", "<p>stays</p>"), f.Make("a", "gone.html", "<p>goes</p>")]);
    await f.Settle(a);
    CloudFolderCursor fromA = new(), fromB = new();
    await f.Send(a, f.DeviceA, b, fromA);
    Assert.Equal(2, b.Items().Count);
    // His Remove on A's page. His project file stays.
    Assert.True(await a.RemoveAsync("site/gone.html"));
    Assert.True(File.Exists(Path.Combine(f.Project("a"), "gone.html")));
    await f.Settle(a);
    Assert.Equal(["site/gone.html"], a.Bin().Select(k => k.Path));
    var removal = await f.Send(a, f.DeviceA, b, fromA);
    Assert.Contains(removal, op => op.Kind == "archive");
    Assert.Equal(["keep.html"], b.Items().Select(i => i.RelPath));
    Assert.Equal(["site/gone.html"], b.Bin().Select(k => k.Path));
    // Not copied again on A while his file stays as it is.
    await a.FeedAsync([f.Entry("a", "gone.html")]);
    Assert.Equal(["keep.html"], a.Items().Select(i => i.RelPath));
    // Put back on B: back on both, out of both Bins.
    Assert.True(await b.PutBackAsync("site/gone.html"));
    await f.Settle(b);
    await f.Send(b, f.DeviceB, a, fromB);
    Assert.Equal(new HashSet<string> { "keep.html", "gone.html" }, a.Items().Select(i => i.RelPath).ToHashSet());
    Assert.Empty(a.Bin());
    Assert.Empty(b.Bin());
  }

  [Fact]
  public async Task An_emptied_store_stays_absent_until_make_it_again()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA);
    await a.FeedAsync(new[] { "1.md", "2.md", "3.md" }.Select(n => f.Make("a", n, n)).ToArray());
    await f.Settle(a);
    var before = CloudArtifactsFixture.Journal(a).Count;
    foreach (var entry in Directory.EnumerateFileSystemEntries(f.Store("a")).ToArray())
      if (Directory.Exists(entry)) Directory.Delete(entry, recursive: true); else File.Delete(entry);
    await f.Settle(a);
    Assert.Equal(before, CloudArtifactsFixture.Journal(a).Count);
    Assert.Empty(await a.NotHereAsync());
    Assert.True(a.Owner.WaitingAnswer()?.FolderMissing);
    Assert.Empty(a.Items());
    await a.Owner.MakeFolderAgainAsync();
    Assert.Equal(3, a.Items().Count);
  }

  [Fact]
  public async Task A_missing_store_sends_nothing()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA);
    await a.FeedAsync([f.Make("a", "x.md", "x")]); await f.Settle(a);
    var before = CloudArtifactsFixture.Journal(a).Count;
    Directory.Delete(f.Store("a"), recursive: true);
    await f.Settle(a); f.Clock.Advance(4_000); await a.Owner.LookAsync();
    Assert.Equal(before, CloudArtifactsFixture.Journal(a).Count);
    Assert.True(a.Owner.WaitingAnswer()?.FolderMissing);
  }

  /// A large explicit group has no sending limit or answer step.
  [Fact]
  public async Task A_burst_of_explicit_removals_needs_no_answer()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA);
    await a.FeedAsync(Enumerable.Range(0, 30).Select(i => f.Make("a", "r" + i + ".md", "report " + i)).ToArray());
    await f.Settle(a);
    for (var i = 0; i < 12; i++) Assert.True(await a.RemoveAsync("site/r" + i + ".md"));
    await f.Settle(a);
    Assert.Null(a.Owner.WaitingAnswer());
    Assert.Equal(12, a.Bin().Count);
    Assert.Equal(24, CloudArtifactsFixture.Journal(a).Count(op => op.Kind == "archive"));
  }

  /// Six artifacts he removed on the page (twelve files with their descriptions) are sent without a second question.
  [Fact]
  public async Task Removing_six_artifacts_sends_them_without_a_second_question()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA);
    await a.FeedAsync(Enumerable.Range(0, 30).Select(i => f.Make("a", "r" + i + ".md", "report " + i)).ToArray());
    await f.Settle(a);
    for (var i = 0; i < 6; i++) Assert.True(await a.RemoveAsync("site/r" + i + ".md"));
    await f.Settle(a);
    Assert.Null(a.Owner.WaitingAnswer());
    Assert.Equal(12, CloudArtifactsFixture.Journal(a).Count(op => op.Kind == "archive"));
    Assert.Equal(6, a.Bin().Count);
  }

  /// Every arriving removal applies to its exact parent; artifact descriptions are kept in the same Bin.
  [Fact]
  public async Task Removals_arrive_counted_in_artifacts()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    await a.FeedAsync(Enumerable.Range(0, 30).Select(i => f.Make("a", "r" + i + ".md", "report " + i)).ToArray());
    await f.Settle(a);
    var fromA = new CloudFolderCursor();
    await f.Send(a, f.DeviceA, b, fromA);
    Assert.Equal(30, b.Items().Count);
    for (var i = 0; i < 6; i++) Assert.True(await a.RemoveAsync("site/r" + i + ".md"));
    await f.Settle(a);
    await f.Send(a, f.DeviceA, b, fromA);
    Assert.Null(b.Owner.WaitingAnswer());
    Assert.Equal(24, b.Items().Count);
    Assert.Equal(6, b.Bin().Count);
    // Eleven more go immediately too; there is no sending or applying window.
    f.Clock.Advance(1_000);
    for (var i = 6; i < 17; i++) Assert.True(await a.RemoveAsync("site/r" + i + ".md"));
    await f.Settle(a);
    Assert.Null(a.Owner.WaitingAnswer());
    await f.Send(a, f.DeviceA, b, fromA);
    Assert.Null(b.Owner.WaitingAnswer());
    Assert.Equal(13, b.Items().Count);
    Assert.Equal(17, b.Bin().Count);
  }

  /// Removing every artifact on the page (the store is then empty) is his own press: not asked again.
  [Fact]
  public async Task Removing_the_last_artifacts_on_the_page_is_not_asked_again()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA);
    await a.FeedAsync(new[] { "1.md", "2.md" }.Select(n => f.Make("a", n, n)).ToArray());
    await f.Settle(a);
    Assert.True(await a.RemoveAsync("site/1.md"));
    Assert.True(await a.RemoveAsync("site/2.md"));
    await f.Settle(a);
    Assert.Null(a.Owner.WaitingAnswer());
    Assert.Equal(4, CloudArtifactsFixture.Journal(a).Count(op => op.Kind == "archive"));
  }

  [Fact]
  public async Task A_fresh_device_copies_and_sends_nothing_before_it_has_read_the_cloud()
  {
    using var f = new CloudArtifactsFixture();
    var b = f.Mac("b", f.DeviceB, read: false);
    Assert.Equal(0, await b.FeedAsync([f.Make("b", "mine.md", "local")]));
    await f.Settle(b);
    Assert.Empty(CloudArtifactsFixture.Journal(b));
    b.Owner.MarkCloudRead();
    Assert.Equal(1, await b.FeedAsync([f.Entry("b", "mine.md")]));
    await f.Settle(b);
    Assert.NotEmpty(CloudArtifactsFixture.Journal(b));
  }

  /// No write lands outside the store: a walk out of the project, a project name with a slash, an arriving record for a
  /// path outside, and a linked folder inside the store all write nothing outside.
  [Fact]
  public async Task A_write_outside_the_store_is_impossible()
  {
    using var f = new CloudArtifactsFixture();
    Assert.Null(CloudArtifactsFormat.StorePath("site", "../escape.html"));
    Assert.Null(CloudArtifactsFormat.StorePath("a/b", "x.html"));
    Assert.Null(CloudArtifactsFormat.StorePath("..", "x.html"));
    Assert.Null(CloudArtifactsFormat.StorePath("site", "/Users/x/outside.html"));
    Assert.Equal("site/out/report.html", CloudArtifactsFormat.StorePath("site", "out/report.html"));
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    var outside = Path.Combine(f.Base, "outside");
    Directory.CreateDirectory(outside);
    // B's store holds a link where the project's folder would be.
    CloudFolderFixture.LinkFolder(Path.Combine(f.Store("b"), "site"), outside);
    await a.FeedAsync([f.Make("a", "deep/x.html", "<p>never outside</p>")]);
    await f.Settle(a);
    await f.Send(a, f.DeviceA, b, new CloudFolderCursor());
    await f.Settle(b);
    Assert.Empty(Directory.EnumerateFileSystemEntries(outside));
    // A source under a linked folder of the project is never read either.
    CloudFolderFixture.LinkFolder(Path.Combine(f.Project("a"), "linked"), outside);
    File.WriteAllText(Path.Combine(outside, "y.html"), "secret elsewhere");
    Assert.Equal(0, await a.FeedAsync([f.Entry("a", "linked/y.html")]));
    // An arriving path that walks out, is hidden or is on the never-send list is refused before a byte is kept.
    foreach (var path in new[] { "site/../../x.html", "../x.html", "site/.hidden/x.html", "site/.env", "site/keys/id_rsa" })
      Assert.NotNull(CloudFileKind.Artifacts.Refusal(path));
  }

  [Fact]
  public async Task Names_differing_only_by_capitals_keep_both()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    await b.FeedAsync([f.Make("b", "Report.md", "B's")]); await f.Settle(b);
    await a.FeedAsync([f.Make("a", "report.md", "A's")]); await f.Settle(a);
    await f.Send(a, f.DeviceA, b, new CloudFolderCursor());
    var texts = b.Items().Select(i => File.ReadAllText(i.File)).ToHashSet();
    Assert.Equal(new HashSet<string> { "B's", "A's" }, texts);
  }
}

public sealed class CloudArtifactsLimitTests
{
  [Fact]
  public async Task A_large_one_a_secret_one_and_an_outside_one_stay_on_this_PC_each_with_its_line()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA);
    // 26 MB, sparse (nothing real is written).
    CloudFolderFixture.Sparse(Path.Combine(f.Project("a"), "video.mp4"), 26_000_000);
    var entries = new[]
    {
      f.Entry("a", "video.mp4"),
      f.Make("a", "deploy-notes.md", "Use Authorization: Bearer abcdefghijklmnop1234 to call it."),
      f.Make("a", "keys/server.pem", "-----BEGIN PRIVATE KEY-----x-----END PRIVATE KEY-----"),
      f.Make("a", "page.html", "<script>const token = readToken(); const pic = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'</script>"),
      new CloudArtifactEntry("site", "Site", f.Project("a"), "/tmp/outside.html", "outside.html", null, 1)
    };
    await a.FeedAsync(entries);
    await f.Settle(a);
    // Only the ordinary page travels (code and pictures in a page are not secrets).
    var keys = CloudArtifactsFixture.Journal(a).Select(op => op.Source.RecordId).ToHashSet();
    Assert.Equal(new HashSet<string> { "file/artifacts/site/page.html", "file/artifacts/site/page.html" + CloudArtifactsFormat.AboutSuffix }, keys);
    var lines = a.PageLines();
    Assert.Contains(CloudArtifactsFormat.TooLargeLine(1), lines);
    Assert.Contains(CloudArtifactsFormat.SecretNameLine(["deploy-notes.md", "server.pem"]), lines);
  }

  [Fact]
  public async Task The_folder_and_artifacts_share_one_daily_budget()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA);
    var budget = new CloudDayBudget(Path.Combine(f.Base, "a", "data", "cloud", "subject", "file-day-budget.json"));
    a.Owner.SetDayBudget(budget);
    // The Cloud folder sent nearly all of today's 200 MB.
    budget.Add(CloudFolderFormat.DailySendBytes - 10, f.Clock.Ms / CloudFolderFormat.Day);
    await a.FeedAsync([f.Make("a", "x.md", "more than ten bytes")]);
    await f.Settle(a); await a.Owner.SendNowAsync();
    Assert.Empty(CloudArtifactsFixture.Journal(a));
    Assert.Contains(CloudArtifactsFormat.DayFullLine, a.PageLines());
    f.Clock.Advance(CloudFolderFormat.Day); await f.Settle(a);
    Assert.NotEmpty(CloudArtifactsFixture.Journal(a));
    Assert.True(budget.Sent(f.Clock.Ms / CloudFolderFormat.Day) > 0);
  }

  [Fact]
  public async Task The_room_and_disk_floors_hold_with_their_lines()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB, freeDisk: 1_000_000_000);
    a.Owner.SetRoomLeft(() => 2_000_000_000);
    await a.FeedAsync([f.Make("a", "x.md", "x")]); await f.Settle(a);
    Assert.Empty(CloudArtifactsFixture.Journal(a));
    Assert.Contains(CloudArtifactsFormat.RoomLowLine, a.PageLines());
    a.Owner.SetRoomLeft(() => 9_000_000_000);
    await a.Owner.LookAsync();
    var operations = CloudArtifactsFixture.Journal(a);
    Assert.NotEmpty(operations);
    await Assert.ThrowsAsync<CloudFailure>(() => b.Owner.ApplyAsync(operations[0], new CloudImportOrigin(f.DeviceA, 1, null, false), CancellationToken.None));
    Assert.Empty(b.Items());
    Assert.Contains(CloudArtifactsFormat.DiskLowLine, b.PageLines());
  }

  [Fact]
  public void The_numbers_are_the_owners_and_the_shared_ones()
  {
    var kind = CloudFileKind.Artifacts;
    Assert.Equal(25_000_000, kind.MaximumFileBytes);
    Assert.Equal(1_000_000_000, kind.MaximumFolderBytes);
    Assert.Equal("artifacts", kind.Domain);
    Assert.Equal(30L * 86_400_000, CloudBinGroup.RetentionMilliseconds);
    Assert.True(CloudFolderFormat.DailySendBytes == 200_000_000 && CloudFolderFormat.VersionsPerDay == 6);
    Assert.True(CloudFolderFormat.RoomFloor == 3_000_000_000 && CloudFolderFormat.DiskFloor == 2_000_000_000);
    Assert.True(CloudFileKind.CloudFolder.Domain == "cloud-folder" && CloudFileKind.CloudFolder.SourceId == "folder");
    Assert.Equal("cloudFolder", CloudFileKind.CloudFolder.KeeperKind);
  }
}

/// An older build next to this one: it never announces artifacts, so this PC sends none; the kind is a domain of its own,
/// and neither kind's owner takes the other's records.
public sealed class CloudArtifactsOlderBuildTests
{
  [Fact]
  public async Task With_a_device_that_does_not_understand_nothing_is_sent_and_the_device_is_named()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA, understands: false);
    a.Owner.SetWhoWaits(() => ["MacBook Pro"]);
    await a.FeedAsync([f.Make("a", "x.md", "x")]);
    await f.Settle(a);
    Assert.Empty(CloudArtifactsFixture.Journal(a));
    Assert.Contains(CloudArtifactsFormat.GateLine(["MacBook Pro"]), a.PageLines());
  }

  [Fact]
  public async Task Each_kind_refuses_the_others_records()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA);
    await a.FeedAsync([f.Make("a", "x.md", "x")]); await f.Settle(a);
    var operations = CloudArtifactsFixture.Journal(a);
    Assert.NotEmpty(operations);
    var clock = f.Clock;
    var folder = new CloudFolderOwner(f.DeviceB, Path.Combine(f.Base, "b", "home", "Terminal Deck Cloud"), Path.Combine(f.Base, "b", "data", "cloud-folder"),
      CloudBin.Shared(Path.Combine(f.Base, "b", "data", "archive", "versions")), () => true, freeDisk: () => 500_000_000_000, now: () => clock.Ms);
    var refused = await Assert.ThrowsAsync<CloudFailure>(() => folder.ApplyAsync(operations[0], new CloudImportOrigin(f.DeviceA, 1, null, false), CancellationToken.None));
    Assert.Equal("invalid_request", refused.Code);
    Assert.Equal("artifacts", CloudArtifactsFormat.Domain);
    Assert.Equal("onerule.understands.artifacts.abc", CloudAnnounce.FeatureKey(CloudArtifactsFormat.Feature, "ABC"));
  }
}
