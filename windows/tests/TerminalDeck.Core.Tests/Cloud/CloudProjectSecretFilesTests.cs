using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// Project secret files (the Mac's ProjectSecretFilesTests + the project cases of SecretsDeleteRuleTests): two "devices"
// of one account (one shared key, each its own holding key), each with its own made-up project folder inside this test's
// own temporary folder. Records go from one store's capture to the other's validate + merge exactly as the saved-passwords
// adapter hands them. No real home, project, password store or network; everything made here is removed at the end.
public sealed class CloudProjectSecretFilesFixture : IDisposable
{
  public readonly string Base = Path.Combine(Path.GetTempPath(), "td-secret-files-" + Guid.NewGuid().ToString("N"));
  public readonly string ProjectId = "p-" + Guid.NewGuid().ToString("N")[..8];
  public readonly byte[] Shared = RandomNumberGenerator.GetBytes(32);
  private readonly Dictionary<string, byte[]> locals = [];
  public CloudProjectSecretFilesGate Gate = CloudProjectSecretFilesGate.Open;
  public bool DeleteOpen = true;
  public long Clock = 1_900_000_000_000;
  public CloudProjectSecretFilesFixture() => Directory.CreateDirectory(Base);
  public void Dispose()
  {
    try { foreach (var junction in Directory.EnumerateDirectories(Base, "*", SearchOption.AllDirectories).Where(d => new DirectoryInfo(d).LinkTarget is not null).ToArray()) Directory.Delete(junction); }
    catch (Exception) { }
    // A scanner may still hold a just-written file for a moment: tried again, so nothing is left behind.
    for (var attempt = 0; attempt < 10 && Directory.Exists(Base); attempt++)
    {
      try { Directory.Delete(Base, true); } catch (Exception) { Thread.Sleep(200); }
    }
  }
  public void Advance(long by = 3_001) => Clock += by;
  /// A project folder as a real one is: never empty (decision 11). A plain file that is not a secret file.
  public void MakeProject(string folder)
  {
    Directory.CreateDirectory(folder);
    File.WriteAllText(Path.Combine(folder, "README.md"), "made-up project\n");
  }
  public string Folder(string mac) => Path.Combine(Base, mac, "Projects", "Shop");
  public CloudSecretsStoreKeys Keys(string mac, byte[]? shared = null)
  {
    if (!locals.TryGetValue(mac, out var local)) locals[mac] = local = RandomNumberGenerator.GetBytes(32);
    return new(1, shared ?? Shared, local);
  }
  public CloudProjectSecretFilesStore Store(string name, Func<IReadOnlyList<CloudProjectSecretFilesProject>> projects, string? home = null, bool keyed = true,
    byte[]? shared = null, CloudDeleteWitnessSlot? witness = null, long wallAhead = 0)
  {
    var store = new CloudProjectSecretFilesStore(Path.Combine(Base, name, "state"), projects, () => name, () => Gate,
      home: home ?? Path.Combine(Base, name, "home"), walkReuse: 0, deleteGate: () => DeleteOpen, deleteStamp: () => Clock,
      deleteDevice: () => name.ToLowerInvariant().Replace(' ', '-'), witness: witness ?? new CloudDeleteWitnessSlot(), now: () => Clock + wallAhead);
    if (keyed) store.UseKeys(Keys(name, shared));
    return store;
  }
  /// One device's store with the project "Shop" in one folder. `folders` false: the project is here with no folder yet.
  public CloudProjectSecretFilesStore Mac(string name, bool folders = true, byte[]? shared = null, string? home = null, CloudDeleteWitnessSlot? witness = null, long wallAhead = 0)
  {
    var folder = Folder(name);
    if (folders) MakeProject(folder);
    var id = ProjectId;
    return Store(name, () => [new(id, "Shop", Directory.Exists(folder) ? [folder] : [])], home, shared: shared, witness: witness, wallAhead: wallAhead);
  }
  public void Write(string mac, string path, string text) => WriteAt(Path.Combine(Folder(mac), path), text);
  public static void WriteAt(string file, string text)
  {
    Directory.CreateDirectory(Path.GetDirectoryName(file)!);
    File.WriteAllText(file, text);
  }
  public string? Read(string mac, string path) => ReadAt(Path.Combine(Folder(mac), path));
  public static string? ReadAt(string file) => File.Exists(file) ? File.ReadAllText(file) : null;
  public static CloudProjectSecretFileValue Value(CloudSecretRecord record) => CloudProjectSecretFileValue.Decode(record);
  public static string[] Paths(IEnumerable<CloudSecretRecord> records) => records.Select(r => Value(r).Path).Order(StringComparer.Ordinal).ToArray();
  /// A record a hostile or buggy device of the SAME account could make: it holds the shared key, so the record name and
  /// the fingerprint are right, and only the path rules (and caps) can refuse it.
  public CloudSecretRecord Forged(string path, string text, string folder = "", string? projectId = null, int mode = 384, string? basis = null, string from = "Mac mini")
  {
    var keys = new CloudSecretsStoreKeys(1, Shared, RandomNumberGenerator.GetBytes(32));
    var project = projectId ?? ProjectId;
    var bytes = Encoding.UTF8.GetBytes(text);
    var id = "file/" + project + "/" + keys.Shared(Encoding.UTF8.GetBytes("id\n" + project + "\n" + folder + "\n" + path));
    return new CloudProjectSecretFileValue(1, project, folder, path, mode, Convert.ToBase64String(bytes), keys.Shared([.. "content\n"u8, .. bytes]), basis, 1_900_000_000_000, from).Record(id);
  }
  /// What the adapter does with an arriving record: validate, then merge, then verify.
  public static async Task<CloudApplyStatus[]> Deliver(IEnumerable<CloudSecretRecord> records, CloudProjectSecretFilesStore store)
  {
    var outcomes = new List<CloudApplyStatus>();
    foreach (var record in records)
    {
      await store.ValidateAsync(record);
      var outcome = await store.MergeAsync(record);
      Assert.True(await store.VerifyAsync(record, outcome));
      outcomes.Add(outcome);
    }
    return outcomes.ToArray();
  }
  public static string[] Temporaries(string folder) =>
    Directory.Exists(folder) ? Directory.GetFiles(folder).Select(Path.GetFileName).Where(n => CloudProjectSecretFilesRules.IsTemporary(n!)).Select(n => n!).ToArray() : [];
  public static IEnumerable<CloudProjectSecretFilesStatus.File> Files(CloudProjectSecretFilesStore store) => store.Status()!.Projects.SelectMany(p => p.Files);
  /// Owner-only on this PC: on Windows a protected list with only the current user (the Mac's 0600).
  public static bool OwnerOnly(string file)
  {
    if (!OperatingSystem.IsWindows()) return (File.GetUnixFileMode(file) & (UnixFileMode.GroupRead | UnixFileMode.OtherRead)) == 0;
    return OwnerOnlyOnWindows(file);
  }
  [System.Runtime.Versioning.SupportedOSPlatform("windows")]
  private static bool OwnerOnlyOnWindows(string file)
  {
    var security = new FileInfo(file).GetAccessControl();
    using var me = WindowsIdentity.GetCurrent();
    var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
    return security.AreAccessRulesProtected && rules.Length > 0 && rules.All(r => r.IdentityReference.Equals(me.User));
  }
  /// A directory junction (no special right needed on Windows); a symbolic link elsewhere.
  public static void Junction(string link, string target)
  {
    Directory.CreateDirectory(Path.GetDirectoryName(link)!);
    if (!OperatingSystem.IsWindows()) { Directory.CreateSymbolicLink(link, target); return; }
    using var p = Process.Start(new ProcessStartInfo("cmd.exe", ["/c", "mklink", "/J", link, target]) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true })!;
    p.WaitForExit();
    Assert.True(Directory.Exists(link));
  }
  public CloudDeleteActor Actor(CloudDeleteBy by = CloudDeleteBy.Person, string? group = null) =>
    new(by, "a", "Mac mini", by == CloudDeleteBy.Ai ? "Night work" : null, by == CloudDeleteBy.Ai ? "Worker" : null, Clock, group ?? Guid.NewGuid().ToString("D"));
  public CloudDeleteItem Item(CloudProjectSecretFilesStore store, string path = ".env") => Assert.IsType<CloudDeleteItem>(store.DeleteItem(ProjectId, "", path));
  public async Task Absent(string mac, CloudProjectSecretFilesStore store, string path = ".env")
  {
    File.Delete(Path.Combine(Folder(mac), path));
    await store.CaptureAsync(); Advance(); await store.CaptureAsync();
  }
}

public sealed class CloudProjectSecretFilesTests
{
  [Fact]
  public async Task Only_project_secret_files_travel_and_arrive_owner_only()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("Mac mini"); var b = f.Mac("PC");
    f.Write("Mac mini", ".env", "TOKEN=one\n");
    f.Write("Mac mini", "apps/web/.env.local", "KEY=two\n");
    f.Write("Mac mini", "README.md", "hello");
    f.Write("Mac mini", "id_ed25519", "-----BEGIN OPENSSH PRIVATE KEY-----");     // a person's key: never
    f.Write("Mac mini", "deploy/.aws/credentials", "[default]");                 // machine credentials: never
    f.Write("Mac mini", "node_modules/pkg/.env", "X=1");                         // package folder: never
    f.Write("Mac mini", "cert.pem", "-----BEGIN CERTIFICATE-----");              // not a private key: never
    f.Write("Mac mini", ".env.production", new string('A', 40_000));             // too large
    var sent = await a.CaptureAsync();
    Assert.Equal([".env", "apps/web/.env.local"], CloudProjectSecretFilesFixture.Paths(sent));
    foreach (var record in sent)
    {
      Assert.Equal("project", record.Domain);
      Assert.DoesNotContain("env", record.RecordId);
      Assert.StartsWith("file/" + f.ProjectId + "/", record.RecordId);
      Assert.Equal(64, record.RecordId.Split('/')[^1].Length);
    }
    Assert.Equal([CloudApplyStatus.Applied, CloudApplyStatus.Applied], await CloudProjectSecretFilesFixture.Deliver(sent, b));
    Assert.Equal("TOKEN=one\n", f.Read("PC", ".env"));
    Assert.Equal("KEY=two\n", f.Read("PC", "apps/web/.env.local"));
    Assert.True(CloudProjectSecretFilesFixture.OwnerOnly(Path.Combine(f.Folder("PC"), ".env")));
    Assert.True(CloudProjectSecretFilesFixture.OwnerOnly(Path.Combine(f.Folder("PC"), "apps", "web", ".env.local")));
    Assert.Empty(CloudProjectSecretFilesFixture.Temporaries(f.Folder("PC")));
    Assert.Empty(CloudProjectSecretFilesFixture.Temporaries(Path.Combine(f.Folder("PC"), "apps", "web")));
    var names = CloudProjectSecretFilesFixture.Files(a).Select(x => x.Path + "|" + x.State).ToArray();
    Assert.Contains(".env.production|" + CloudProjectSecretFilesWords.TooLarge, names);
    Assert.Contains(".env|" + CloudProjectSecretFilesWords.Travels, names);
    Assert.Contains(CloudProjectSecretFilesFixture.Files(b), x => x.Path == ".env" && x.State == CloudProjectSecretFilesWords.Arrived("Mac mini"));
    // The arrived file is not sent back as new: the same record comes out on the other device.
    var echo = await b.CaptureAsync();
    Assert.Equal(sent.Select(r => r.RecordId).Order(), echo.Select(r => r.RecordId).Order());
    Assert.All(echo, r => Assert.True(sent.Single(s => s.RecordId == r.RecordId).Same(r)));
  }

  /// A Mac and a PC open each other's records byte for byte: the record made by the Mac's own code (CryptoKit, Swift
  /// JSONEncoder; script in the lane's result file) lands here, and this PC sends back exactly the same bytes.
  [Fact]
  public async Task A_record_made_on_a_Mac_lands_here_and_goes_back_byte_for_byte()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var root = Enumerable.Repeat((byte)9, 32).ToArray();
    var shared = HKDF.DeriveKey(HashAlgorithmName.SHA256, root, 32, [], Encoding.UTF8.GetBytes("TD-CLOUD-SHARED-ID-1\nproject-files\n1"));
    var folder = f.Folder("PC");
    f.MakeProject(folder);
    var pc = f.Store("PC", () => [new("shop", "Shop", [folder])], shared: shared);
    const string MacId = "file/shop/05e44a01576a04f265c1d471930df5507d4ba8ba36123e0c60a05afeee0090a0";
    var fromMac = new CloudSecretRecord("project-files", MacId, "project", CloudJson.Parse(
      """{"at":1900000000000,"data":"VE9LRU49b25lCg==","folder":"","from":"Mac mini","mark":"07e6fd5f2debb5d898a636003b83b42158ca07375124b5811d4e84fdb6908566","mode":384,"path":".env","projectId":"shop","v":1}"""));
    Assert.Equal([CloudApplyStatus.Applied], await CloudProjectSecretFilesFixture.Deliver([fromMac], pc));
    Assert.Equal("TOKEN=one\n", File.ReadAllText(Path.Combine(folder, ".env")));
    var back = Assert.Single(await pc.CaptureAsync());
    Assert.Equal(fromMac.Canonical(), back.Canonical());
    // A second vector with a folder name, a base and '/' and '+' in the bytes: the name and fingerprint agree too.
    var second = new CloudSecretRecord("project-files", "file/shop/fcf061764b3f789927fb949ea5cea1726dcdda9d8329bc076d36723618754a43", "project", CloudJson.Parse(
      """{"at":1900000000000,"base":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":"S0VZPXR3by94K3kK","folder":"api","from":"Mac mini","mark":"49e49d1fbb0e2f2da71f330ee478cef5d6c934c98ac180dd38980c8ae818d329","mode":384,"path":"apps/web/.env.local","projectId":"shop","v":1}"""));
    await pc.ValidateAsync(second);
    Assert.Equal(CloudCanonical.Encode(second.Payload), CloudCanonical.Encode(CloudProjectSecretFilesFixture.Value(second).ToJson()));
  }

  [Fact]
  public async Task His_different_file_is_never_overwritten_and_a_newer_version_made_on_top_replaces()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("Mac mini"); var b = f.Mac("PC");
    f.Write("Mac mini", ".env", "TOKEN=one\n");
    await CloudProjectSecretFilesFixture.Deliver(await a.CaptureAsync(), b);
    f.Write("Mac mini", ".env", "TOKEN=two\n");
    Assert.Equal([CloudApplyStatus.Applied], await CloudProjectSecretFilesFixture.Deliver(await a.CaptureAsync(), b));
    Assert.Equal("TOKEN=two\n", f.Read("PC", ".env"));
    f.Write("Mac mini", ".env", "TOKEN=three\n");
    f.Write("PC", ".env", "TOKEN=mine\n");
    await b.CaptureAsync();
    Assert.Equal([CloudApplyStatus.KeptBoth], await CloudProjectSecretFilesFixture.Deliver(await a.CaptureAsync(), b));
    Assert.Equal("TOKEN=mine\n", f.Read("PC", ".env"));
    Assert.Contains(CloudProjectSecretFilesFixture.Files(b), x => x.Path == ".env" && x.State == CloudProjectSecretFilesWords.Differs("Mac mini"));
    f.Write("Mac mini", "secrets.json", "{\"a\":1}");
    f.Write("PC", "secrets.json", "{\"b\":2}");
    var second = (await a.CaptureAsync()).Where(r => CloudProjectSecretFilesFixture.Value(r).Path == "secrets.json");
    Assert.Equal([CloudApplyStatus.KeptBoth], await CloudProjectSecretFilesFixture.Deliver(second, b));
    Assert.Equal("{\"b\":2}", f.Read("PC", "secrets.json"));
  }

  [Fact]
  public async Task His_uncaptured_edit_and_a_case_twin_are_kept()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("Mac mini"); var b = f.Mac("PC");
    f.Write("Mac mini", ".env", "TOKEN=one\n");
    await CloudProjectSecretFilesFixture.Deliver(await a.CaptureAsync(), b);
    f.Write("PC", ".env", "TOKEN=mine\n");      // not captured on the PC yet
    f.Write("Mac mini", ".env", "TOKEN=two\n");
    Assert.Equal([CloudApplyStatus.KeptBoth], await CloudProjectSecretFilesFixture.Deliver(await a.CaptureAsync(), b));
    Assert.Equal("TOKEN=mine\n", f.Read("PC", ".env"));
    f.Write("PC", "Secrets.json", "{\"his\":1}");
    Assert.Equal([CloudApplyStatus.KeptBoth], await CloudProjectSecretFilesFixture.Deliver([f.Forged("secrets.json", "{\"x\":1}")], b));
    Assert.Equal("{\"his\":1}", f.Read("PC", "Secrets.json"));
    Assert.Contains("Secrets.json", Directory.GetFiles(f.Folder("PC")).Select(x => Path.GetFileName(x)).ToArray());
  }

  [Fact]
  public async Task Nothing_is_sent_until_every_computer_understands()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("Mac mini");
    f.Write("Mac mini", ".env", "TOKEN=one\n");
    f.Gate = CloudProjectSecretFilesGate.WaitingForDevices;
    Assert.Empty(await a.CaptureAsync());
    Assert.True(a.Status()!.WaitingForDevices);
    Assert.Equal(CloudProjectSecretFilesWords.WaitingDevices, a.Status()!.WaitingWhy);
    f.Gate = CloudProjectSecretFilesGate.CloudMemoryOff;
    Assert.Empty(await a.CaptureAsync());
    Assert.Equal(CloudProjectSecretFilesWords.WaitingMemory, a.Status()!.WaitingWhy);
    f.Gate = CloudProjectSecretFilesGate.Open;
    Assert.Single(await a.CaptureAsync());
  }

  [Fact]
  public async Task An_arrival_without_its_folder_waits_sealed_and_is_placed_when_the_folder_exists()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("Mac mini"); var b = f.Mac("PC", folders: false);
    f.Write("Mac mini", ".env", "TOKEN=one\n");
    Assert.Equal([CloudApplyStatus.AlreadyPresent], await CloudProjectSecretFilesFixture.Deliver(await a.CaptureAsync(), b));
    var state = Path.Combine(f.Base, "PC", "state");
    var files = Directory.GetFiles(state, "*", SearchOption.AllDirectories);
    Assert.NotEmpty(files);
    Assert.All(files, file => Assert.DoesNotContain("TOKEN=one", File.ReadAllText(file)));
    Assert.All(files, file => Assert.DoesNotContain(Convert.ToBase64String("TOKEN=one\n"u8.ToArray()), File.ReadAllText(file)));
    Assert.Contains(CloudProjectSecretFilesFixture.Files(b), x => x.State == CloudProjectSecretFilesWords.WaitingFolder);
    f.MakeProject(f.Folder("PC"));
    await b.CaptureAsync();
    Assert.Equal("TOKEN=one\n", f.Read("PC", ".env"));
    Assert.True(CloudProjectSecretFilesFixture.OwnerOnly(Path.Combine(f.Folder("PC"), ".env")));
  }

  [Fact]
  public async Task Keep_on_this_PC_only_sends_nothing_and_holds_arrivals()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("Mac mini"); var b = f.Mac("PC");
    f.Write("Mac mini", ".env", "TOKEN=one\n");
    f.Write("PC", "other/.env", "B=1\n");
    var sent = await a.CaptureAsync();
    b.SetKeepOnThisPc(true);
    Assert.Empty(await b.CaptureAsync());
    Assert.Equal([CloudApplyStatus.AlreadyPresent], await CloudProjectSecretFilesFixture.Deliver(sent, b));
    Assert.Null(f.Read("PC", ".env"));
    b.SetKeepOnThisPc(false);
    await b.CaptureAsync();
    Assert.Equal("TOKEN=one\n", f.Read("PC", ".env"));
  }

  [Fact]
  public async Task A_record_that_is_not_his_or_climbs_out_is_refused()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("Mac mini"); var b = f.Mac("PC");
    var stranger = f.Mac("Other", shared: RandomNumberGenerator.GetBytes(32));
    f.Write("Other", ".env", "EVIL=1\n");
    var foreign = await stranger.CaptureAsync();
    Assert.Equal("invalid_request", (await Assert.ThrowsAsync<CloudFailure>(() => b.ValidateAsync(foreign[0]))).Code);
    f.Write("Mac mini", ".env", "TOKEN=one\n");
    var good = (await a.CaptureAsync())[0];
    var value = CloudProjectSecretFilesFixture.Value(good);
    foreach (var path in new[] { "../.env", "/etc/.env", ".git/.env", "README.md", "id_rsa", "a\\..\\.env", "C:/x/.env" })
    {
      var forged = (value with { Path = path, Base = null }).Record(good.RecordId);
      Assert.Equal("invalid_request", (await Assert.ThrowsAsync<CloudFailure>(() => b.ValidateAsync(forged))).Code);
    }
    Assert.Equal("made-up project\n", f.Read("PC", "README.md"));
    Assert.Null(f.Read("PC", "id_rsa")); Assert.Null(f.Read("PC", ".git/.env"));
    b.UseKeys(null);
    Assert.Equal("secrets_locked", (await Assert.ThrowsAsync<CloudFailure>(() => b.ValidateAsync(good))).Code);
    Assert.Equal("secrets_locked", (await Assert.ThrowsAsync<CloudFailure>(() => b.CaptureAsync())).Code);
  }

  [Fact]
  public void The_tool_answers_names_and_dates_never_content_or_ids()
  {
    var status = new CloudProjectSecretFilesStatus();
    status.Projects.Add(new("p1", "Shop", [new("", ".env", 10, 1_900_000_000_000, "Mac mini", CloudProjectSecretFilesWords.Travels, true)]));
    var text = CloudProjectSecretFilesTools.Answer(status).GetRawText();
    Assert.Contains("\".env\"", text);
    Assert.Contains("Shop", text);
    Assert.DoesNotContain("p1", text);
    Assert.Equal("cloud.project_secrets", Assert.Single(CloudProjectSecretFilesTools.Specs).Id);
    // The Code page reads which held-back files travel (an arrived one travels too).
    status.Projects[0] = new("p1", "Shop", [new("", ".env", 10, 1, "Mac mini", CloudProjectSecretFilesWords.Arrived("Mac mini"), true)]);
    Assert.True(CloudProjectSecretFilesWords.TravellingFiles(status, "p1").ContainsKey(".env"));
    Assert.True(CloudProjectSecretFilesWords.Travelling(CloudProjectSecretFilesWords.Arrived("Mac mini")));
  }

  /// F8: forged records with the RIGHT name and fingerprint are refused by the path rules themselves.
  [Fact]
  public async Task Forged_records_with_correct_names_are_refused_by_the_path_rules()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var b = f.Mac("PC");
    foreach (var path in new[] { "../.env", "/etc/.env", ".git/hooks/x.env", ".git/.env", "a/.ssh/config.env", "a/.aws/credentials", "id_rsa", "id_ed25519",
      "node_modules/pkg/.env", "README.md", "a/b/c/d/e/f/g/.env", CloudProjectSecretFilesRules.TemporaryName() })
      await Assert.ThrowsAsync<CloudFailure>(() => b.ValidateAsync(f.Forged(path, "X=1\n")));
    Assert.Null(CloudProjectSecretFilesFixture.ReadAt(Path.Combine(f.Base, "PC", "Projects", ".env")));
    await b.ValidateAsync(f.Forged(".env", "X=1\n"));
  }

  /// F1: an arriving file never widens anything. New: owner-only. Replacing his file: his permissions stay.
  [Fact]
  public async Task An_arriving_file_never_widens_permissions()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("Mac mini"); var b = f.Mac("PC");
    f.Write("Mac mini", ".env", "TOKEN=one\n");
    Assert.Equal([CloudApplyStatus.Applied], await CloudProjectSecretFilesFixture.Deliver(await a.CaptureAsync(), b));
    var file = Path.Combine(f.Folder("PC"), ".env");
    Assert.True(CloudProjectSecretFilesFixture.OwnerOnly(file));
    // He opens it up himself (inherits the folder's permissions again): a replacement keeps that.
    if (OperatingSystem.IsWindows())
    {
      var security = new FileInfo(file).GetAccessControl();
      security.SetAccessRuleProtection(isProtected: false, preserveInheritance: false);
      new FileInfo(file).SetAccessControl(security);
    }
    else File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead);
    f.Write("Mac mini", ".env", "TOKEN=two\n");
    Assert.Equal([CloudApplyStatus.Applied], await CloudProjectSecretFilesFixture.Deliver(await a.CaptureAsync(), b));
    Assert.Equal("TOKEN=two\n", f.Read("PC", ".env"));
    Assert.False(CloudProjectSecretFilesFixture.OwnerOnly(file));
    // A sender's 0777 is not believed either.
    Assert.Equal([CloudApplyStatus.Applied], await CloudProjectSecretFilesFixture.Deliver([f.Forged("secrets.json", "{}", mode: 511)], b));
    Assert.True(CloudProjectSecretFilesFixture.OwnerOnly(Path.Combine(f.Folder("PC"), "secrets.json")));
  }

  /// F2: files that run programs never travel and are never created on arrival.
  [Fact]
  public async Task Files_that_run_programs_never_travel_or_arrive()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("Mac mini"); var b = f.Mac("PC");
    f.Write("Mac mini", ".envrc", "export X=1\n");
    f.Write("Mac mini", ".yarnrc.yml", "yarnPath: ./credentials\n");
    f.Write("Mac mini", ".npmrc", "# mine\nregistry=https://registry.example.test/\r\n@shop:registry=https://npm.example.test/\n//npm.example.test/:_authToken=abc\n\nalways-auth=true\n");
    f.Write("Mac mini", "tools/.npmrc", "registry=https://registry.example.test/\nscript-shell=/tmp/run\n");
    f.Write("Mac mini", "ops/.netrc", "machine x login y password z\nmacdef init\n");
    f.Write("Mac mini", "ops/credentials", "[default]\ncredential_process = /tmp/run\n");
    var sent = await a.CaptureAsync();
    Assert.Equal([".npmrc"], CloudProjectSecretFilesFixture.Paths(sent));
    var held = CloudProjectSecretFilesFixture.Files(a).Where(x => x.State == CloudProjectSecretFilesWords.StaysHere).Select(x => x.Path).ToHashSet();
    Assert.True(held.SetEquals([".envrc", ".yarnrc.yml", "tools/.npmrc", "ops/.netrc", "ops/credentials"]));
    CloudSecretRecord[] bad = [f.Forged(".envrc", "export X=1\n"), f.Forged(".yarnrc.yml", "yarnPath: ./x\n"), f.Forged("other/.npmrc", "node-options=--require ./x\n")];
    Assert.Equal([CloudApplyStatus.AlreadyPresent, CloudApplyStatus.AlreadyPresent, CloudApplyStatus.AlreadyPresent, CloudApplyStatus.Applied],
      await CloudProjectSecretFilesFixture.Deliver([.. bad, .. sent], b));
    Assert.Null(f.Read("PC", ".envrc")); Assert.Null(f.Read("PC", ".yarnrc.yml")); Assert.Null(f.Read("PC", "other/.npmrc"));
    Assert.NotNull(f.Read("PC", ".npmrc"));
    Assert.Equal(3, b.Status()!.RefusedArrivals);
    Assert.Equal(3, CloudProjectSecretFilesFixture.Files(b).Count(x => x.State == CloudProjectSecretFilesWords.RefusedPrograms));
    Assert.True(CloudProjectSecretFilesRules.NpmrcTravels("//r.example.test/:_password=x\n//r.example.test/:username=me\n//r.example.test/:email=a@b.test\n; c\n"u8.ToArray()));
    Assert.False(CloudProjectSecretFilesRules.NpmrcTravels("email=a@b.test\n"u8.ToArray()));
    Assert.False(CloudProjectSecretFilesRules.NpmrcTravels("onload-script=./x\n"u8.ToArray()));
    Assert.False(CloudProjectSecretFilesRules.NpmrcTravels("[section]\nregistry=x\n"u8.ToArray()));
    Assert.False(CloudProjectSecretFilesRules.NpmrcTravels("registry\n"u8.ToArray()));
    Assert.False(CloudProjectSecretFilesRules.NpmrcTravels("//r.example.test/:certfile=./x\n"u8.ToArray()));
    foreach (var text in new[] { "default,macdef init\n", "\"macdef\" init\n", "mac\\def init\n" })
      Assert.Equal(CloudProjectSecretFilesRules.Verdict.StaysHere, CloudProjectSecretFilesRules.Judge("ops/.netrc", Encoding.UTF8.GetBytes("machine x login y password z\n" + text)));
  }

  /// F3: the temporary file's name is one the Code page holds back, it never travels, and stale ones are cleared.
  [Fact]
  public async Task The_temporary_file_is_held_back_and_stale_ones_are_cleared()
  {
    var name = CloudProjectSecretFilesRules.TemporaryName();
    Assert.Equal(CodeSecrets.Kind.Credential, CodeSecrets.KindOf(name));
    Assert.Equal(CodeSecrets.Kind.Credential, CodeSecrets.KindOf("apps/web/" + name));
    Assert.Equal(CloudProjectSecretFilesRules.Verdict.Never, CloudProjectSecretFilesRules.Judge(name, null));
    using var f = new CloudProjectSecretFilesFixture();
    f.Clock = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    var a = f.Mac("Mac mini");
    var folder = Path.Combine(f.Folder("Mac mini"), "apps");
    var fresh = Path.Combine(folder, CloudProjectSecretFilesRules.TemporaryName());
    CloudProjectSecretFilesFixture.WriteAt(fresh, "TOKEN=now\n");
    File.SetLastWriteTimeUtc(fresh, DateTime.UtcNow.AddMinutes(-10));
    Assert.Empty(await a.CaptureAsync());
    Assert.True(File.Exists(fresh));
    var his = Path.Combine(folder, ".env.td-cloud-mine.local");
    CloudProjectSecretFilesFixture.WriteAt(his, "TOKEN=his\n");
    Assert.False(CloudProjectSecretFilesRules.IsTemporary(Path.GetFileName(his)));
    CloudProjectSecretFilesDisk.Walk(f.Folder("Mac mini"), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 600_000);
    Assert.False(File.Exists(fresh));
    Assert.True(File.Exists(his));
    f.Write("Mac mini", ".env", "TOKEN=mine\n");
    Assert.Equal("changed", Assert.Throws<CloudProjectSecretFilesDisk.Refused>(() =>
      CloudProjectSecretFilesDisk.Write(f.Folder("Mac mini"), ".env", "TOKEN=new\n"u8.ToArray(), "TOKEN=old\n"u8.ToArray(), 1)).Code);
    Assert.Empty(CloudProjectSecretFilesFixture.Temporaries(f.Folder("Mac mini")));
    Assert.Equal("TOKEN=mine\n", f.Read("Mac mini", ".env"));
  }

  /// F4: every cap holds on arrival (40 files and 512 KB a project) and on the waiting list.
  [Fact]
  public async Task The_caps_hold_on_arrival()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var b = f.Mac("PC");
    var outcomes = await CloudProjectSecretFilesFixture.Deliver(Enumerable.Range(0, 41).Select(i => f.Forged($"s{i}/.env", $"N={i}\n")), b);
    Assert.Equal(40, outcomes.Count(o => o == CloudApplyStatus.Applied));
    Assert.Equal(CloudApplyStatus.AlreadyPresent, outcomes[^1]);
    Assert.Null(f.Read("PC", "s40/.env"));
    Assert.Equal(1, b.Status()!.RefusedArrivals);
    using var g = new CloudProjectSecretFilesFixture();
    var c = g.Mac("PC");
    var big = new string('A', 31 * 1024);
    var placed = await CloudProjectSecretFilesFixture.Deliver(Enumerable.Range(0, 17).Select(i => g.Forged($"b{i}/.env", big)), c);
    Assert.Equal(16, placed.Count(o => o == CloudApplyStatus.Applied));
    Assert.Equal(CloudApplyStatus.AlreadyPresent, placed[^1]);
  }

  [Fact]
  public async Task The_waiting_list_has_a_cap_and_survives_a_restart()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var b = f.Mac("PC", folders: false);
    Assert.All(await CloudProjectSecretFilesFixture.Deliver(Enumerable.Range(0, 41).Select(i => f.Forged($"s{i}/.env", $"N={i}\n")), b),
      o => Assert.Equal(CloudApplyStatus.AlreadyPresent, o));
    Assert.Equal(40, CloudProjectSecretFilesFixture.Files(b).Count(x => x.State == CloudProjectSecretFilesWords.WaitingFolder));
    Assert.Equal(1, b.Status()!.RefusedArrivals);
    var again = f.Mac("PC", folders: false);
    f.MakeProject(f.Folder("PC"));
    await again.CaptureAsync();
    Assert.Equal("N=0\n", f.Read("PC", "s0/.env"));
    Assert.Equal("N=39\n", f.Read("PC", "s39/.env"));
    Assert.Null(f.Read("PC", "s40/.env"));
  }

  /// F5 and R1: two folders of one name are skipped and named; a record for a folder never lands in another folder.
  [Fact]
  public async Task Same_named_folders_are_skipped_and_a_record_never_lands_in_the_wrong_folder()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var two = "p-" + Guid.NewGuid().ToString("N")[..8];
    IReadOnlyList<CloudProjectSecretFilesProject> Layout(string mac)
    {
      var root = Path.Combine(f.Base, mac);
      foreach (var path in new[] { "x/web", "y/web", "api", "blog" }) f.MakeProject(Path.Combine(root, path));
      return [new(f.ProjectId, "Shop", new[] { "x/web", "y/web", "api" }.Select(p => Path.Combine(root, p)).ToArray()), new(two, "Blog", [Path.Combine(root, "blog")])];
    }
    var mine = Layout("Mac mini"); var theirs = Layout("PC");
    var a = f.Store("Mac mini", () => mine); var b = f.Store("PC", () => theirs);
    var here = Path.Combine(f.Base, "Mac mini");
    CloudProjectSecretFilesFixture.WriteAt(Path.Combine(here, "x/web/.env"), "A=1\n");
    CloudProjectSecretFilesFixture.WriteAt(Path.Combine(here, "y/web/.env"), "B=1\n");
    CloudProjectSecretFilesFixture.WriteAt(Path.Combine(here, "api/.env"), "C=1\n");
    CloudProjectSecretFilesFixture.WriteAt(Path.Combine(here, "blog/.env"), "D=1\n");
    var sent = await a.CaptureAsync();
    Assert.Equal(sent.Count, sent.Select(r => r.RecordId).Distinct().Count());
    Assert.Equal(new[] { "api|.env", "|.env" }.Order(), sent.Select(r => CloudProjectSecretFilesFixture.Value(r)).Select(v => v.Folder + "|" + v.Path).Order());
    Assert.Contains(CloudProjectSecretFilesFixture.Files(a), x => x.State == CloudProjectSecretFilesWords.SameName("web"));
    Assert.Equal([CloudApplyStatus.Applied, CloudApplyStatus.Applied], await CloudProjectSecretFilesFixture.Deliver(sent, b));
    var there = Path.Combine(f.Base, "PC");
    Assert.Equal("C=1\n", CloudProjectSecretFilesFixture.ReadAt(Path.Combine(there, "api/.env")));
    Assert.Equal("D=1\n", CloudProjectSecretFilesFixture.ReadAt(Path.Combine(there, "blog/.env")));
    Assert.Equal([CloudApplyStatus.AlreadyPresent], await CloudProjectSecretFilesFixture.Deliver([f.Forged(".env", "W=1\n", folder: "web")], b));
    Assert.Null(CloudProjectSecretFilesFixture.ReadAt(Path.Combine(there, "x/web/.env")));
    Assert.Null(CloudProjectSecretFilesFixture.ReadAt(Path.Combine(there, "y/web/.env")));
    Assert.Contains(CloudProjectSecretFilesFixture.Files(b), x => x.State == CloudProjectSecretFilesWords.WaitingSameName("web"));
    // R1: one folder here, a record naming another folder: waits; the same name in any letter case is placed.
    var c = f.Mac("Laptop");
    Assert.Equal([CloudApplyStatus.AlreadyPresent], await CloudProjectSecretFilesFixture.Deliver([f.Forged(".env", "API=1\n", folder: "api")], c));
    Assert.Null(f.Read("Laptop", ".env"));
    Assert.Equal([CloudApplyStatus.Applied], await CloudProjectSecretFilesFixture.Deliver([f.Forged(".env", "SHOP=1\n", folder: "shop")], c));
    Assert.Equal("SHOP=1\n", f.Read("Laptop", ".env"));
  }

  /// F6: a project registered through a link (here a junction) works; a link BELOW the root is never followed.
  [Fact]
  public async Task A_project_registered_through_a_link_works_and_links_below_it_stay_refused()
  {
    using var f = new CloudProjectSecretFilesFixture();
    string Linked(string mac)
    {
      var real = Path.Combine(f.Base, mac, "code", "Shop"); var link = Path.Combine(f.Base, mac, "Projects", "Shop");
      f.MakeProject(real);
      CloudProjectSecretFilesFixture.Junction(link, real);
      return link;
    }
    var id = f.ProjectId;
    var mine = Linked("Mac mini"); var theirs = Linked("PC");
    var a = f.Store("Mac mini", () => [new(id, "Shop", [mine])]); var b = f.Store("PC", () => [new(id, "Shop", [theirs])]);
    CloudProjectSecretFilesFixture.WriteAt(Path.Combine(f.Base, "Mac mini", "code", "Shop", ".env"), "TOKEN=one\n");
    var outside = Path.Combine(f.Base, "outside");
    CloudProjectSecretFilesFixture.WriteAt(Path.Combine(outside, ".env"), "OUT=1\n");
    CloudProjectSecretFilesFixture.Junction(Path.Combine(f.Base, "Mac mini", "code", "Shop", "linked"), outside);
    var sent = await a.CaptureAsync();
    Assert.Equal([".env"], CloudProjectSecretFilesFixture.Paths(sent));
    Assert.Equal([CloudApplyStatus.Applied], await CloudProjectSecretFilesFixture.Deliver(sent, b));
    Assert.Equal("TOKEN=one\n", CloudProjectSecretFilesFixture.ReadAt(Path.Combine(f.Base, "PC", "code", "Shop", ".env")));
    CloudProjectSecretFilesFixture.Junction(Path.Combine(f.Base, "PC", "code", "Shop", "linked"), outside);
    Assert.Equal([CloudApplyStatus.AlreadyPresent], await CloudProjectSecretFilesFixture.Deliver([f.Forged("linked/.env", "EVIL=1\n")], b));
    Assert.Equal("OUT=1\n", CloudProjectSecretFilesFixture.ReadAt(Path.Combine(outside, ".env")));
    Assert.Equal(new[] { ".env" }, Directory.GetFiles(outside).Select(x => Path.GetFileName(x)).ToArray());
  }

  /// F7: a project whose folder is the home folder, above it, or a whole disk: nothing travels, nothing is written.
  [Fact]
  public async Task A_home_folder_or_a_whole_disk_never_takes_part()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var home = f.Folder("Mac mini");
    Directory.CreateDirectory(Path.Combine(home, "inner"));
    f.Write("Mac mini", ".netrc", "machine x login y password z\n");
    foreach (var asHome in new[] { home, Path.Combine(home, "inner") })
    {
      var a = f.Mac("Mac mini", home: asHome);
      Assert.Empty(await a.CaptureAsync());
      Assert.Contains(CloudProjectSecretFilesFixture.Files(a), x => x.State == CloudProjectSecretFilesWords.WholeFolder);
    }
    // R5: the home folder reached through a link is the same folder.
    var link = Path.Combine(f.Base, "home-link");
    CloudProjectSecretFilesFixture.Junction(link, home);
    Assert.Equal(CloudProjectSecretFilesRules.RootKind.Forbidden, CloudProjectSecretFilesRules.RealRoot(link, home).Kind);
    Assert.Equal(CloudProjectSecretFilesRules.RootKind.Forbidden, CloudProjectSecretFilesRules.RealRoot(home, link).Kind);
    Assert.NotEqual(CloudProjectSecretFilesRules.RootKind.Forbidden, CloudProjectSecretFilesRules.RealRoot(Path.Combine(home, "inner"), link).Kind);
    Assert.Equal(CloudProjectSecretFilesRules.RootKind.Forbidden, CloudProjectSecretFilesRules.RealRoot(Path.GetPathRoot(f.Base)!, home).Kind);
    var id = f.ProjectId;
    var disk = f.Store("Disk", () => [new(id, "Disk", [Path.GetPathRoot(f.Base)!])]);
    Assert.Empty(await disk.CaptureAsync());
    var b = f.Mac("PC", home: f.Folder("PC"));
    Assert.Equal([CloudApplyStatus.AlreadyPresent], await CloudProjectSecretFilesFixture.Deliver([f.Forged(".env", "X=1\n")], b));
    Assert.Null(f.Read("PC", ".env"));
    Assert.Contains(CloudProjectSecretFilesFixture.Files(b), x => x.State == CloudProjectSecretFilesWords.WaitingWholeFolder);
  }
}

/// Review 15 Nov, fault A: a name a Mac can make that Windows cannot hold, or that could leave the folder, is never
/// written anywhere; it waits sealed and the rest of the round still lands; a removal for it removes nothing anywhere.
public sealed class CloudProjectSecretFilesWindowsNamesTests
{
  private static readonly string[] Unholdable = ["d:prod.p12", "c:prod.p12", "x/a:b/.env", "CON/.env", "aux.p12", "lpt1.p12", ".env.", "keys./.env", "deploy /.env", "a/s:x.keystore"];

  [Fact]
  public async Task Names_Windows_cannot_hold_wait_sealed_and_nothing_is_written_outside_the_project()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var b = f.Mac("PC");
    var outside = new[] { Path.GetFullPath("c:prod.p12"), Path.GetFullPath("d:prod.p12"), Path.Combine(Path.GetTempPath(), "prod.p12"), Path.GetFullPath("prod.p12") }
      .Where(p => Path.GetPathRoot(p) is { } r && Directory.Exists(r)).ToArray();
    Assert.All(outside, p => Assert.False(File.Exists(p)));
    var bad = Unholdable.Select(n => f.Forged(n, "MADE_UP=" + n.Length + "\n")).ToArray();
    var outcomes = await CloudProjectSecretFilesFixture.Deliver([.. bad, f.Forged(".env", "GOOD=1\n")], b);
    Assert.All(outcomes[..^1], o => Assert.Equal(CloudApplyStatus.AlreadyPresent, o));
    Assert.Equal(CloudApplyStatus.Applied, outcomes[^1]);
    Assert.Equal("GOOD=1\n", f.Read("PC", ".env"));
    Assert.All(outside, p => Assert.False(File.Exists(p)));
    // Inside the project only README.md and the good file; nothing else anywhere under the test folder.
    var written = Directory.GetFiles(f.Base, "*", SearchOption.AllDirectories).Where(x => !x.Contains(Path.DirectorySeparatorChar + "state" + Path.DirectorySeparatorChar)).Select(x => Path.GetRelativePath(f.Folder("PC"), x)).Order().ToArray();
    Assert.Equal(new[] { ".env", "README.md" }, written);
    Assert.Equal(Unholdable.Length, CloudProjectSecretFilesFixture.Files(b).Count(x => x.State == CloudProjectSecretFilesWords.WaitingName));
    // Each stays sealed: the next round places nothing and keeps them waiting.
    await b.CaptureAsync();
    Assert.Equal(Unholdable.Length, CloudProjectSecretFilesFixture.Files(b).Count(x => x.State == CloudProjectSecretFilesWords.WaitingName));
    Assert.All(outside, p => Assert.False(File.Exists(p)));
    // Paths the Mac refuses too are refused whole at validation (nothing placed, nothing waits).
    foreach (var path in new[] { "..\\x.env", "/abs/.env", "\\\\server\\share\\.env", "a//.env" })
      await Assert.ThrowsAsync<CloudFailure>(() => b.ValidateAsync(f.Forged(path, "X=1\n")));
    // The disk layer refuses them on its own as well.
    foreach (var name in Unholdable)
    {
      Assert.Equal("name", Assert.Throws<CloudProjectSecretFilesDisk.Refused>(() => CloudProjectSecretFilesDisk.Write(f.Folder("PC"), name, "X"u8.ToArray(), null, 1)).Code);
      Assert.Equal("name", CloudProjectSecretFilesDisk.Read(f.Folder("PC"), name).Blocked);
    }
    Assert.All(outside, p => Assert.False(File.Exists(p)));
  }

  [Fact]
  public async Task A_removal_for_such_a_name_removes_nothing_anywhere()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var b = f.Mac("PC");
    // A made-up file at the drive-relative place "c:prod.p12" points to (this test's own working folder).
    var decoy = Path.GetFullPath("c:prod.p12");
    var hadDecoy = File.Exists(decoy);
    if (!hadDecoy) File.WriteAllText(decoy, "MADE_UP=decoy\n");
    try
    {
      Assert.Equal(CloudProjectSecretFilesDisk.Unlinked.Kept, CloudProjectSecretFilesDisk.UnlinkExactly(f.Folder("PC"), "c:prod.p12", "MADE_UP=decoy\n"u8.ToArray()));
      Assert.True(File.Exists(decoy));
      // The same through an arriving removal from another device (the record carried inside the removal).
      var a = f.Store("A", () => []);
      var record = f.Forged("c:prod.p12", "MADE_UP=decoy\n");
      await b.MergeAsync(record);
      Assert.True(File.Exists(decoy));
      var removal = new CloudSecretRemoval(record.SourceId, record.RecordId, record.Domain, Guid.NewGuid().ToString("D"),
        new Dictionary<string, string> { [CloudDeleteTravel.Rule] = "1", [CloudDeleteTravel.Scope] = "everywhere", [CloudDeleteTravel.By] = "person", [CloudDeleteTravel.Group] = Guid.NewGuid().ToString("D") },
        "a", "Mac mini", f.Clock, record, null);
      try { var outcome = await b.MergeRemovalAsync(removal); await b.VerifyRemovalAsync(removal, outcome); } catch (CloudFailure) { }
      // And his own press on this PC: nothing outside is ever removed.
      if (b.DeleteItem(f.ProjectId, "", "c:prod.p12") is { } item)
        try { await b.DeleteItemsAsync([item], CloudDeleteScope.Everywhere, f.Actor()); } catch (CloudFailure) { }
      Assert.True(File.Exists(decoy));
      Assert.Equal("MADE_UP=decoy\n", File.ReadAllText(decoy));
    }
    finally { if (!hadDecoy) File.Delete(decoy); }
  }
}

/// The delete rule for project secret files (the Mac's SecretsDeleteRuleTests, project cases).
public sealed class CloudProjectSecretFilesDeleteRuleTests
{
  private sealed class AiWitness(string group) : ICloudDeleteWitness
  {
    public Task<CloudDeleteWitnessAnswer> WhoAsync(string removedPath, DateTimeOffset lastSeen, DateTimeOffset seenGoneAt) =>
      Task.FromResult(CloudDeleteWitnessAnswer.Ai("Night work", "Worker", lastSeen, group));
  }

  [Fact]
  public async Task Everywhere_keeps_the_bytes_sealed_before_removing_and_put_back_is_owner_only()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("A");
    f.Write("A", ".env", "MADE_UP_TOKEN=one");
    await a.CaptureAsync();
    var item = f.Item(a); var actor = f.Actor(CloudDeleteBy.Ai);
    var group = await a.DeleteItemsAsync([item], CloudDeleteScope.Everywhere, actor);
    Assert.Single(group.Items);
    Assert.Equal("Night work", group.Session);
    Assert.Null(f.Read("A", ".env"));
    Assert.Equal(actor.Group, (await a.BinGroupsAsync()).First().Id);
    Assert.Equal([item], await a.PutBackGroupAsync(group.Id));
    Assert.Equal("MADE_UP_TOKEN=one", f.Read("A", ".env"));
    Assert.True(CloudProjectSecretFilesFixture.OwnerOnly(Path.Combine(f.Folder("A"), ".env")));
    // The sealed Bin holds no plain text of it.
    foreach (var file in Directory.GetFiles(Path.Combine(f.Base, "A", "state"), "*", SearchOption.AllDirectories))
      Assert.DoesNotContain("MADE_UP_TOKEN", File.ReadAllText(file));
  }

  [Fact]
  public async Task A_removal_by_hand_marks_here_and_never_travels_even_with_newer_arrivals()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("A"); var b = f.Mac("B");
    f.Write("A", ".env", "MADE_UP=old");
    var old = Assert.Single(await a.CaptureAsync());
    await b.MergeAsync(old); await f.Absent("B", b);
    Assert.Equal(CloudLocalMark.NotOnThisPc, (await b.NotHereAsync()).First().Mark);
    Assert.Empty(await b.CaptureRemovalsAsync());
    f.Write("A", ".env", "MADE_UP=new");
    await b.MergeAsync(Assert.Single(await a.CaptureAsync()));
    Assert.Null(f.Read("B", ".env"));
    Assert.Single(await b.NotHereAsync());
    Assert.Empty(await b.CaptureAsync());
    // The same version again after his removal: stays removed.
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await b.MergeAsync(old));
    Assert.Null(f.Read("B", ".env"));
  }

  [Fact]
  public async Task An_AI_session_removal_goes_everywhere_with_its_command_group()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var slot = new CloudDeleteWitnessSlot(); var group = Guid.NewGuid().ToString("D");
    Assert.True(slot.InstallOnce(new AiWitness(group)));
    var a = f.Mac("A", witness: slot);
    f.Write("A", ".env", "MADE_UP=gone"); await a.CaptureAsync(); await f.Absent("A", a);
    var removal = Assert.Single(await a.CaptureRemovalsAsync());
    Assert.Equal("everywhere", removal.Fields[CloudDeleteTravel.Scope]);
    Assert.Equal("ai", removal.Fields[CloudDeleteTravel.By]);
    Assert.Equal(group, removal.Fields[CloudDeleteTravel.Group]);
    Assert.Equal("Night work", (await a.BinGroupsAsync()).First().Session);
  }

  [Fact]
  public async Task A_missing_or_empty_project_folder_is_never_a_delete_or_a_mark()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var slot = new CloudDeleteWitnessSlot(); slot.InstallOnce(new AiWitness(Guid.NewGuid().ToString("D")));
    var a = f.Mac("A", witness: slot);
    f.Write("A", ".env", "MADE_UP=kept"); await a.CaptureAsync();
    Directory.Move(f.Folder("A"), f.Folder("A") + ".away");
    await a.CaptureAsync(); f.Advance(); await a.CaptureAsync();
    Assert.Empty(await a.NotHereAsync());
    Assert.Empty(await a.CaptureRemovalsAsync());
    // Decision 11: an EMPTY folder is like a missing one: no marks, nothing placed until it has content.
    using var g = new CloudProjectSecretFilesFixture();
    var c = g.Mac("A"); var d = g.Mac("B");
    g.Write("A", ".env", "MADE_UP=only"); var record = Assert.Single(await c.CaptureAsync());
    foreach (var entry in Directory.GetFileSystemEntries(g.Folder("A"))) File.Delete(entry);
    await c.CaptureAsync(); g.Advance(); await c.CaptureAsync();
    Assert.Empty(await c.NotHereAsync());
    File.Delete(Path.Combine(g.Folder("B"), "README.md"));
    await d.MergeAsync(record);
    Assert.Null(g.Read("B", ".env"));
    File.WriteAllText(Path.Combine(g.Folder("B"), "README.md"), "made-up project\n");
    await d.CaptureAsync();
    Assert.Equal("MADE_UP=only", g.Read("B", ".env"));
  }

  [Fact]
  public async Task Two_looks_avoid_an_editor_delete_and_rewrite_and_the_newest_coming_back_clears_the_mark()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("A");
    f.Write("A", ".env", "MADE_UP=old"); await a.CaptureAsync();
    File.Delete(Path.Combine(f.Folder("A"), ".env")); await a.CaptureAsync();
    f.Write("A", ".env", "MADE_UP=new"); f.Advance(); await a.CaptureAsync();
    Assert.Empty(await a.NotHereAsync());
    Assert.Empty(await a.CaptureRemovalsAsync());
    await f.Absent("A", a);
    Assert.Single(await a.NotHereAsync());
    f.Write("A", ".env", "MADE_UP=new");
    Assert.Empty(await a.CaptureAsync());
    Assert.Empty(await a.NotHereAsync());
  }

  /// J-7: old bytes coming back (a branch switch) are never sent over the newer version; the newest is placed.
  [Fact]
  public async Task Reappearing_old_bytes_place_the_newest_without_sending_the_old_ones()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("A"); var b = f.Mac("B");
    f.Write("A", ".env", "MADE_UP=old"); var old = Assert.Single(await a.CaptureAsync());
    await b.MergeAsync(old); await f.Absent("B", b);
    f.Write("A", ".env", "MADE_UP=new"); var newest = Assert.Single(await a.CaptureAsync()); await b.MergeAsync(newest);
    f.Write("B", ".env", "MADE_UP=old");
    Assert.Empty(await b.CaptureAsync());
    Assert.Equal("MADE_UP=new", f.Read("B", ".env"));
    Assert.Empty(await b.NotHereAsync());
    // His own new bytes are made on top of the Cloud's newest.
    using var g = new CloudProjectSecretFilesFixture();
    var c = g.Mac("A"); var d = g.Mac("B");
    g.Write("A", ".env", "MADE_UP=old"); await d.MergeAsync(Assert.Single(await c.CaptureAsync()));
    await g.Absent("B", d);
    g.Write("A", ".env", "MADE_UP=new"); var head = Assert.Single(await c.CaptureAsync()); await d.MergeAsync(head);
    g.Write("B", ".env", "MADE_UP=own");
    var own = Assert.Single(await d.CaptureAsync());
    Assert.Equal(CloudProjectSecretFilesFixture.Value(head).Mark, CloudProjectSecretFilesFixture.Value(own).Base);
  }

  [Fact]
  public async Task Cloud_scope_keeps_every_file_and_put_in_Cloud_again_uses_this_PCs_bytes()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("A"); var b = f.Mac("B");
    f.Write("A", ".env", "MADE_UP=kept"); await b.MergeAsync(Assert.Single(await a.CaptureAsync()));
    await a.DeleteItemsAsync([f.Item(a)], CloudDeleteScope.Cloud, f.Actor());
    var removal = Assert.Single(await a.CaptureRemovalsAsync());
    Assert.Equal(CloudApplyStatus.Applied, await b.MergeRemovalAsync(removal));
    Assert.NotNull(f.Read("A", ".env")); Assert.NotNull(f.Read("B", ".env"));
    Assert.Empty(await a.CaptureAsync()); Assert.Empty(await b.CaptureAsync());
    f.Write("B", ".env", "MADE_UP=this-PC");
    await b.BringBackAsync([f.Item(b)], CloudBringBackDestination.Cloud);
    Assert.Equal(Convert.ToBase64String("MADE_UP=this-PC"u8.ToArray()), CloudProjectSecretFilesFixture.Value((await b.CaptureAsync())[0]).Data);
  }

  [Fact]
  public async Task An_arriving_removal_removes_only_its_exact_version_and_a_later_edit_wins()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("A"); var b = f.Mac("B");
    f.Write("A", ".env", "MADE_UP=one"); await b.MergeAsync(Assert.Single(await a.CaptureAsync()));
    await a.DeleteItemsAsync([f.Item(a)], CloudDeleteScope.Everywhere, f.Actor(CloudDeleteBy.Ai));
    var removal = Assert.Single(await a.CaptureRemovalsAsync());
    Assert.Equal(CloudApplyStatus.Applied, await b.MergeRemovalAsync(removal));
    Assert.Null(f.Read("B", ".env"));
    Assert.Single(await b.BinGroupsAsync());
    Assert.True(await b.VerifyRemovalAsync(removal, CloudApplyStatus.Applied));
    Assert.Equal(CloudApplyStatus.Applied, await b.MergeRemovalAsync(removal));
    using var g = new CloudProjectSecretFilesFixture();
    var c = g.Mac("A"); var d = g.Mac("B");
    g.Write("A", ".env", "MADE_UP=old"); await d.MergeAsync(Assert.Single(await c.CaptureAsync()));
    await c.DeleteItemsAsync([g.Item(c)], CloudDeleteScope.Everywhere, g.Actor());
    g.Write("B", ".env", "MADE_UP=later");
    Assert.Equal(CloudApplyStatus.KeptBoth, await d.MergeRemovalAsync(Assert.Single(await c.CaptureRemovalsAsync())));
    Assert.Equal("MADE_UP=later", g.Read("B", ".env"));
    Assert.Empty(await d.BinGroupsAsync());
  }

  /// Decision 7: while an older device exists neither scope can be honoured; nothing is removed.
  [Fact]
  public async Task A_closed_gate_refuses_both_scopes()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("A");
    f.Write("A", ".env", "MADE_UP=one"); await a.CaptureAsync(); var item = f.Item(a);
    Assert.True(await a.CanDeleteEverywhereAsync());
    f.DeleteOpen = false;
    Assert.False(await a.CanDeleteEverywhereAsync());
    foreach (var scope in new[] { CloudDeleteScope.Everywhere, CloudDeleteScope.Cloud })
      Assert.Equal(CloudDeleteWords.CloudNeedsUpdatedDevices, (await Assert.ThrowsAsync<CloudProjectSecretFilesWaiting>(() => a.DeleteItemsAsync([item], scope, f.Actor()))).Reason);
    Assert.Equal("MADE_UP=one", f.Read("A", ".env"));
    Assert.Empty(await a.CaptureRemovalsAsync());
    Assert.Empty(await a.BinGroupsAsync());
  }

  [Fact]
  public async Task A_removal_with_its_folder_not_on_this_PC_applies_into_the_Bin()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("A");
    f.Write("A", ".env", "MADE_UP=far"); await a.CaptureAsync();
    await a.DeleteItemsAsync([f.Item(a)], CloudDeleteScope.Everywhere, f.Actor());
    var removal = Assert.Single(await a.CaptureRemovalsAsync());
    var b = f.Store("B", () => []);
    Assert.Equal(CloudApplyStatus.Applied, await b.MergeRemovalAsync(removal));
    Assert.True(await b.VerifyRemovalAsync(removal, CloudApplyStatus.Applied));
    Assert.Single((await b.BinGroupsAsync()).First().Items);
  }

  /// Decision 5: the Bin is no side door: a file that runs programs, or one over the caps, never comes out of it.
  [Fact]
  public async Task A_file_that_runs_programs_or_is_over_the_caps_is_never_written_from_the_Bin()
  {
    foreach (var scope in new[] { CloudDeleteScope.Everywhere, CloudDeleteScope.Cloud })
    {
      using var f = new CloudProjectSecretFilesFixture();
      var a = f.Mac("A"); var b = f.Mac("B");
      f.Write("A", ".npmrc", "registry=https://registry.example.invalid/\n"); await a.CaptureAsync();
      var item = f.Item(a, ".npmrc");
      f.Write("A", ".npmrc", "script-shell=/made/up/shell\n");
      var group = await a.DeleteItemsAsync([item], scope, f.Actor(CloudDeleteBy.Ai));
      Assert.Equal(CloudApplyStatus.Applied, await b.MergeRemovalAsync(Assert.Single(await a.CaptureRemovalsAsync())));
      if (scope == CloudDeleteScope.Everywhere) Assert.Empty(await b.PutBackGroupAsync(group.Id));
      else Assert.Empty(await b.BringBackAsync([(await b.NotHereAsync()).First().Item], CloudBringBackDestination.ThisPc));
      Assert.Null(f.Read("B", ".npmrc"));
      Assert.Single(await b.BinGroupsAsync());
      Assert.Contains(CloudProjectSecretFilesFixture.Files(b), x => x.Path == ".npmrc" && x.State == CloudProjectSecretFilesWords.PutBackPrograms);
    }
    using var g = new CloudProjectSecretFilesFixture();
    var c = g.Mac("A"); var d = g.Mac("B");
    for (var i = 0; i < 40; i++) g.Write("B", $".env.{i}.local", $"MADE_UP={i}");
    Assert.Equal(40, (await d.CaptureAsync()).Count);
    g.Write("A", ".env", "MADE_UP=one-too-many"); await c.CaptureAsync();
    var many = await c.DeleteItemsAsync([g.Item(c)], CloudDeleteScope.Everywhere, g.Actor());
    Assert.Equal(CloudApplyStatus.Applied, await d.MergeRemovalAsync(Assert.Single(await c.CaptureRemovalsAsync())));
    Assert.Empty(await d.PutBackGroupAsync(many.Id));
    Assert.Null(g.Read("B", ".env"));
  }

  /// Decision 8: a damaged Bin is set aside with one line; nothing looks locked.
  [Fact]
  public async Task A_damaged_Bin_is_set_aside_with_one_line_and_nothing_looks_locked()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("A");
    f.Write("A", ".env", "MADE_UP=one"); f.Write("A", ".env.local", "MADE_UP=two"); await a.CaptureAsync();
    await a.DeleteItemsAsync([f.Item(a)], CloudDeleteScope.Everywhere, f.Actor());
    var bin = Path.Combine(f.Base, "A", "state", "sealed-bin");
    foreach (var file in Directory.GetFiles(bin, "*.sealed")) File.WriteAllText(file, "made-up damage");
    var again = f.Mac("A");
    Assert.Single(await again.CaptureAsync());
    Assert.Empty(await again.BinGroupsAsync());
    Assert.Equal(CloudProjectSecretFilesWords.BinDamaged, again.Status()!.BinNotice);
    Assert.Contains(Directory.GetFiles(bin), n => n.Contains(".sealed.unreadable-", StringComparison.Ordinal));
  }

  /// Decision 10: removed here, and he puts the same file back himself: his new version, it syncs.
  [Fact]
  public async Task His_own_put_back_by_hand_syncs_as_his_new_version()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("A");
    f.Write("A", ".env", "MADE_UP=mine"); await a.CaptureAsync();
    var group = await a.DeleteItemsAsync([f.Item(a)], CloudDeleteScope.Everywhere, f.Actor(CloudDeleteBy.Ai));
    f.Write("A", ".env", "MADE_UP=mine");
    var record = Assert.Single(await a.CaptureAsync());
    Assert.Equal("MADE_UP=mine", f.Read("A", ".env"));
    Assert.NotNull(await a.VersionForUploadAsync(record));
    Assert.Equal(group.Id, await a.RepublicationAsync(record.RecordId));
    Assert.Empty(await a.NotHereAsync());
  }

  /// The Bin ages by the service clock only: this PC's own clock set forward deletes nothing early, and a removal applied
  /// late still keeps 30 days here.
  [Fact]
  public async Task The_Bin_ages_by_the_service_clock_only()
  {
    using var f = new CloudProjectSecretFilesFixture();
    var a = f.Mac("A", wallAhead: 2 * CloudBinGroup.RetentionMilliseconds);
    f.Write("A", ".env", "MADE_UP=kept"); await a.CaptureAsync();
    var group = await a.DeleteItemsAsync([f.Item(a)], CloudDeleteScope.Everywhere, f.Actor());
    f.Advance(); await a.CaptureAsync();
    Assert.Equal(group.Id, (await a.BinGroupsAsync()).First().Id);
    using var g = new CloudProjectSecretFilesFixture();
    var c = g.Mac("A"); var d = g.Mac("B");
    g.Write("A", ".env", "MADE_UP=late"); await d.MergeAsync(Assert.Single(await c.CaptureAsync()));
    await c.DeleteItemsAsync([g.Item(c)], CloudDeleteScope.Everywhere, g.Actor());
    var removal = Assert.Single(await c.CaptureRemovalsAsync());
    const long Day = 24L * 60 * 60 * 1000;
    g.Advance(40 * Day);
    Assert.Equal(CloudApplyStatus.Applied, await d.MergeRemovalAsync(removal));
    g.Advance(25 * Day); await d.CaptureAsync();
    Assert.Single(await d.BinGroupsAsync());
    g.Advance(6 * Day); await d.CaptureAsync();
    Assert.Empty(await d.BinGroupsAsync());
  }
}
