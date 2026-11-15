using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// Lane U1 (15 Nov), the Mac's CloudSecretsShelfSeal.swift + BackendCloudShelfSealed.swift: the SEALED part of the
// shelf. Saved passwords (saved MCP server sign-ins included) and project secret files go on the service's shelf so his
// phones show them with every computer off, sealed HERE with a key derived from the saved-passwords key, which the
// service never holds. Byte-compatible with the Mac (reference cases in cloud-shelf-vectors.json):
// - shelf root = HKDF-SHA256(ikm: saved-passwords key, salt: empty, info: "TD-SHELF-SEALED-1\nroot\n<sub>\n<epoch>")
// - piece key  = HKDF-SHA256(ikm: shelf root, salt: the piece id's 16 UUID bytes, info: "TD-SHELF-SEALED-1\n<kind>\n<role>\n<epoch>")
// - AAD        = "TD-SHELF-SEALED-1\n<sub>\n<kind>\n<role>\n<epoch>\n<pieceId>"
// - plaintext  = 4-byte big-endian length, the bytes, zeros up to the next size step (256 B doubling, at most 256 KiB)
// - AES-256-GCM, 12-byte random nonce; nonce, ciphertext and tag base64url without padding.
// Every JSON inside (values, index, the steady list behind the fingerprint) is written with SORTED keys: tonight's Mac
// fault was a value whose key order changed on every encoding, so the fingerprint moved and the list went up every 30 s.
//
// Which items go on it is exactly what his devices sync (the saved-passwords lane hands the records through
// `ICloudShelfSealedSource`); until that lane is joined there is no source and nothing is sealed or put.
public static class CloudShelfSeal
{
  public const string Label = "TD-SHELF-SEALED-1", Suite = "A256GCM-HKDF-SHA256";
  public const int MaximumPlainBytes = 262_144, IndexPartBytes = 200_000;
  public enum Kind { SavedPasswords, ProjectSecretFiles }
  public enum Role { Index, Value }
  public static string Raw(Kind kind) => kind == Kind.SavedPasswords ? "savedPasswords" : "projectSecretFiles";
  public static string Raw(Role role) => role == Role.Index ? "index" : "value";
  public static readonly IReadOnlyList<Kind> Kinds = [Kind.SavedPasswords, Kind.ProjectSecretFiles];

  public sealed record Piece(int V, string Suite, string Kind, string Role, int Epoch, string PieceId, string Nonce, string Ciphertext, string Tag)
  {
    public CloudShelfJson.Obj Json() => new CloudShelfJson.Obj().Add("v", V).Add("suite", Suite).Add("kind", Kind).Add("role", Role).Add("epoch", Epoch)
      .Add("pieceId", PieceId).Add("nonce", Nonce).Add("ciphertext", Ciphertext).Add("tag", Tag);
  }
  public sealed record SavedPassword(string Ref, string Name, string Purpose, string? Place, long? ChangedAt, string Value, int ValueBytes, IReadOnlyList<string> Labels)
  {
    public CloudShelfJson.Obj Json() => new CloudShelfJson.Obj().Add("ref", Ref).Add("name", Name).Add("for", Purpose).Add("place", Place).Add("changedAt", ChangedAt)
      .Add("value", Value).Add("valueBytes", ValueBytes).Add("labels", Labels.ToList());
  }
  public sealed record SecretFile(string Ref, string Project, string File, string Place, long? ChangedAt, string? ChangedBy, int SizeBytes, string Value)
  {
    public CloudShelfJson.Obj Json() => new CloudShelfJson.Obj().Add("ref", Ref).Add("project", Project).Add("file", File).Add("place", Place)
      .Add("changedAt", ChangedAt).Add("changedBy", ChangedBy).Add("sizeBytes", SizeBytes).Add("value", Value);
  }
  public sealed record Field(string Label, string Value, bool Secret)
  {
    public CloudShelfJson.Obj Json() => new CloudShelfJson.Obj().Add("label", Label).Add("value", Value).Add("secret", Secret);
  }
  /// A saved password's value piece, inside the seal: `{"fields":[…],"v":1}` with sorted keys.
  public static byte[] ValueBytes(IReadOnlyList<Field> fields) => CloudShelfJson.Encode(new CloudShelfJson.Obj().Add("v", 1).Add("fields", fields.Select(f => f.Json()).ToList()));
  public static byte[] IndexBytes(Kind kind, string putId, int part, int parts, long madeAt, string madeBy, int count, IReadOnlyList<SavedPassword>? passwords,
    IReadOnlyList<SecretFile>? files) =>
    CloudShelfJson.Encode(new CloudShelfJson.Obj().Add("v", 1).Add("kind", Raw(kind)).Add("putId", putId).Add("part", part).Add("parts", parts).Add("madeAt", madeAt)
      .Add("madeBy", madeBy).Add("count", count).Add("passwords", passwords?.Select(p => p.Json()).ToList()).Add("files", files?.Select(f => f.Json()).ToList()));

  /// The size steps: 256, 512, ... 262,144 bytes; null past the largest.
  public static int? Step(int size)
  {
    var step = 256;
    while (step < size) step *= 2;
    return step <= MaximumPlainBytes ? step : null;
  }
  public static byte[] Pad(byte[] bytes)
  {
    var total = Step(bytes.Length + 4) ?? throw new CloudFailure("invalid_request");
    var made = new byte[total];
    var count = (uint)bytes.Length;
    made[0] = (byte)(count >> 24); made[1] = (byte)(count >> 16); made[2] = (byte)(count >> 8); made[3] = (byte)count;
    bytes.CopyTo(made, 4);
    return made;
  }
  public static byte[] Unpad(byte[] padded)
  {
    if (padded.Length < 4 || Step(padded.Length) != padded.Length) throw new CloudFailure("unsupported_format");
    var count = padded[0] << 24 | padded[1] << 16 | padded[2] << 8 | padded[3];
    if (count < 0 || count > padded.Length - 4 || padded.Skip(4 + count).Any(b => b != 0)) throw new CloudFailure("unsupported_format");
    return padded[4..(4 + count)];
  }
  internal static byte[] Aad(string sub, Kind kind, Role role, int epoch, string pieceId) =>
    Encoding.UTF8.GetBytes(Label + "\n" + sub + "\n" + Raw(kind) + "\n" + Raw(role) + "\n" + epoch.ToString(CultureInfo.InvariantCulture) + "\n" + pieceId);
}

/// The shelf's sealer for one account and one key generation. Holds only the derived shelf root, never the key itself.
public sealed class CloudShelfSealer
{
  public string Sub { get; }
  public int Epoch { get; }
  private readonly byte[] shelfRoot;
  private readonly byte[] refKey;

  private CloudShelfSealer(byte[] root, string sub, int epoch)
  {
    if (root.Length != 32 || epoch <= 0) throw new CloudFailure("invalid_request");
    CloudBytes.Uuid(sub);
    Sub = sub; Epoch = epoch;
    shelfRoot = Derive(root, [], CloudShelfSeal.Label + "\nroot\n" + sub + "\n" + epoch.ToString(CultureInfo.InvariantCulture));
    refKey = Derive(shelfRoot, [], CloudShelfSeal.Label + "\nref");
  }
  /// The sealer from the saved-passwords key of `epoch` (the saved-passwords lane calls this; tests use a known key).
  public static CloudShelfSealer Make(byte[] root, string sub, int epoch) => new(root, sub, epoch);

  private static byte[] Derive(byte[] input, byte[] salt, string info) => HKDF.DeriveKey(HashAlgorithmName.SHA256, input, 32, salt, Encoding.UTF8.GetBytes(info));
  private byte[] PieceKey(CloudShelfSeal.Kind kind, CloudShelfSeal.Role role, string pieceId) =>
    Derive(shelfRoot, CloudBytes.Uuid(pieceId), CloudShelfSeal.Label + "\n" + CloudShelfSeal.Raw(kind) + "\n" + CloudShelfSeal.Raw(role) + "\n" + Epoch.ToString(CultureInfo.InvariantCulture));

  public CloudShelfSeal.Piece Seal(byte[] bytes, CloudShelfSeal.Kind kind, CloudShelfSeal.Role role, string pieceId) =>
    Seal(bytes, kind, role, pieceId, RandomNumberGenerator.GetBytes(12));
  /// With a given nonce: the reference cases only.
  public CloudShelfSeal.Piece Seal(byte[] bytes, CloudShelfSeal.Kind kind, CloudShelfSeal.Role role, string pieceId, byte[] nonce)
  {
    if (nonce.Length != 12 || pieceId != pieceId.ToLowerInvariant()) throw new CloudFailure("invalid_request");
    var plain = CloudShelfSeal.Pad(bytes);
    var key = PieceKey(kind, role, pieceId);
    try
    {
      var cipher = new byte[plain.Length];
      var tag = new byte[16];
      using (var aes = new AesGcm(key, 16)) aes.Encrypt(nonce, plain, cipher, tag, CloudShelfSeal.Aad(Sub, kind, role, Epoch, pieceId));
      return new(1, CloudShelfSeal.Suite, CloudShelfSeal.Raw(kind), CloudShelfSeal.Raw(role), Epoch, pieceId, CloudBytes.Base64Url(nonce), CloudBytes.Base64Url(cipher), CloudBytes.Base64Url(tag));
    }
    finally { CryptographicOperations.ZeroMemory(plain); CryptographicOperations.ZeroMemory(key); }
  }
  /// Opens one piece of THIS account and generation, of the expected kind and role. Anything else throws.
  public byte[] Open(CloudShelfSeal.Piece piece, CloudShelfSeal.Kind kind, CloudShelfSeal.Role role)
  {
    if (piece.V != 1 || piece.Suite != CloudShelfSeal.Suite || piece.Kind != CloudShelfSeal.Raw(kind) || piece.Role != CloudShelfSeal.Raw(role) || piece.Epoch != Epoch)
      throw new CloudFailure("unsupported_format");
    var key = PieceKey(kind, role, piece.PieceId);
    try
    {
      var cipher = CloudBytes.Unbase64(piece.Ciphertext);
      var plain = new byte[cipher.Length];
      using (var aes = new AesGcm(key, 16)) aes.Decrypt(CloudBytes.Unbase64(piece.Nonce, 12), cipher, CloudBytes.Unbase64(piece.Tag, 16), plain, CloudShelfSeal.Aad(Sub, kind, role, Epoch, piece.PieceId));
      return CloudShelfSeal.Unpad(plain);
    }
    catch (CryptographicException) { throw new CloudFailure("checksum_mismatch"); }
    finally { CryptographicOperations.ZeroMemory(key); }
  }

  private byte[] Mac(string text) => HMACSHA256.HashData(refKey, Encoding.UTF8.GetBytes(text));
  /// The item's opaque reference inside the list: the same on every device of the account for the same item.
  public string Ref(CloudShelfSeal.Kind kind, string itemKey) => Convert.ToHexStringLower(Mac("item\n" + CloudShelfSeal.Raw(kind) + "\n" + itemKey)[..16]);
  /// A value piece's id: the same for the same item and bytes, a new one when the value changes.
  public string ValueId(CloudShelfSeal.Kind kind, string itemKey, byte[] bytes)
  {
    var raw = Mac("value\n" + CloudShelfSeal.Raw(kind) + "\n" + itemKey + "\n" + CloudBytes.Sha256Hex(bytes))[..16];
    raw[6] = (byte)(raw[6] & 0x0f | 0x40);
    raw[8] = (byte)(raw[8] & 0x3f | 0x80);
    var hex = Convert.ToHexStringLower(raw);
    return hex[..8] + "-" + hex[8..12] + "-" + hex[12..16] + "-" + hex[16..20] + "-" + hex[20..];
  }
  /// A keyed fingerprint of one kind's whole sealed view. Holds no name or value.
  public string Fingerprint(byte[] bytes) => Convert.ToHexStringLower(HMACSHA256.HashData(refKey, Encoding.UTF8.GetBytes("fingerprint\n").Concat(bytes).ToArray()));
}

/// One record his devices sync, as the saved-passwords lane hands it: its source, id, domain and decoded payload.
public sealed record CloudShelfSealedRecord(string SourceId, string RecordId, string Domain, CloudJson Payload);

/// What a sealed round may carry (BackendCloudSecretsGraph.ShelfSealed).
public abstract record CloudShelfSealedMaterial
{
  /// Saved passwords are locked, not set up or not open here: nothing may be sealed.
  public sealed record NotNow : CloudShelfSealedMaterial;
  /// His setting keeps saved passwords and secret files off his phones: both kinds leave the shelf.
  public sealed record KeptOff : CloudShelfSealedMaterial;
  /// `Failed`: source id -> a fixed reason (never a name or a value) for each source that could not be read.
  public sealed record Ready(CloudShelfSealer Sealer, IReadOnlyList<CloudShelfSealedRecord> Records, IReadOnlyDictionary<string, string> ProjectNames,
    IReadOnlyDictionary<string, string> Failed) : CloudShelfSealedMaterial;
}

/// The saved-passwords lane's one door into the sealed shelf. None registered = no sealed round.
public interface ICloudShelfSealedSource
{
  Task<CloudShelfSealedMaterial> MaterialAsync(CancellationToken cancel);
}

public static class CloudShelfSealed
{
  public const string ProjectFilesSource = "project-files";
  public const int PiecesPerCall = 64, BodyBytes = 900_000;
  public static int MaximumItems(CloudShelfSeal.Kind kind) => kind == CloudShelfSeal.Kind.SavedPasswords ? 2_000 : 400;

  public sealed record Listed(string Name, string Purpose, string? Place, long? ChangedAt, IReadOnlyList<string> Labels);
  public sealed record FileListed(string Project, string File, string Place, long? ChangedAt, string? ChangedBy);
  public sealed record Made(string ItemKey, Listed? Password, FileListed? File, byte[] Value);

  /// One source's lines in a list put before: carried over unchanged while that source cannot be read.
  public sealed class Carried
  {
    public List<CloudShelfSeal.SavedPassword> Passwords { get; } = [];
    public List<CloudShelfSeal.SecretFile> Files { get; } = [];
    public IEnumerable<string> ValueIds => Passwords.Select(p => p.Value).Concat(Files.Select(f => f.Value));
  }
  public sealed class Pieces
  {
    public required CloudShelfSeal.Kind Kind { get; init; }
    public required IReadOnlyList<CloudShelfSeal.Piece> Index { get; init; }
    public required IReadOnlyList<CloudShelfSeal.Piece> Values { get; init; }
    public required int Count { get; init; }
    public required string Fingerprint { get; init; }
    public IReadOnlyList<string> Sources { get; set; } = [];
    public Dictionary<string, Carried> BySource { get; set; } = new(StringComparer.Ordinal);
    public IReadOnlyList<string> CarriedIds { get; set; } = [];
  }

  public static CloudShelfSeal.Kind KindOfSource(string sourceId) => sourceId == ProjectFilesSource ? CloudShelfSeal.Kind.ProjectSecretFiles : CloudShelfSeal.Kind.SavedPasswords;

  /// The two kinds' items from the synced records. `projectNames`: project id -> his name for it.
  public static Dictionary<CloudShelfSeal.Kind, List<Made>> Items(IReadOnlyList<CloudShelfSealedRecord> records, IReadOnlyDictionary<string, string> projectNames)
  {
    var made = CloudShelfSeal.Kinds.ToDictionary(k => k, _ => new List<Made>());
    var shown = new HashSet<string>(StringComparer.Ordinal);
    foreach (var record in records)
    {
      var key = record.SourceId + "\n" + record.RecordId;
      if (record.SourceId == ProjectFilesSource)
      {
        if (record.Domain != "project" || record.Payload is not CloudJson.Object file || Text(file, "data") is not { } data) continue;
        byte[] bytes;
        try { bytes = Convert.FromBase64String(data); } catch (FormatException) { continue; }
        var folder = Text(file, "folder") ?? "";
        var path = Text(file, "path") ?? "";
        var place = folder.Length == 0 ? path : folder + "/" + path;
        var name = path.Split('/')[^1];
        var at = Long(file, "at") ?? 0;
        made[CloudShelfSeal.Kind.ProjectSecretFiles].Add(new Made(key, null,
          new FileListed(Clip(projectNames.GetValueOrDefault(Text(file, "projectId") ?? ""), 128) ?? "A project", Clip(name, 128) ?? "File", Clip(place, 512) ?? name,
            at > 0 ? at : null, Clip(Text(file, "from"), 64)), bytes));
        continue;
      }
      if (Password(record) is not { } line) continue;
      var value = CloudShelfSeal.ValueBytes(line.Fields);
      var same = SHA256.HashData(Encoding.UTF8.GetBytes(record.SourceId + "\n" + line.Name + "\n" + line.Purpose + "\n").Concat(value).ToArray());
      if (!shown.Add(Convert.ToHexStringLower(same))) continue;
      made[CloudShelfSeal.Kind.SavedPasswords].Add(new Made(key, new Listed(line.Name, line.Purpose, line.Place, null, line.Fields.Select(f => f.Label).ToArray()), null, value));
    }
    foreach (var list in made.Values) list.Sort((a, b) => string.CompareOrdinal(a.ItemKey, b.ItemKey));
    return made;
  }

  public sealed record Line(string Name, string Purpose, string? Place, IReadOnlyList<CloudShelfSeal.Field> Fields);

  private static CloudJson? Get(CloudJson.Object o, string key) => o.Members.FirstOrDefault(m => m.Key == key).Value;
  private static string? Text(CloudJson? o, string key) => o is CloudJson.Object obj && Get(obj, key) is CloudJson.String s ? s.Value : null;
  private static long? Long(CloudJson? o, string key) => o is CloudJson.Object obj && Get(obj, key) is CloudJson.Number n ? (long)n.Value : null;
  private static CloudJson? Sub(CloudJson? o, string key) => o is CloudJson.Object obj ? Get(obj, key) : null;
  private static bool Domain(CloudShelfSealedRecord r, string domain) => r.Domain == domain && r.Payload is CloudJson.Object;

  /// One saved password in the words the phone shows: name, what it is for, where, and its fields.
  public static Line? Password(CloudShelfSealedRecord record)
  {
    var p = record.Payload;
    switch (record.SourceId)
    {
      case "servers":
      {
        if (!Domain(record, "server")) return null;
        var fields = new List<CloudShelfSeal.Field>();
        string? place = null;
        var server = Sub(p, "server");
        if (server is CloudJson.Object)
        {
          if (Text(server, "username") is { Length: > 0 } user) fields.Add(new("User", user, false));
          if (Text(server, "address") is { Length: > 0 } address)
          {
            var port = Long(server, "port") ?? 22;
            var at = port == 22 || port <= 0 ? address : address + ":" + port.ToString(CultureInfo.InvariantCulture);
            fields.Add(new("Address", at, false));
            place = at;
          }
        }
        if (Text(p, "password") is { Length: > 0 } password) fields.Add(new("Password", password, true));
        if (Text(p, "privateKey") is { Length: > 0 } key) fields.Add(new("Private key", key, true));
        if (Text(p, "passphrase") is { Length: > 0 } phrase) fields.Add(new("Passphrase", phrase, true));
        if (!fields.Any(f => f.Secret)) return null;
        return new(Clip(Text(server, "name"), 128) ?? "Server sign-in", "Server", Clip(place, 512), fields);
      }
      case "voice":
        if (!Domain(record, "app") || Text(p, "key") is not { Length: > 0 } voiceKey) return null;
        return new("Voice key", Clip(Text(p, "provider"), 64) ?? "Voice", null, [new("Key", voiceKey, true), new("Service", Text(p, "endpoint") ?? "", false)]);
      case "api":
      {
        if (!Domain(record, "api-key") || Text(p, "key") is not { Length: > 0 } apiKey) return null;
        var fields = new List<CloudShelfSeal.Field> { new("Key", apiKey, true), new("Service", Text(p, "baseURL") ?? "", false) };
        if (Text(p, "model") is { Length: > 0 } model) fields.Add(new("Model", model, false));
        if (Text(p, "workspaceID") is { Length: > 0 } workspace) fields.Add(new("Workspace", workspace, false));
        return new(Clip(Text(p, "name"), 128) ?? "API key", "API key", null, fields);
      }
      case "tasks":
        if (!Domain(record, "task-connection") || Text(p, "token") is not { Length: > 0 } token) return null;
        return new(Clip(Text(p, "name"), 128) ?? "Task connection", "Task connection", null, [new("Token", token, true)]);
      case "ssh":
      {
        if (!Domain(record, "ssh") || Text(p, "hostname") is not { } host || Text(p, "user") is not { } sshUser) return null;
        var port = Long(p, "port") ?? 22;
        var address = port == 22 ? host : host + ":" + port.ToString(CultureInfo.InvariantCulture);
        var fields = new List<CloudShelfSeal.Field> { new("User", sshUser, false), new("Address", address, false) };
        if (Sub(p, "keys") is CloudJson.Array keys)
          foreach (var k in keys.Items)
          {
            string bytes;
            try { bytes = Encoding.UTF8.GetString(Convert.FromBase64String(Text(k, "bytes") ?? "")); } catch (FormatException) { continue; }
            fields.Add(new("Key file " + (Clip(Text(k, "name"), 48) ?? "key"), bytes, true));
          }
        return new("Server key · " + (Clip(Text(Sub(p, "server"), "name"), 110) ?? "server"), "Server key", Clip(address, 512), fields);
      }
      case "receiver":
      {
        if (!Domain(record, "receiver") || Sub(p, "source") is not CloudJson.Object source || Sub(p, "secrets") is not CloudJson.Object secrets
          || Text(secrets, "secret") is not { Length: > 0 } secret) return null;
        var fields = new List<CloudShelfSeal.Field> { new("Secret", secret, true) };
        if (Text(secrets, "reply") is { Length: > 0 } reply) fields.Add(new("Reply token", reply, true));
        return new(Clip(Text(source, "name"), 128) ?? "Receiver source", "Receiver", null, fields);
      }
      default:
      {
        var raw = p;
        if (record.SourceId == "mcp-user" && Sub(p, "definition") is CloudJson.Object definition) raw = definition;
        var fields = new List<CloudShelfSeal.Field>();
        Flatten(raw, "", fields);
        if (fields.Count == 0) return null;
        var name = record.SourceId == "mcp-user" ? Clip(record.RecordId, 128) ?? "MCP server" : Noun(record.Domain);
        return new(name, record.SourceId == "mcp-user" ? "MCP server" : Noun(record.Domain), null, fields);
      }
    }
  }

  public static string Noun(string domain) => domain switch
  {
    "api-key" => "API key", "server" => "Server sign-in", "ssh" => "SSH key", "mcp" => "MCP server", "task-connection" => "Task connection",
    "receiver" => "Receiver sign-in", "project" => "Project password", "app" => "App password", _ => "Saved password"
  };
  private static readonly string[] SecretWords = ["key", "token", "secret", "password", "passwd", "passphrase", "auth", "credential", "cookie", "session", "bearer"];
  private static void Flatten(CloudJson value, string path, List<CloudShelfSeal.Field> fields)
  {
    if (fields.Count >= 64) return;
    void Add(string text)
    {
      var label = Clip(path.Length == 0 ? "Value" : path, 64) ?? "Value";
      var lower = label.ToLowerInvariant();
      fields.Add(new(label, text, SecretWords.Any(lower.Contains)));
    }
    switch (value)
    {
      case CloudJson.Object o: foreach (var m in o.Members) Flatten(m.Value, path.Length == 0 ? m.Key : path + "." + m.Key, fields); break;
      case CloudJson.Array a: for (var i = 0; i < a.Items.Count; i++) Flatten(a.Items[i], path + "[" + i.ToString(CultureInfo.InvariantCulture) + "]", fields); break;
      case CloudJson.String s: Add(s.Value); break;
      case CloudJson.Number n: Add(n.Value == Math.Round(n.Value) && Math.Abs(n.Value) < 1e15 ? ((long)n.Value).ToString(CultureInfo.InvariantCulture) : n.Value.ToString("R", CultureInfo.InvariantCulture)); break;
      case CloudJson.Bool b: Add(b.Value ? "true" : "false"); break;
    }
  }

  /// One line, trimmed, at most `limit` characters ("…" when cut); null when empty.
  public static string? Clip(string? text, int limit)
  {
    if (text is null) return null;
    var line = string.Join(" ", text.Split(['\n', '\r', '\u2028', '\u2029', '\u0085', '\u000B', '\u000C'])).Trim();
    return line.Length == 0 ? null : CloudShelf.Clip(line, limit);
  }

  /// One kind sealed for a put: one value piece per item (its id stays while its bytes stay), the list in index pieces.
  /// `carried`: per source that cannot be read this round, its lines from the list put before (named again, not sent).
  public static Pieces Seal(CloudShelfSeal.Kind kind, IReadOnlyList<Made> items, CloudShelfSealer sealer, string putId, long madeAt, string madeBy,
    IReadOnlyDictionary<string, Carried>? carried = null)
  {
    var values = new List<CloudShelfSeal.Piece>();
    var passwords = new List<CloudShelfSeal.SavedPassword>();
    var files = new List<CloudShelfSeal.SecretFile>();
    var bySource = new Dictionary<string, Carried>(StringComparer.Ordinal);
    var limit = MaximumItems(kind);
    foreach (var item in items.Take(limit))
    {
      if (CloudShelfSeal.Step(item.Value.Length + 4) is null) continue;
      var source = item.ItemKey.Split('\n', 2)[0];
      var id = sealer.ValueId(kind, item.ItemKey, item.Value);
      var reference = sealer.Ref(kind, item.ItemKey);
      values.Add(sealer.Seal(item.Value, kind, CloudShelfSeal.Role.Value, id));
      if (!bySource.TryGetValue(source, out var mine)) bySource[source] = mine = new Carried();
      if (item.Password is { } listed)
      {
        var line = new CloudShelfSeal.SavedPassword(reference, listed.Name, listed.Purpose, listed.Place, listed.ChangedAt, id, item.Value.Length, listed.Labels);
        passwords.Add(line); mine.Passwords.Add(line);
      }
      else if (item.File is { } file)
      {
        var line = new CloudShelfSeal.SecretFile(reference, file.Project, file.File, file.Place, file.ChangedAt, file.ChangedBy, item.Value.Length, id);
        files.Add(line); mine.Files.Add(line);
      }
    }
    var carriedIds = new List<string>();
    var fresh = values.Select(v => v.PieceId).ToHashSet(StringComparer.Ordinal);
    foreach (var source in (carried?.Keys ?? []).Order(StringComparer.Ordinal))
    {
      if (bySource.ContainsKey(source)) continue;
      var lines = carried![source];
      var kept = new Carried();
      foreach (var line in lines.Passwords) if (passwords.Count + files.Count < limit && !fresh.Contains(line.Value)) { passwords.Add(line); kept.Passwords.Add(line); }
      foreach (var line in lines.Files) if (passwords.Count + files.Count < limit && !fresh.Contains(line.Value)) { files.Add(line); kept.Files.Add(line); }
      bySource[source] = kept;
      carriedIds.AddRange(kept.ValueIds);
    }
    passwords.Sort((a, b) => string.CompareOrdinal(a.Ref, b.Ref));
    files.Sort((a, b) => string.CompareOrdinal(a.Ref, b.Ref));
    var steady = Steady(passwords, files);
    var chunks = new List<(List<CloudShelfSeal.SavedPassword> P, List<CloudShelfSeal.SecretFile> F)>();
    var current = (P: new List<CloudShelfSeal.SavedPassword>(), F: new List<CloudShelfSeal.SecretFile>());
    var size = 0;
    foreach (var line in passwords)
    {
      var w = CloudShelfJson.Encode(line.Json()).Length + 1;
      if (size + w > CloudShelfSeal.IndexPartBytes && current.P.Count > 0) { chunks.Add(current); current = ([], []); size = 0; }
      current.P.Add(line); size += w;
    }
    foreach (var line in files)
    {
      var w = CloudShelfJson.Encode(line.Json()).Length + 1;
      if (size + w > CloudShelfSeal.IndexPartBytes && current.F.Count > 0) { chunks.Add(current); current = ([], []); size = 0; }
      current.F.Add(line); size += w;
    }
    if (current.P.Count > 0 || current.F.Count > 0 || chunks.Count == 0) chunks.Add(current);
    var count = passwords.Count + files.Count;
    var index = chunks.Select((chunk, part) => sealer.Seal(CloudShelfSeal.IndexBytes(kind, putId, part, chunks.Count, madeAt, madeBy, count,
      kind == CloudShelfSeal.Kind.SavedPasswords ? chunk.P : null, kind == CloudShelfSeal.Kind.ProjectSecretFiles ? chunk.F : null),
      kind, CloudShelfSeal.Role.Index, Guid.NewGuid().ToString("D"))).ToArray();
    return new Pieces
    {
      Kind = kind, Index = index, Values = values, Count = count, Fingerprint = sealer.Fingerprint(steady),
      Sources = bySource.Where(s => s.Value.Passwords.Count > 0 || s.Value.Files.Count > 0).Select(s => s.Key).Order(StringComparer.Ordinal).ToArray(),
      BySource = bySource, CarriedIds = carriedIds.Distinct().Order(StringComparer.Ordinal).ToArray(),
    };
  }

  /// The steady list behind the keyed fingerprint: `{"files":[…],"passwords":[…]}` with sorted keys.
  public static byte[] Steady(IReadOnlyList<CloudShelfSeal.SavedPassword> passwords, IReadOnlyList<CloudShelfSeal.SecretFile> files) =>
    CloudShelfJson.Encode(new CloudShelfJson.Obj().Add("passwords", passwords.Select(p => p.Json()).ToList()).Add("files", files.Select(f => f.Json()).ToList()));
}

/// The sealed putter: only what changed, resume by asking the service which pieces it lacks, the shelf setting. Keeps
/// beside the shelf state only keyed fingerprints, when each kind was put and its key generation: `shelf-sealed.json`.
public sealed class CloudShelfSealedPutter
{
  public sealed class KindState
  {
    public string? Fingerprint { get; set; }
    public int? Epoch { get; set; }
    public long? PutAt { get; set; }
    public List<string>? Sources { get; set; }
    public Dictionary<string, long>? FailingSince { get; set; }
  }
  public sealed class State
  {
    public Dictionary<string, KindState> Kinds { get; set; } = [];
    public bool Cleared { get; set; }
  }
  public enum Outcome { Put, Unchanged, Behind, Off, Missing, Later, Cleared }

  private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
  private readonly CloudShelfPutter door;
  private readonly string? file;
  private readonly Dictionary<CloudShelfSeal.Kind, long> retryAt = [];
  public State Current { get; private set; }
  public bool Missing { get; private set; }
  /// The service's last refusal in fixed words ("status 403 not_approved", "no answer"); null after an answer that went.
  public string? LastRefusal { get; private set; }

  /// `door`: the shelf putter whose calls (and shelf door) this one uses; its own state lives in `file`.
  public CloudShelfSealedPutter(CloudShelfPutter door, string? file)
  {
    this.door = door;
    this.file = file;
    State? saved = null;
    try { if (file is not null && File.Exists(file)) saved = JsonSerializer.Deserialize<State>(File.ReadAllBytes(file), Json); } catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
    Current = saved ?? new State();
  }
  private void Save()
  {
    if (file is null) return;
    try { Directory.CreateDirectory(Path.GetDirectoryName(file)!); File.WriteAllBytes(file + ".tmp", JsonSerializer.SerializeToUtf8Bytes(Current, Json)); File.Move(file + ".tmp", file, true); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
  }
  /// The service's short code, kept to its own alphabet (never more than 40 of a-z, 0-9 and "_").
  public static string Code(string text) => new(text.ToLowerInvariant().Where(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '_').Take(40).ToArray());

  private async Task<CloudShelfPutter.Answer> CallAsync(string path, byte[] body)
  {
    if (Missing) return new(CloudShelfPutter.Kind.Refused, [], 404, "not_found");
    var answer = await door.CallAsync("POST", path, body, quiet404: true);
    if (answer.Kind == CloudShelfPutter.Kind.Lost) LastRefusal = "no answer";
    else if (answer.Kind == CloudShelfPutter.Kind.Ok) LastRefusal = null;
    else
    {
      LastRefusal = "status " + answer.Status.ToString(CultureInfo.InvariantCulture) + (answer.Code is { } c ? " " + Code(c) : "");
      if (answer.Status == 404) Missing = true;
    }
    return answer;
  }

  /// Puts one sealed kind when its keyed fingerprint changed (or `force`). Order: the value pieces the service lacks,
  /// then the list (the commit). A crash in between resumes by itself.
  public async Task<(Outcome Outcome, int Count, int Pieces)> PutAsync(CloudShelfSealed.Pieces made, int epoch, string throughSeq, bool force, long now)
  {
    var kind = made.Kind;
    var raw = CloudShelfSeal.Raw(kind);
    if (Missing) return (Outcome.Missing, 0, 0);
    if (retryAt.TryGetValue(kind, out var wait) && now < wait) return (Outcome.Later, 0, 0);
    var known = Current.Kinds.GetValueOrDefault(raw) ?? new KindState();
    if (!force && known.Fingerprint == made.Fingerprint && known.Epoch == epoch) return (Outcome.Unchanged, 0, 0);
    var need = new List<string>();
    var ids = made.Values.Select(v => v.PieceId).ToList();
    for (var start = 0; start < ids.Count; start += 500)
    {
      var slice = ids.Skip(start).Take(500).ToList();
      var answer = await CallAsync("/shelf/sealed/missing", CloudShelfJson.Encode(new CloudShelfJson.Obj().Add("kind", raw).Add("epoch", epoch).Add("pieceIds", slice)));
      if (answer.Kind == CloudShelfPutter.Kind.Lost) return (Outcome.Later, 0, 0);
      if (answer.Kind == CloudShelfPutter.Kind.Refused) return (Stop(kind, answer, now), 0, 0);
      try
      {
        using var doc = JsonDocument.Parse(answer.Data);
        need.AddRange(doc.RootElement.TryGetProperty("missing", out var m) && m.ValueKind == JsonValueKind.Array ? m.EnumerateArray().Select(e => e.GetString() ?? "") : slice);
      }
      catch (JsonException) { need.AddRange(slice); }
    }
    var wanted = need.ToHashSet(StringComparer.Ordinal);
    var batch = new List<CloudShelfJson.Obj>();
    int size = 0, sent = 0;
    foreach (var piece in made.Values.Where(v => wanted.Contains(v.PieceId)))
    {
      var json = piece.Json();
      var width = CloudShelfJson.Encode(json).Length + 1;
      if (batch.Count > 0 && (batch.Count >= CloudShelfSealed.PiecesPerCall || size + width > CloudShelfSealed.BodyBytes))
      {
        if (await PostPiecesAsync(kind, epoch, batch, now) is { } halted) return (halted, 0, sent);
        sent += batch.Count; batch = []; size = 0;
      }
      batch.Add(json); size += width;
    }
    if (batch.Count > 0)
    {
      if (await PostPiecesAsync(kind, epoch, batch, now) is { } halted) return (halted, 0, sent);
      sent += batch.Count;
    }
    var index = await CallAsync("/shelf/sealed/index", CloudShelfJson.Encode(new CloudShelfJson.Obj().Add("kind", raw).Add("putId", Guid.NewGuid().ToString("D"))
      .Add("epoch", epoch).Add("throughSeq", throughSeq).Add("count", made.Count).Add("valueIds", ids.Concat(made.CarriedIds).ToList())
      .Add("index", made.Index.Select(p => p.Json()).ToList())));
    if (index.Kind == CloudShelfPutter.Kind.Lost) return (Outcome.Later, 0, sent);
    if (index.Kind == CloudShelfPutter.Kind.Refused)
    {
      if (index.Status == 409 && index.Code == "shelf_behind") { Remember(known, made, epoch, now); Current.Kinds[raw] = known; Save(); }
      return (Stop(kind, index, now), 0, sent);
    }
    try
    {
      using var doc = JsonDocument.Parse(index.Data);
      if (!doc.RootElement.TryGetProperty("accepted", out var ok) || ok.ValueKind != JsonValueKind.True) return (Outcome.Later, 0, sent);
    }
    catch (JsonException) { return (Outcome.Later, 0, sent); }
    Remember(known, made, epoch, now);
    Current.Kinds[raw] = known;
    Current.Cleared = false;
    Save();
    return (Outcome.Put, made.Count, sent);
  }
  private static void Remember(KindState known, CloudShelfSealed.Pieces made, int epoch, long now)
  {
    known.Fingerprint = made.Fingerprint; known.Epoch = epoch; known.PutAt = now; known.Sources = made.Sources.ToList();
  }
  private async Task<Outcome?> PostPiecesAsync(CloudShelfSeal.Kind kind, int epoch, List<CloudShelfJson.Obj> pieces, long now)
  {
    var answer = await CallAsync("/shelf/sealed/pieces", CloudShelfJson.Encode(new CloudShelfJson.Obj().Add("kind", CloudShelfSeal.Raw(kind)).Add("epoch", epoch).Add("pieces", pieces)));
    return answer.Kind switch { CloudShelfPutter.Kind.Ok => null, CloudShelfPutter.Kind.Lost => Outcome.Later, _ => Stop(kind, answer, now) };
  }
  private Outcome Stop(CloudShelfSeal.Kind kind, CloudShelfPutter.Answer answer, long now)
  {
    if (answer.Status == 404) return Outcome.Missing;
    if (answer.Status == 409 && answer.Code == "shelf_behind") return Outcome.Behind;
    if (answer.Status == 409 && answer.Code is "shelf_off" or "sealed_off") return Outcome.Off;
    retryAt[kind] = now + (answer.Status == 429 ? Math.Max(answer.RetryAfterMs ?? 0, CloudShelf.SettleMs) : CloudShelf.SettleMs);
    return Outcome.Later;
  }

  /// His phones setting keeps them off (or saved passwords started anew): both kinds leave the shelf now. Once.
  public async Task<Outcome> ClearAsync()
  {
    if (Current.Cleared) return Outcome.Unchanged;
    if (Missing) return Outcome.Missing;
    foreach (var kind in CloudShelfSeal.Kinds)
    {
      var answer = await CallAsync("/shelf/sealed/clear", CloudShelfJson.Encode(new CloudShelfJson.Obj().Add("kind", CloudShelfSeal.Raw(kind))));
      if (answer.Kind == CloudShelfPutter.Kind.Lost) return Outcome.Later;
      if (answer.Kind == CloudShelfPutter.Kind.Refused) return answer.Status == 404 ? Outcome.Missing : Outcome.Later;
    }
    Current = new State { Cleared = true };
    Save();
    return Outcome.Cleared;
  }
  /// Keeps when each failing source of a kind first failed (saved only when it changes).
  public void SetFailing(CloudShelfSeal.Kind kind, Dictionary<string, long> since)
  {
    var raw = CloudShelfSeal.Raw(kind);
    var had = Current.Kinds.GetValueOrDefault(raw);
    var next = since.Count == 0 ? null : since;
    var same = had?.FailingSince is null ? next is null : next is not null && had.FailingSince.Count == next.Count && next.All(n => had.FailingSince.TryGetValue(n.Key, out var v) && v == n.Value);
    if (same || had is null && next is null) return;
    var known = had ?? new KindState();
    known.FailingSince = next;
    Current.Kinds[raw] = known;
    Save();
  }
  public bool Due(CloudShelfSeal.Kind kind, long now) => now - (Current.Kinds.GetValueOrDefault(CloudShelfSeal.Raw(kind))?.PutAt ?? 0) >= CloudShelf.DayMs;
}

/// One sealed round (BackendCloudShelfSealedRound). Rules:
/// - A source that cannot be read does not hold back the list: the list goes up with the sources that could be read. A
///   source never on the shelf is left out for now; a source his phones show now keeps its last lines (at most 24 hours),
///   and when this PC does not hold them in memory the kind stays exactly as it is on the shelf.
/// - A failed source or a refused put is tried again 30 s later, then on the normal rhythm (10 minutes or a moved feed).
/// - ONE plain log line per round outcome (a repeat is not written again): kind titles, counts, source ids, fixed
///   reasons, the service's status and short code. Never a name, a place or a value.
public sealed class CloudShelfSealedRound(CloudShelfSealedPutter putter, ICloudShelfSealedSource source, Action<string> note, Func<long>? clock = null)
{
  private readonly Func<long> clock = clock ?? CloudShelfPutter.Now;
  private readonly Dictionary<CloudShelfSeal.Kind, (string Fingerprint, long Since)> seen = [];
  private readonly Dictionary<CloudShelfSeal.Kind, Dictionary<string, CloudShelfSealed.Carried>> lastLines = [];
  private long lastBuild;
  private string lastSignal = "";
  private bool retried;
  public long? RetryAt { get; private set; }
  public string? LastLine { get; private set; }
  public const long RebuildMs = 600_000;

  public void Soon() { RetryAt = clock(); retried = false; }
  public bool RetryDue() => RetryAt is { } at && clock() >= at;
  public bool Settling => seen.Count > 0;
  private static string Title(CloudShelfSeal.Kind kind) => kind == CloudShelfSeal.Kind.SavedPasswords ? "saved passwords" : "secret files";
  private static string SourceTitle(string id) => CloudShelfWords.Plain(id) ?? "a source";

  /// One round. Returns false when nothing was due.
  public async Task<bool> RunAsync(string throughSeq, string? from, bool atLaunch, string signal)
  {
    var now = clock();
    var daily = CloudShelfSeal.Kinds.Any(k => putter.Due(k, now));
    var retry = RetryAt is { } at && now >= at;
    if (!(atLaunch || seen.Count > 0 || daily || retry || signal != lastSignal || now - lastBuild >= RebuildMs)) return false;
    lastSignal = signal; lastBuild = now;
    if (retry) RetryAt = null;
    CloudShelfSealedMaterial material;
    try { material = await source.MaterialAsync(CancellationToken.None); }
    catch (Exception) { material = new CloudShelfSealedMaterial.NotNow(); }
    switch (material)
    {
      case CloudShelfSealedMaterial.KeptOff:
      {
        seen.Clear();
        var outcome = await putter.ClearAsync();
        Say("kept off your phones by your setting" + (outcome == CloudShelfSealedPutter.Outcome.Later ? "; taking them off the shelf is tried again" : ""));
        if (outcome == CloudShelfSealedPutter.Outcome.Later) Again(); else retried = false;
        return true;
      }
      case CloudShelfSealedMaterial.Ready ready:
        await ReadyAsync(ready, throughSeq, from, atLaunch);
        return true;
      default:
        Say("not now: saved passwords are locked, not set up or not open on this PC");
        return true;
    }
  }

  private async Task ReadyAsync(CloudShelfSealedMaterial.Ready ready, string throughSeq, string? from, bool atLaunch)
  {
    Dictionary<CloudShelfSeal.Kind, List<CloudShelfSealed.Made>> items;
    try { items = CloudShelfSealed.Items(ready.Records, ready.ProjectNames); }
    catch (Exception) { Say("could not be read"); Again(); return; }
    var parts = new List<string>();
    var trouble = ready.Failed.Count > 0;
    foreach (var kind in CloudShelfSeal.Kinds)
    {
      var known = putter.Current.Kinds.GetValueOrDefault(CloudShelfSeal.Raw(kind));
      var failedHere = ready.Failed.Keys.Where(s => CloudShelfSealed.KindOfSource(s) == kind).Order(StringComparer.Ordinal).ToArray();
      var shown = failedHere.Where(s => known?.PutAt is not null && (known.Sources is null || known.Sources.Contains(s))).ToArray();
      var now = clock();
      var since = (known?.FailingSince ?? []).Where(f => shown.Contains(f.Key)).ToDictionary(f => f.Key, f => f.Value, StringComparer.Ordinal);
      foreach (var s in shown) since.TryAdd(s, now);
      putter.SetFailing(kind, since);
      var expired = shown.Where(s => now - since.GetValueOrDefault(s, now) >= CloudShelf.DayMs).ToArray();
      var carry = new Dictionary<string, CloudShelfSealed.Carried>(StringComparer.Ordinal);
      var whole = new List<string>();
      foreach (var s in shown.Except(expired))
        if (lastLines.TryGetValue(kind, out var mine) && mine.TryGetValue(s, out var lines)) carry[s] = lines; else whole.Add(s);
      if (whole.Count > 0)
      {
        seen.Remove(kind);
        parts.Add(Title(kind) + ": kept as on your phones until " + string.Join(", ", whole.Select(SourceTitle)) + " can be read");
        continue;
      }
      CloudShelfSealed.Pieces made;
      try { made = CloudShelfSealed.Seal(kind, items[kind], ready.Sealer, Guid.NewGuid().ToString("D"), clock(), from ?? "PC", carry); }
      catch (Exception) { parts.Add(Title(kind) + ": could not be sealed"); trouble = true; continue; }
      if (carry.Count > 0) parts.Add(Title(kind) + ": last entries carried for " + string.Join(", ", carry.Keys.Order(StringComparer.Ordinal).Select(SourceTitle)));
      if (expired.Length > 0) parts.Add(Title(kind) + ": left out after 24 hours: " + string.Join(", ", expired.Select(SourceTitle)));
      var changed = known?.Fingerprint != made.Fingerprint || known?.Epoch != ready.Sealer.Epoch;
      var due = putter.Due(kind, clock());
      if (!changed && !due) { seen.Remove(kind); lastLines[kind] = made.BySource; parts.Add(Title(kind) + ": unchanged"); continue; }
      var joins = !made.Sources.ToHashSet(StringComparer.Ordinal).IsSubsetOf(known?.Sources ?? []);
      if (changed && !atLaunch && !joins)
      {
        if (!seen.TryGetValue(kind, out var held) || held.Fingerprint != made.Fingerprint) { seen[kind] = (made.Fingerprint, clock()); parts.Add(Title(kind) + ": changed, settling"); continue; }
        if (clock() - held.Since < CloudShelf.SettleMs) { parts.Add(Title(kind) + ": changed, settling"); continue; }
      }
      var (outcome, count, _) = await putter.PutAsync(made, ready.Sealer.Epoch, throughSeq, due && !changed, clock());
      var refusal = putter.LastRefusal;
      switch (outcome)
      {
        case CloudShelfSealedPutter.Outcome.Put: seen.Remove(kind); lastLines[kind] = made.BySource; parts.Add(Title(kind) + ": put " + count.ToString(CultureInfo.InvariantCulture)); break;
        case CloudShelfSealedPutter.Outcome.Unchanged: seen.Remove(kind); lastLines[kind] = made.BySource; parts.Add(Title(kind) + ": unchanged"); break;
        case CloudShelfSealedPutter.Outcome.Behind: seen.Remove(kind); parts.Add(Title(kind) + ": a newer list from another device is there"); break;
        case CloudShelfSealedPutter.Outcome.Off: seen.Clear(); Say(Title(kind) + ": the service keeps the shelf off (" + (refusal ?? "off") + ")"); return;
        case CloudShelfSealedPutter.Outcome.Missing: seen.Clear(); Say("the service has no sealed shelf (" + (refusal ?? "not found") + ")"); return;
        default: trouble = true; parts.Add(Title(kind) + ": refused, tried again shortly (" + (refusal ?? "waiting") + ")"); break;
      }
    }
    if (ready.Failed.Count > 0)
      parts.Add("not read this round: " + string.Join(", ", ready.Failed.Keys.Order(StringComparer.Ordinal).Select(s => SourceTitle(s) + " (" + (CloudShelfWords.Plain(ready.Failed[s]) ?? "could not be read") + ")")));
    Say(string.Join("; ", parts));
    if (trouble) Again(); else retried = false;
  }

  private void Again()
  {
    if (retried) return;
    retried = true;
    RetryAt = clock() + CloudShelf.SettleMs;
  }
  private void Say(string text)
  {
    var line = "cloud shelf: sealed: " + text;
    if (line == LastLine) return;
    LastLine = line;
    note(line);
  }
}
