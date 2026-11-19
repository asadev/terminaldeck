using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// Folders that travel with a project (19 Nov 2026), case for case the Mac's ProjectFoldersTravelTests.swift and its
// rules test: two devices, each with the same project in a DIFFERENT folder, one owner over many project folders each,
// records passed as the Windows sync passes them. Scratch folders only.
public sealed class ProjectFoldersTravelTests
{
  private const string ProjectId = "project-deck";
  /// Computed outside this code: "p" + the first 16 hex of SHA-256("td-project-folders\nproject-deck").
  private const string Key = "p402830051885cc4d";

  private static string Project(CloudFolderFixture f, string mac) => Path.Combine(f.Base, mac, "home", mac == "a" ? "Deck Dev" : Path.Combine("Work", "Deck"));
  private static CloudFolderOwner Owner(CloudFolderFixture f, string mac, string device, IReadOnlyDictionary<string, string>? roots = null, CloudFileKind? kind = null)
  {
    Directory.CreateDirectory(Project(f, mac));
    var clock = f.Clock;
    var owner = new CloudFolderOwner(device, Path.Combine(f.Base, mac, "data", "root"), Path.Combine(f.Base, mac, "data", "project-folders"), f.Keeper(mac),
      () => true, kind ?? CloudFileKind.ProjectFolders, freeDisk: () => 500_000_000_000, now: () => clock.Ms,
      roots: new CloudFolderRoots(roots ?? new Dictionary<string, string> { [Key] = Project(f, mac) }));
    owner.SetDeleteRuleAnnounced(_ => false);
    owner.MarkCloudRead();
    return owner;
  }
  private static void Write(CloudFolderFixture f, string mac, string path, byte[] bytes)
  {
    var full = CloudFolderDisk.Full(Project(f, mac), path);
    Directory.CreateDirectory(Path.GetDirectoryName(full)!);
    File.WriteAllBytes(full, bytes);
    File.SetLastWriteTimeUtc(full, DateTime.UnixEpoch.AddMilliseconds(f.Clock.Ms));
  }
  private static byte[] Text(string text) => Encoding.UTF8.GetBytes(text);
  private static byte[]? Data(CloudFolderFixture f, string mac, string path) =>
    File.Exists(CloudFolderDisk.Full(Project(f, mac), path)) ? File.ReadAllBytes(CloudFolderDisk.Full(Project(f, mac), path)) : null;

  [Fact]
  public void The_rules_take_every_folder_and_keep_out_only_rebuilt_things()
  {
    using var f = new CloudFolderFixture();
    var project = Project(f, "a");
    foreach (var folder in new[] { "team", "notes", "logs", "backups", "code", "installers", "node_modules", ".claude" }) Directory.CreateDirectory(Path.Combine(project, folder));
    // A folder that is a code checkout (it holds .git) never travels.
    Directory.CreateDirectory(Path.Combine(project, "vendor", ".git"));
    File.WriteAllText(Path.Combine(project, "loose.md"), "a file at the top is not a folder\n");
    Assert.Equal(["backups", "logs", "notes", "team"], CloudProjectFoldersRules.Folders(project));
    // The override file names the folders (comments, the never list, hidden and outside names are ignored).
    Directory.CreateDirectory(Path.Combine(project, ".terminaldeck"));
    File.WriteAllText(Path.Combine(project, ".terminaldeck", "travel-folders"), "# what travels\nteam\r\ncode\n../x\n.claude\nmissing\n");
    Assert.Equal(["team"], CloudProjectFoldersRules.Folders(project));

    Assert.Equal(Key, CloudProjectFoldersRules.Key(ProjectId));
    Assert.NotEqual(Key, CloudProjectFoldersRules.Key("project-2"));
    // Every kind of file travels, secret-looking names and hidden files included.
    foreach (var path in new[] { "team/cloud/card.md", "notes/shot.png", "notes/clip.mov", "notes/app.zip", "notes/.env", "notes/x/id_rsa", "logs/.hidden/run.log" })
      Assert.True(CloudProjectFoldersRules.Refusal(Key + "/" + path) is null, path);
    Assert.Equal(CloudFolderSkip.Rebuildable, CloudProjectFoldersRules.Refusal(Key + "/notes/app/node_modules/p/a.md"));
    Assert.Equal(CloudFolderSkip.Rebuildable, CloudProjectFoldersRules.Refusal(Key + "/notes/src/.git/config"));
    Assert.Equal(CloudFolderSkip.Temporary, CloudProjectFoldersRules.Refusal(Key + "/notes/.DS_Store"));
    Assert.Equal(CloudFolderSkip.Temporary, CloudProjectFoldersRules.Refusal(Key + "/notes/._shot.png"));
    Assert.Equal(CloudFolderSkip.Temporary, CloudProjectFoldersRules.Refusal(Key + "/notes/Thumbs.db"));
    Assert.Equal(CloudFolderSkip.Hidden, CloudProjectFoldersRules.Refusal(Key + "/.claude/settings.json"));
    Assert.Equal(CloudFolderSkip.Name, CloudProjectFoldersRules.Refusal("notes/card.md"));
    Assert.Equal(CloudFolderSkip.Name, CloudProjectFoldersRules.Refusal(Key + "/card.md"));
    Assert.Equal("project-folders", CloudFileKind.ProjectFolders.Domain);

    // Only projects whose folder is inside the user's folder, never the user's folder itself.
    var home = Path.Combine(f.Base, "a", "home");
    var roots = CloudProjectFoldersRules.Roots(new Dictionary<string, string> { [ProjectId] = project, ["home"] = home, ["outside"] = f.Base, ["gone"] = Path.Combine(home, "gone") }, home);
    Assert.Equal(new Dictionary<string, string> { [Key] = project }, roots);
  }

  [Fact]
  public async Task Every_folder_of_a_project_arrives_in_that_projects_folder_on_the_other_device()
  {
    using var f = new CloudFolderFixture();
    var picture = new byte[] { 0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 1, 2, 3 };
    var large = Enumerable.Range(0, 200_000).Select(i => (byte)(i % 251)).ToArray(); // several parts
    Write(f, "a", "team/cloud/card.md", Text("seat card\n"));
    Write(f, "a", "notes/shot.png", picture);
    Write(f, "a", "logs/run/big.bin", large);
    Write(f, "a", "notes/.env", Text("KEY=secret-value\n"));
    // Left out: built, checked out, scratch.
    Write(f, "a", "code/app/main.cs", Text("code\n"));
    Write(f, "a", "notes/web/node_modules/p/index.js", Text("pkg\n"));
    Write(f, "a", "tools/repo/.git/HEAD", Text("ref\n"));
    Write(f, "a", "tools/repo/readme.md", Text("checkout\n"));
    Write(f, "a", "notes/.DS_Store", [0, 1]);
    Write(f, "a", "notes/Thumbs.db", [0, 1]);
    var a = Owner(f, "a", f.DeviceA); var b = Owner(f, "b", f.DeviceB);
    await f.Settle(a);
    var sent = await f.Send(a, f.DeviceA, b, new CloudFolderCursor());
    Assert.NotEmpty(sent);
    Assert.All(sent, op => Assert.Equal("project-folders", op.Domain));
    await b.LookAsync();
    Assert.Equal(Text("seat card\n"), Data(f, "b", "team/cloud/card.md"));
    Assert.Equal(picture, Data(f, "b", "notes/shot.png"));
    Assert.Equal(large, Data(f, "b", "logs/run/big.bin"));
    Assert.Equal(Text("KEY=secret-value\n"), Data(f, "b", "notes/.env"));
    foreach (var path in new[] { "code/app/main.cs", "notes/web/node_modules/p/index.js", "tools/repo/readme.md", "notes/.DS_Store", "notes/Thumbs.db" })
      Assert.True(Data(f, "b", path) is null, path);
    // No path of either device travels: only the project key and the path inside the project.
    Assert.All(sent, op => Assert.StartsWith("file/projects/" + Key + "/", op.Source.RecordId));
    Assert.All(sent, op => Assert.DoesNotContain("Deck Dev", op.Source.RecordId));
    // Nothing echoes back.
    await f.Settle(b);
    Assert.Empty(CloudFolderFixture.Journal(b));
  }

  [Fact]
  public async Task An_edit_comes_back_and_a_file_of_a_project_not_on_this_device_waits()
  {
    using var f = new CloudFolderFixture();
    Write(f, "a", "notes/plan.md", Text("one\n"));
    var a = Owner(f, "a", f.DeviceA);
    // Device b does not have the project yet.
    var b = Owner(f, "b", f.DeviceB, new Dictionary<string, string>());
    await f.Settle(a);
    CloudFolderCursor toB = new(), toA = new();
    await f.Send(a, f.DeviceA, b, toB);
    await b.LookAsync();
    Assert.Null(Data(f, "b", "notes/plan.md"));
    // The project appears on b: its file is placed at the next look.
    b.SetRoots(new Dictionary<string, string> { [Key] = Project(f, "b") });
    await b.LookAsync();
    Assert.Equal(Text("one\n"), Data(f, "b", "notes/plan.md"));
    // An edit on b travels back to a; a's older file is replaced (and kept as a version).
    f.Clock.Advance(60_000);
    Write(f, "b", "notes/plan.md", Text("two\n"));
    await f.Settle(b);
    await f.Send(b, f.DeviceB, a, toA);
    await a.LookAsync();
    Assert.Equal(Text("two\n"), Data(f, "a", "notes/plan.md"));
  }

  [Fact]
  public async Task A_first_upload_goes_in_steps_and_never_waits_for_a_day_cap()
  {
    using var f = new CloudFolderFixture();
    var kind = CloudFileKind.ProjectFolders;
    Assert.Null(kind.DailySendBytes);
    Assert.False(kind.ObeysRoomFloor);
    Assert.Equal(long.MaxValue, kind.MaximumFileBytes);
    // More than the Cloud folder's 200 MB a day is never asked about: a large first upload only goes in steps.
    var paced = kind with { BytesPerLook = 10 };
    for (var index = 0; index < 5; index++) Write(f, "a", "notes/n" + index + ".md", Text("note " + index + " of five\n"));
    var a = Owner(f, "a", f.DeviceA, kind: paced);
    a.SetRoomLeft(() => 1);
    await f.Settle(a);
    string[] Recorded() => CloudFolderFixture.Journal(a).Select(op => op.Source.RecordId).Distinct().Order(StringComparer.Ordinal).ToArray();
    Assert.Single(Recorded());
    await a.LookAsync(); await a.LookAsync(); await a.LookAsync(); await a.LookAsync();
    Assert.Equal(Enumerable.Range(0, 5).Select(i => "file/projects/" + Key + "/notes/n" + i + ".md"), Recorded());
  }
}
