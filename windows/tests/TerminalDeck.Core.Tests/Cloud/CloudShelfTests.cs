using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// Lane U1: the shelf, case for case the Mac's CloudShelfTests.swift / CloudShelfFilesTests.swift / the sealed suites of
// CloudSecretsEverywhereTests.swift, plus the REFERENCE cases: cloud-shelf-vectors.json was made on the Mac by
// cloud-shelf-vectors.swift with Apple's own JSONEncoder(.sortedKeys) and CryptoKit, so a pass here means the bytes this
// PC puts are the bytes a Mac puts (row fingerprints, text pieces, sealed values, refs, value ids, the keyed fingerprint
// and AES pieces). All keys in the file are TEST-ONLY constants.
public sealed class CloudShelfTests
{
  private static readonly JsonElement Vectors = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "cloud-shelf-vectors.json"))).RootElement;
  private static JsonElement Sealed => Vectors.GetProperty("sealed");
  private static string S(JsonElement e, string key) => e.GetProperty(key).GetString()!;

  private static CloudShelf.Row RowOf(JsonElement e)
  {
    string? T(string k) => e.TryGetProperty(k, out var v) ? v.GetString() : null;
    long? L(string k) => e.TryGetProperty(k, out var v) ? v.GetInt64() : null;
    return new CloudShelf.Row(T("key")!, T("name")!, L("changedAt")!.Value, T("place"), T("changedBy"), L("sizeBytes"), T("status"),
      e.TryGetProperty("binary", out var b) ? b.GetBoolean() : null, T("textHash"), (int?)L("textBytes"), (int?)L("textPieces"), T("fileHash"), L("fileBytes"), T("fileType"),
      e.GetProperty("grouped").GetBoolean());
  }

  [Fact]
  public void Reference_RowFingerprintIsTheMacs()
  {
    var rows = Vectors.GetProperty("rows").EnumerateArray().Select(RowOf).ToArray();
    var steady = rows.Select(r => r.Grouped ? r with { ChangedAt = 0, SizeBytes = null, Status = null } : r).Select(r => r.Json()).ToList();
    Assert.Equal(S(Vectors, "rowsJson"), Encoding.UTF8.GetString(CloudShelfJson.Encode(steady)));
    Assert.Equal(S(Vectors, "rowsFingerprint"), CloudShelf.Fingerprint(rows));
    // A grouped table (the diary) whose date, size and count moved does not change the view.
    Assert.Equal(S(Vectors, "rowsFingerprintGroupedMoved"), CloudShelf.Fingerprint([.. rows[..^1], rows[^1] with { ChangedAt = 12345, SizeBytes = 999, Status = "59 entries" }]));
    Assert.Equal(S(Vectors, "rowsFingerprint"), S(Vectors, "rowsFingerprintGroupedMoved"));
    Assert.Equal(S(Vectors, "emptyFingerprint"), CloudShelf.Fingerprint([]));
    Assert.Equal(S(Vectors, "emptyJson"), Encoding.UTF8.GetString(CloudShelfJson.Encode(new List<CloudShelfJson.Obj>())));
  }

  [Fact]
  public void Reference_TextFactsAndPieces()
  {
    var big = Vectors.GetProperty("bigText");
    var texts = new Dictionary<string, string>
    {
      ["small"] = "Hello / world\n\"quoted\" é 😀", ["empty"] = "",
      ["overOnePiece"] = string.Concat(Enumerable.Repeat(S(big, "repeat"), big.GetProperty("times").GetInt32())) + S(big, "tail"),
    };
    foreach (var v in Vectors.GetProperty("textFacts").EnumerateArray())
    {
      var text = texts[S(v, "name")];
      var fact = CloudShelf.Fact(text);
      Assert.Equal(S(v, "hash"), fact.Hash);
      Assert.Equal(v.GetProperty("bytes").GetInt32(), fact.Bytes);
      Assert.Equal(v.GetProperty("pieces").GetInt32(), fact.Pieces);
      Assert.Equal(v.GetProperty("pieceBytes").EnumerateArray().Select(e => e.GetInt32()), CloudShelf.Pieces(text).Select(p => Encoding.UTF8.GetByteCount(p)));
      Assert.Equal(text, string.Concat(CloudShelf.Pieces(text)));
    }
  }

  private static CloudShelfSealer Sealer() => CloudShelfSealer.Make(Convert.FromHexString(S(Sealed, "testOnlyRootHex")), S(Sealed, "sub"), Sealed.GetProperty("epoch").GetInt32());
  private static CloudShelfSeal.SavedPassword Password(CloudShelfSealer sealer, string valueId, int valueBytes) =>
    new(sealer.Ref(CloudShelfSeal.Kind.SavedPasswords, S(Sealed, "itemKey")), "Web server", "Server", "10.0.0.5:2222", null, valueId, valueBytes, ["User", "Password"]);
  private static void SamePiece(JsonElement expected, CloudShelfSeal.Piece piece)
  {
    Assert.Equal(S(expected, "nonce"), piece.Nonce);
    Assert.Equal(S(expected, "ciphertext"), piece.Ciphertext);
    Assert.Equal(S(expected, "tag"), piece.Tag);
  }

  [Fact]
  public void Reference_SealedValueRefIdAndPieceAreTheMacs()
  {
    var sealer = Sealer();
    var value = CloudShelfSeal.ValueBytes([new("User", "root/admin", false), new("Password", "p\"w é", true)]);
    Assert.Equal(S(Sealed, "valueJson"), Encoding.UTF8.GetString(value));
    Assert.Equal(S(Sealed, "paddedValueHex"), Convert.ToHexStringLower(CloudShelfSeal.Pad(value)));
    Assert.Equal(S(Sealed, "ref"), sealer.Ref(CloudShelfSeal.Kind.SavedPasswords, S(Sealed, "itemKey")));
    var id = sealer.ValueId(CloudShelfSeal.Kind.SavedPasswords, S(Sealed, "itemKey"), value);
    Assert.Equal(S(Sealed, "valueId"), id);
    var piece = sealer.Seal(value, CloudShelfSeal.Kind.SavedPasswords, CloudShelfSeal.Role.Value, id, Convert.FromHexString(S(Sealed, "nonceHex")));
    SamePiece(Sealed.GetProperty("valuePiece"), piece);
    Assert.Equal(value, sealer.Open(piece, CloudShelfSeal.Kind.SavedPasswords, CloudShelfSeal.Role.Value));
    // Another kind, role or generation does not open it.
    Assert.ThrowsAny<CloudFailure>(() => sealer.Open(piece, CloudShelfSeal.Kind.ProjectSecretFiles, CloudShelfSeal.Role.Value));
    Assert.ThrowsAny<CloudFailure>(() => sealer.Open(piece, CloudShelfSeal.Kind.SavedPasswords, CloudShelfSeal.Role.Index));
    var later = CloudShelfSealer.Make(Convert.FromHexString(S(Sealed, "testOnlyRootHex")), S(Sealed, "sub"), 4);
    Assert.ThrowsAny<CloudFailure>(() => later.Open(piece, CloudShelfSeal.Kind.SavedPasswords, CloudShelfSeal.Role.Value));
  }

  [Fact]
  public void Reference_SealedListFingerprintAndIndexAreTheMacs()
  {
    var sealer = Sealer();
    var value = CloudShelfSeal.ValueBytes([new("User", "root/admin", false), new("Password", "p\"w é", true)]);
    var pw = Password(sealer, S(Sealed, "valueId"), value.Length);
    var steady = CloudShelfSealed.Steady([pw], []);
    Assert.Equal(S(Sealed, "steadyJson"), Encoding.UTF8.GetString(steady));
    Assert.Equal(S(Sealed, "fingerprint"), sealer.Fingerprint(steady));
    var index = CloudShelfSeal.IndexBytes(CloudShelfSeal.Kind.SavedPasswords, "33333333-3333-4333-8333-333333333333", 0, 1, 1763200000000, "Office PC", 1, [pw], null);
    Assert.Equal(S(Sealed, "indexJson"), Encoding.UTF8.GetString(index));
    SamePiece(Sealed.GetProperty("indexPiece"), sealer.Seal(index, CloudShelfSeal.Kind.SavedPasswords, CloudShelfSeal.Role.Index, S(Sealed, "indexPieceId"),
      Convert.FromHexString(S(Sealed, "nonceHex"))));

    var bytes = Convert.FromHexString(S(Sealed, "fileBytesHex"));
    var key = S(Sealed, "fileItemKey");
    Assert.Equal(S(Sealed, "fileRef"), sealer.Ref(CloudShelfSeal.Kind.ProjectSecretFiles, key));
    Assert.Equal(S(Sealed, "fileValueId"), sealer.ValueId(CloudShelfSeal.Kind.ProjectSecretFiles, key, bytes));
    var file = new CloudShelfSeal.SecretFile(S(Sealed, "fileRef"), "Garden", ".env", "app/.env", 1763200000001, "Mac mini", bytes.Length, S(Sealed, "fileValueId"));
    var files = CloudShelfSealed.Steady([], [file]);
    Assert.Equal(S(Sealed, "steadyFilesJson"), Encoding.UTF8.GetString(files));
    Assert.Equal(S(Sealed, "filesFingerprint"), sealer.Fingerprint(files));
    foreach (var step in Sealed.GetProperty("steps").EnumerateArray())
      Assert.Equal(step[1].GetInt32(), CloudShelfSeal.Step(step[0].GetInt32()));
    Assert.Null(CloudShelfSeal.Step(262_145));
  }

  private static CloudShelfSealedRecord Record(string source, string id, string domain, string json) => new(source, id, domain, CloudJson.Parse(json));

  /// Tonight's Mac fault: a list whose fingerprint changed on every put. Two seals of the same records: one fingerprint.
  [Fact]
  public void Sealed_SameRecordsSameFingerprintEveryRound()
  {
    var sealer = Sealer();
    var records = new[]
    {
      Record("servers", "a", "server", """{"kind":"password","password":"pw1","server":{"name":"Web","address":"10.0.0.5","port":2222,"username":"root"}}"""),
      Record("api", "b", "api-key", """{"name":"Main","provider":"anthropic","kind":"key","baseURL":"https://api.example","key":"k-1","model":"m"}"""),
      Record("tasks", "c", "task-connection", """{"token":"t-1","name":"Board"}"""),
      Record("project-files", "d", "project", """{"v":1,"projectId":"p1","folder":"","path":"app/.env","mode":384,"data":"QVBJPTEK","mark":"x","at":5,"from":"Mac mini"}"""),
    };
    var items = CloudShelfSealed.Items(records, new Dictionary<string, string> { ["p1"] = "Garden" });
    Assert.Equal(3, items[CloudShelfSeal.Kind.SavedPasswords].Count);
    Assert.Single(items[CloudShelfSeal.Kind.ProjectSecretFiles]);
    Assert.Equal("Garden", items[CloudShelfSeal.Kind.ProjectSecretFiles][0].File!.Project);
    var one = CloudShelfSealed.Seal(CloudShelfSeal.Kind.SavedPasswords, items[CloudShelfSeal.Kind.SavedPasswords], sealer, Guid.NewGuid().ToString("D"), 1, "PC");
    var again = CloudShelfSealed.Seal(CloudShelfSeal.Kind.SavedPasswords, CloudShelfSealed.Items(records, new Dictionary<string, string>())[CloudShelfSeal.Kind.SavedPasswords],
      sealer, Guid.NewGuid().ToString("D"), 2, "PC");
    Assert.Equal(one.Fingerprint, again.Fingerprint);
    Assert.Equal(one.Values.Select(v => v.PieceId), again.Values.Select(v => v.PieceId));
    Assert.Equal(["api", "servers", "tasks"], one.Sources);
    var server = CloudShelfSealed.Password(records[0])!;
    Assert.Equal("Web", server.Name);
    Assert.Equal("10.0.0.5:2222", server.Place);
    Assert.Equal(["User", "Address", "Password"], server.Fields.Select(f => f.Label));
    // A record without a secret is not a saved password.
    Assert.Null(CloudShelfSealed.Password(Record("servers", "e", "server", """{"kind":"password","server":{"name":"x","address":"h","port":22,"username":"u"}}""")));
  }

  // ---- The putter against a fake shelf service ----

  private sealed class FakeShelf
  {
    public readonly List<(string Method, string Path, string Body)> Calls = [];
    public Func<string, string, (int, string)?>? Answer;
    public bool KeepsFiles;
    public Task<CloudChatsAnswer> Send(string method, string path, byte[] body)
    {
      var text = Encoding.UTF8.GetString(body);
      Calls.Add((method, path, text));
      if (Answer?.Invoke(path, text) is { } given) return Task.FromResult(new CloudChatsAnswer(given.Item1, Encoding.UTF8.GetBytes(given.Item2)));
      return Task.FromResult(path switch
      {
        "/shelf" => Ok(KeepsFiles ? """{"on":true,"kinds":[],"limits":{"fileKinds":["cloudFolder","artifacts"]}}""" : """{"on":true,"kinds":[]}"""),
        "/shelf/list" => Ok("""{"accepted":true,"count":1,"asOf":77,"needTexts":[]}"""),
        "/shelf/sealed/missing" => Ok("""{"missing":""" + JsonSerializer.Serialize(JsonDocument.Parse(body).RootElement.GetProperty("pieceIds")) + "}"),
        "/shelf/sealed/index" => Ok("""{"accepted":true,"asOf":5}"""),
        _ => Ok("{}"),
      });
    }
    private static CloudChatsAnswer Ok(string json) => new(200, Encoding.UTF8.GetBytes(json));
  }

  private static CloudShelf.Row Row(string key, string name = "Note") => new(key, name, 5);

  [Fact]
  public async Task Putter_PutsOnceThenUnchanged_TextsAsAsked_BehindAndMissing()
  {
    var fake = new FakeShelf();
    var putter = new CloudShelfPutter(fake.Send, null);
    var text = "Hello";
    var hash = CloudShelf.Fact(text).Hash;
    fake.Answer = (path, body) => path == "/shelf/list" ? (200, "{\"accepted\":true,\"count\":1,\"asOf\":77,\"needTexts\":[\"" + hash + "\"]}") : null;
    var rows = new[] { Row("memory||a.md") with { TextHash = hash, TextBytes = 5, TextPieces = 1 } };
    var put = await putter.PutAsync(CloudContentsKind.Memory, rows, "12", "Office PC", h => Task.FromResult<string?>(h == hash ? text : null));
    Assert.Equal(CloudShelfPutter.Outcome.Put, put.Outcome);
    Assert.Equal(1, put.Texts);
    var list = fake.Calls.Single(c => c.Path == "/shelf/list");
    Assert.Contains("\"throughSeq\":\"12\"", list.Body);
    Assert.Contains("\"key\":\"memory||a.md\"", list.Body);
    Assert.Contains("\"text\":\"Hello\"", fake.Calls.Single(c => c.Path == "/shelf/texts").Body);
    Assert.Equal(77, putter.Current.AsOf);
    Assert.Equal(CloudShelfPutter.Outcome.Unchanged, (await putter.PutAsync(CloudContentsKind.Memory, rows, "13", "Office PC", _ => Task.FromResult<string?>(null))).Outcome);
    // Sessions never go on the shelf.
    Assert.Equal(CloudShelfPutter.Outcome.Unchanged, (await putter.PutAsync(CloudContentsKind.Sessions, rows, "13", null, _ => Task.FromResult<string?>(null))).Outcome);

    fake.Answer = (path, _) => path == "/shelf/list" ? (409, """{"error":{"code":"shelf_behind"}}""") : null;
    Assert.Equal(CloudShelfPutter.Outcome.Behind, (await putter.PutAsync(CloudContentsKind.Tasks, [Row("tasks||1")], "1", null, _ => Task.FromResult<string?>(null))).Outcome);
    fake.Answer = (path, _) => path == "/shelf/list" ? (404, """{"error":{"code":"not_found"}}""") : null;
    Assert.Equal(CloudShelfPutter.Outcome.Missing, (await putter.PutAsync(CloudContentsKind.Agents, [Row("agents||1")], "1", null, _ => Task.FromResult<string?>(null))).Outcome);
    Assert.True(putter.Missing);
  }

  [Fact]
  public async Task Putter_StateSurvivesARestart_AndTheSwitchOffEmpties()
  {
    var folder = Path.Combine(AppContext.BaseDirectory, "shelf-tests", Guid.NewGuid().ToString("N"));
    var file = Path.Combine(folder, "shelf.json");
    var fake = new FakeShelf();
    var putter = new CloudShelfPutter(fake.Send, file);
    await putter.PutAsync(CloudContentsKind.Projects, [Row("projects||p")], "3", "PC", _ => Task.FromResult<string?>(null));
    var again = new CloudShelfPutter(fake.Send, file);
    Assert.Equal(CloudShelfPutter.Outcome.Unchanged, (await again.PutAsync(CloudContentsKind.Projects, [Row("projects||p")], "4", "PC", _ => Task.FromResult<string?>(null))).Outcome);
    Assert.True(await again.SetOnAsync(false));
    Assert.Contains(fake.Calls, c => c.Path == "/shelf/setting" && c.Body == "{\"on\":false}");
    Assert.Equal(CloudShelfPutter.Outcome.Off, (await again.PutAsync(CloudContentsKind.Projects, [Row("projects||q")], "5", "PC", _ => Task.FromResult<string?>(null))).Outcome);
    Directory.Delete(folder, true);
  }

  [Fact]
  public void Shelf_SettledWaitsThirtySeconds_StuckRoundStopsBlocking()
  {
    Assert.False(CloudShelf.Settled(null, "a", 100));
    Assert.False(CloudShelf.Settled(("a", 100), "a", 100 + CloudShelf.SettleMs - 1));
    Assert.True(CloudShelf.Settled(("a", 100), "a", 100 + CloudShelf.SettleMs));
    Assert.False(CloudShelf.Settled(("a", 100), "b", 100 + CloudShelf.SettleMs));
    Assert.True(CloudShelf.RoundMayStart(null, 5));
    Assert.False(CloudShelf.RoundMayStart(0, CloudShelf.RoundStuckMs - 1));
    Assert.True(CloudShelf.RoundMayStart(0, CloudShelf.RoundStuckMs));
  }

  [Fact]
  public void Shelf_Parts_AtMost500RowsEach_AnEmptyKindIsOnePart()
  {
    Assert.Single(CloudShelf.Parts([]));
    var rows = Enumerable.Range(0, 1201).Select(i => Row("k" + i)).ToArray();
    Assert.Equal([500, 500, 201], CloudShelf.Parts(rows).Select(p => p.Count));
  }

  private sealed class Readable(bool text = true) : ICloudShelfReadable
  {
    public bool IsText(CloudContentsRow row) => text;
    public Task<string?> TextAsync(CloudContentsRow row, CancellationToken cancel) => Task.FromResult<string?>("t");
  }

  [Fact]
  public void Entries_OnlyWhatStandsInTheCloud_SettingSecretsKeepTheirValue()
  {
    var rows = new List<CloudContentsRow>
    {
      new("memory|A|a.md", CloudContentsKind.Memory, "A note", ["A"], 5, null, 10, CloudItemState.InSync),
      new("memory|A|b.md", CloudContentsKind.Memory, "Only here", ["A"], 5, null, 10, CloudItemState.OnlyOnThisPc),
      new("memory|A|c.md", CloudContentsKind.Memory, "Gone here", ["A"], 5, null, 10, CloudItemState.NotOnThisPc),
      new("marked|memory|x", CloudContentsKind.Memory, "Marked", [], 5, null, null, CloudItemState.InSync),
      new("settings||setting:general.copyOnSelect", CloudContentsKind.Settings, "Copy on select", ["General"], 0, null, null, CloudItemState.InSync, "On"),
      new("settings||setting:x.apiKey", CloudContentsKind.Settings, "API key", ["General"], 0, null, null, CloudItemState.InSync, "On"),
      new("settings||setting:x.url", CloudContentsKind.Settings, "Link", ["General"], 0, null, null, CloudItemState.InSync, "Example site"),
      new("cloudFolder||p.png", CloudContentsKind.CloudFolder, "p.png", [], 5, null, 10, CloudItemState.InSync),
      new("sessions|r", CloudContentsKind.Sessions, "Chat", [], 5, null, null, CloudItemState.InSync),
      new("memory|A|0123456789abcdef0123", CloudContentsKind.Memory, "0123456789abcdef0123", [], 5, null, null, CloudItemState.InSync),
    };
    var entries = CloudShelf.Entries(rows, k => k == CloudContentsKind.CloudFolder ? new Readable(false) : new Readable());
    Assert.Equal(["memory|A|a.md"], entries[CloudContentsKind.Memory].Select(e => e.Row.Key));
    Assert.Equal("A", entries[CloudContentsKind.Memory][0].Row.Place);
    Assert.True(entries[CloudContentsKind.Memory][0].Readable);
    var settings = entries[CloudContentsKind.Settings].ToDictionary(e => e.Row.Name, e => e.Row);
    Assert.Equal("On", settings["Copy on select"].Status);
    Assert.Null(settings["API key"].Status);
    Assert.Null(settings["Link"].Status);
    Assert.Equal("General", settings["Copy on select"].Place);
    Assert.True(entries[CloudContentsKind.CloudFolder][0].Row.Binary);
    Assert.True(entries[CloudContentsKind.CloudFolder][0].MayBeFile);
    Assert.False(entries.ContainsKey(CloudContentsKind.Sessions));
  }

  [Fact]
  public void Words_SecretsAndValues()
  {
    Assert.True(CloudShelfWords.HoldsSecret("setting:x.apiKey API key"));
    Assert.True(CloudShelfWords.HoldsSecret("auth_token"));
    Assert.False(CloudShelfWords.HoldsSecret("Keyboard layout"));
    Assert.Equal("14", CloudShelfWords.ShelfValue("14"));
    Assert.Equal("Dark", CloudShelfWords.ShelfValue("Dark"));
    Assert.Null(CloudShelfWords.ShelfValue("https://example.com"));
    Assert.Equal("On", CloudShelfWords.SettingValue(CloudJson.From(true)));
    Assert.Equal("Claude", CloudShelfWords.SettingValue(CloudJson.From("claude")));
    Assert.Null(CloudShelfWords.Plain("3f2a1b4c-0000-4000-8000-1234567890ab"));
    Assert.Equal("App domain retired", CloudShelfWords.FileWords("2026-11-02-app-domain-retired-dtvjwi"));
  }

  // ---- Files ----

  [Fact]
  public void Files_PiecesAskAndFacts()
  {
    Assert.Equal(1, CloudShelfFiles.FilePieces(0));
    Assert.Equal(2, CloudShelfFiles.FilePieces(CloudShelfFiles.FilePieceBytes + 1));
    var data = new byte[CloudShelfFiles.FilePieceBytes + 3];
    Assert.Equal(3, CloudShelfFiles.FilePiece(data, 1)!.Length);
    Assert.Null(CloudShelfFiles.FilePiece(data, 2));
    var known = new CloudShelfPutter.KindState();
    var hash = new string('a', 64);
    CloudShelfFiles.Ask(known, CloudContentsKind.CloudFolder, [new(hash, [1, 0, 1, 99]), new(hash, [0]), new("bad", [0])], 5);
    Assert.Single(known.FilesOwed!);
    Assert.Equal([0, 1], known.FilesOwed![0].Pieces);
    Assert.Equal(1, known.FilesAsked);
    CloudShelfFiles.Ask(known, CloudContentsKind.Memory, [], 6);
    Assert.NotNull(known.FilesOwed);

    var folder = Path.Combine(AppContext.BaseDirectory, "shelf-files", Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(folder);
    File.WriteAllBytes(Path.Combine(folder, "p.png"), [1, 2, 3]);
    File.WriteAllText(Path.Combine(folder, "n.txt"), "hello");
    File.WriteAllText(Path.Combine(folder, "s.json"), "{\"api_key\": \"sk-ant-api03-" + new string('x', 90) + "\"}");
    var found = CloudShelfFiles.FileFacts([new("1", CloudContentsKind.CloudFolder, folder, "p.png", false), new("2", CloudContentsKind.CloudFolder, folder, "n.txt", true),
      new("3", CloudContentsKind.CloudFolder, folder, "s.json", false)], new Dictionary<string, CloudShelfFiles.FileFact>());
    Assert.Equal("image/png", found.ByItem["1"].Fact.Type);
    Assert.Equal(CloudShelf.Hash([1, 2, 3]), found.ByItem["1"].Fact.Hash);
    Assert.False(found.ByItem.ContainsKey("2"));
    Assert.Null(found.ByItem["3"].Fact.Hash);
    Assert.Equal([1, 2, 3], CloudShelfFiles.FileBytes(folder, "p.png", CloudShelf.Hash([1, 2, 3])));
    Assert.Null(CloudShelfFiles.FileBytes(folder, "p.png", new string('0', 64)));
    var row = CloudShelfFiles.WithFile(Row("cloudFolder||p.png"), found.ByItem["1"].Fact);
    Assert.Equal(3, row.FileBytes);
    Assert.Null(CloudShelfFiles.WithFile(Row("x"), found.ByItem["3"].Fact).FileHash);
    Assert.Equal("hello", CloudShelf.FileText(folder, "n.txt"));
    Assert.Null(CloudShelf.FileText(folder, "s.json"));
    Directory.Delete(folder, true);
  }

  [Fact]
  public async Task Files_SentOnlyWhereTheServiceKeepsFiles_PiecesAsAsked()
  {
    var fake = new FakeShelf { KeepsFiles = true };
    var putter = new CloudShelfPutter(fake.Send, null);
    var bytes = new byte[] { 9, 8, 7 };
    var hash = CloudShelf.Hash(bytes);
    Assert.False(putter.FilesLive(CloudContentsKind.CloudFolder));
    await putter.StatusAsync();
    Assert.True(putter.FilesLive(CloudContentsKind.CloudFolder));
    fake.Answer = (path, _) => path switch
    {
      "/shelf/list" => (200, "{\"accepted\":true,\"count\":1,\"needTexts\":[],\"needFiles\":[{\"hash\":\"" + hash + "\",\"pieces\":[0]}]}"),
      "/shelf?kind=cloudFolder" => (200, "{\"on\":true,\"needFiles\":[{\"hash\":\"" + hash + "\",\"pieces\":[0]}]}"),
      "/shelf/files" => (200, """{"stored":true,"complete":true}"""),
      _ => null,
    };
    await putter.PutAsync(CloudContentsKind.CloudFolder, [Row("cloudFolder||p.png") with { FileHash = hash, FileBytes = 3, FileType = "image/png" }], "1", null, _ => Task.FromResult<string?>(null));
    Assert.Equal((0, 1), putter.FilesProgress());
    long spent = 0;
    var sent = await putter.SendFilesAsync(5, _ => true, b => spent += b, (_, h) => Task.FromResult<byte[]?>(h == hash ? bytes : null));
    Assert.Equal(1, sent);
    Assert.Equal(3, spent);
    Assert.Contains(fake.Calls, c => c.Path == "/shelf/files" && c.Body.Contains(Convert.ToBase64String(bytes)));
    Assert.Null(putter.FilesProgress());
  }

  // ---- The sealed round: one failing source never holds the round, and every round says one plain line ----

  private sealed class Material(Func<CloudShelfSealedMaterial> make) : ICloudShelfSealedSource
  {
    public Task<CloudShelfSealedMaterial> MaterialAsync(CancellationToken cancel) => Task.FromResult(make());
  }

  [Fact]
  public async Task SealedRound_AFailingSourceDoesNotHoldTheList_AndIsLogged()
  {
    var fake = new FakeShelf();
    var sealedPutter = new CloudShelfSealedPutter(new CloudShelfPutter(fake.Send, null), null);
    var notes = new List<string>();
    long now = 1_000_000;
    var records = new[] { Record("api", "b", "api-key", """{"name":"Main","provider":"x","kind":"key","baseURL":"https://api.example","key":"k-1"}""") };
    var round = new CloudShelfSealedRound(sealedPutter, new Material(() => new CloudShelfSealedMaterial.Ready(Sealer(), records, new Dictionary<string, string>(),
      new Dictionary<string, string> { ["servers"] = "could not be read" })), notes.Add, () => now);
    Assert.True(await round.RunAsync("1", "Office PC", atLaunch: true, "s"));
    Assert.Contains(fake.Calls, c => c.Path == "/shelf/sealed/index");
    Assert.Single(notes);
    Assert.Contains("saved passwords: put 1", notes[0]);
    Assert.Contains("not read this round: servers (could not be read)", notes[0]);
    Assert.DoesNotContain("Main", notes[0]);
    Assert.DoesNotContain("k-1", notes[0]);
    // The failure brings a 30 s retry; an unchanged list is not put again.
    Assert.False(round.RetryDue());
    now += CloudShelf.SettleMs;
    Assert.True(round.RetryDue());
    var before = fake.Calls.Count(c => c.Path == "/shelf/sealed/index");
    await round.RunAsync("1", "Office PC", false, "s");
    Assert.Equal(before, fake.Calls.Count(c => c.Path == "/shelf/sealed/index"));
  }

  [Fact]
  public async Task SealedRound_LockedSaysSo_KeptOffClearsOnce()
  {
    var fake = new FakeShelf();
    var sealedPutter = new CloudShelfSealedPutter(new CloudShelfPutter(fake.Send, null), null);
    var notes = new List<string>();
    CloudShelfSealedMaterial material = new CloudShelfSealedMaterial.NotNow();
    var round = new CloudShelfSealedRound(sealedPutter, new Material(() => material), notes.Add, () => 5);
    await round.RunAsync("1", null, true, "a");
    Assert.Contains("not now", notes.Single());
    Assert.DoesNotContain(fake.Calls, c => c.Path.StartsWith("/shelf/sealed", StringComparison.Ordinal));
    material = new CloudShelfSealedMaterial.KeptOff();
    await round.RunAsync("1", null, true, "b");
    Assert.Equal(2, fake.Calls.Count(c => c.Path == "/shelf/sealed/clear"));
    await round.RunAsync("1", null, true, "c");
    Assert.Equal(2, fake.Calls.Count(c => c.Path == "/shelf/sealed/clear"));
  }

  [Fact]
  public void Client_OnlyShelfRoutes()
  {
    Assert.True(CloudShelfClient.IsShelfPath("/shelf/list"));
    Assert.True(CloudShelfClient.IsShelfPath("/shelf?kind=memory"));
    Assert.False(CloudShelfClient.IsShelfPath("/shelf/list?x=1"));
    Assert.False(CloudShelfClient.IsShelfPath("/chats/tick"));
    Assert.False(CloudShelfClient.IsShelfPath("/shelf/../user"));
  }
}
