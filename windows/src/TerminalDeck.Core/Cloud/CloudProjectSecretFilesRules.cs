using System.Globalization;
using System.Text;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Cloud;

// Project secret files (owner 13/14 Nov: his Cloud account carries "project secret files"), port of the Mac's
// BackendProjectSecretFiles.swift (td-mac-next2). The `.env`-style and credential files inside a project folder travel
// INSIDE saved passwords: sealed with the saved-passwords key, one record per file under the secrets-class domain
// `project`, readable only by his devices that hold that key, only while saved passwords are open. His devices open
// them by themselves; no code, no question. Design: team/security/notes/2026-11-14-project-secret-files.md.
//
// What the service sees of a pack: class secrets, purpose secret, domain `project`, the key generation, size and count.
// The record id (`file/<projectId>/<64 hex>`, an account-keyed HMAC of folder name and path), the path, the bytes, the
// dates are all inside the seal.

public static class CloudProjectSecretFilesRules
{
  public const string SourceId = "project-files", InventoryRow = "I25";
  /// The "every computer understands" gate (CloudAnnounce); no dot allowed in it.
  public const string Feature = "projectsecrets";
  public const int Format = 1;
  /// A sealed record must fit the 64 KB record payload. Every cap holds on send AND on arrival (review 14 Nov, F4).
  public const int FileBytes = 32 * 1024, ProjectFiles = 40, ProjectBytes = 512 * 1024, AllFiles = 400;
  /// Arrivals kept sealed here until they can be placed: at most ProjectFiles per project, AllFiles in all, this many
  /// bytes of sealed text.
  public const int WaitingBytes = 8 * 1024 * 1024;
  /// The local ledger file is never read into memory when it is larger than this.
  public const int LedgerBytes = 12 * 1024 * 1024;
  public const int Depth = 6, WalkEntries = 20_000;
  /// Windows has no permission bits; every value this PC sends says owner-only (the Mac's 0600), and an arriving mode
  /// is never used (F1).
  public const int OwnerOnlyMode = 0x180;
  /// Personal SSH keys are a person's or a machine's credentials, not a project's.
  public static readonly string[] PersonalKeyPrefixes = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"];
  /// F2: tool settings that run programs never travel and are never created on arrival.
  public static readonly IReadOnlySet<string> RunsPrograms = new HashSet<string>(StringComparer.Ordinal) { ".envrc", ".yarnrc.yml" };
  /// Package and build folders never looked into (the Mac's CloudFolderRules.rebuildableFolders, lower case).
  public static readonly IReadOnlySet<string> RebuildableFolders = new HashSet<string>(StringComparer.Ordinal)
    { "node_modules", ".build", "deriveddata", "__pycache__", "venv", ".venv", "pods", ".gradle" };
  /// Explorer's (and Finder's) own files: a folder holding only these is empty (decision 11).
  public static readonly IReadOnlySet<string> SystemFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".DS_Store", "desktop.ini", "Thumbs.db" };

  /// F3: an arrival's temporary file is named like a `.env.*.local` file, so the Code page's secret check holds it back
  /// if a crash ever leaves one behind. Only the exact form `.env.td-cloud-<uuid>.local` counts (R4).
  public const string TemporaryPrefix = ".env.td-cloud-", TemporarySuffix = ".local";
  public static string TemporaryName() => TemporaryPrefix + Guid.NewGuid().ToString("D") + TemporarySuffix;
  public static bool IsTemporary(string name)
  {
    if (!name.StartsWith(TemporaryPrefix, StringComparison.Ordinal) || !name.EndsWith(TemporarySuffix, StringComparison.Ordinal)
      || name.Length != TemporaryPrefix.Length + 36 + TemporarySuffix.Length) return false;
    return Guid.TryParseExact(name.Substring(TemporaryPrefix.Length, 36), "D", out _);
  }
  public const long StaleTemporaryMs = 120_000;

  /// Travels: it goes. StaysHere: a secret file that never travels (named as staying on this PC). Never: not one.
  public enum Verdict { Travels, StaysHere, Never }

  /// The ONE decision, the Code page's (kinds A and C, and B only when the bytes hold a private key), narrowed: never
  /// inside a hidden folder or a package/build folder, never a personal SSH key, never an unclean path, never a file that
  /// runs programs. `bytes` null: by name only. The same check runs on the sending device and on the receiving one.
  public static Verdict Judge(string relative, byte[]? bytes)
  {
    if (!CloudBootFilesFormat.CleanRelative(relative) || CloudBootFilesFormat.Parts(relative) is not { } parts || parts.Length > Depth + 1) return Verdict.Never;
    var name = parts[^1].ToLowerInvariant();
    foreach (var folder in parts[..^1])
      if (folder.StartsWith('.') || RebuildableFolders.Contains(folder.ToLowerInvariant())) return Verdict.Never;
    if (PersonalKeyPrefixes.Any(p => name.StartsWith(p, StringComparison.Ordinal)) || IsTemporary(name)) return Verdict.Never;
    switch (CodeSecrets.KindOf(relative))
    {
      case CodeSecrets.Kind.None: return Verdict.Never;
      case CodeSecrets.Kind.MaybeKey: if (bytes is not null && !CodeSecrets.PrivateKey(bytes)) return Verdict.Never; break;
    }
    if (RunsPrograms.Contains(name)) return Verdict.StaysHere;
    if (bytes is not null && !ContentTravels(name, bytes)) return Verdict.StaysHere;
    return Verdict.Travels;
  }
  public static bool Travels(string relative, byte[]? bytes) => Judge(relative, bytes) == Verdict.Travels;

  /// Files whose CONTENT can make a program run: `.npmrc` only with registry and sign-in lines; `.netrc` without a
  /// `macdef`; an AWS-style `credentials` file without `credential_process`.
  public static bool ContentTravels(string name, byte[] bytes)
  {
    switch (name)
    {
      case ".npmrc": return NpmrcTravels(bytes);
      case ".netrc" or "_netrc":
        // R2: netrc readers also split on ',' and undo '"' and '\': anywhere at all, it stays.
        return !new string(Encoding.UTF8.GetString(bytes).ToLowerInvariant().Where(c => c != '\\' && c != '"').ToArray()).Contains("macdef", StringComparison.Ordinal);
      case "credentials": return !Encoding.UTF8.GetString(bytes).ToLowerInvariant().Contains("credential_process", StringComparison.Ordinal);
      default: return true;
    }
  }
  /// Every line a registry or sign-in line; comments and blank lines allowed. Anything else and the file stays.
  public static bool NpmrcTravels(byte[] bytes)
  {
    string text;
    try { text = new UTF8Encoding(false, true).GetString(bytes); } catch (DecoderFallbackException) { return false; }
    foreach (var raw in text.Split(['\n', '\r', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029'], StringSplitOptions.RemoveEmptyEntries))
    {
      var line = raw.Trim(' ', '\t');
      if (line.Length == 0 || line.StartsWith('#') || line.StartsWith(';')) continue;
      var equals = line.IndexOf('=');
      if (equals < 0 || !NpmrcKeyAllowed(line[..equals].Trim(' ', '\t'))) return false;
    }
    return true;
  }
  private static readonly string[] NpmrcHostKeys = [":_authToken", ":_auth", ":username", ":_password", ":email", ":always-auth"];
  public static bool NpmrcKeyAllowed(string key)
  {
    if (key is "registry" or "always-auth") return true;
    if (key.Length == 0 || key.Any(c => char.IsWhiteSpace(c) || c is '[' or ']' or '=')) return false;
    if (key.StartsWith('@') && key.EndsWith(":registry", StringComparison.Ordinal))
    {
      var scope = key[1..^":registry".Length];
      return scope.Length > 0 && !scope.Contains(':');
    }
    if (key.StartsWith("//", StringComparison.Ordinal) && NpmrcHostKeys.FirstOrDefault(e => key.EndsWith(e, StringComparison.Ordinal)) is { } ending)
      return key.Length > 2 + ending.Length;
    return false;
  }
  /// A project folder's own name as it travels: one plain name, nothing that climbs.
  public static bool CleanFolderName(string name) => CloudBootFilesFormat.CleanRelative(name) && !name.Contains('/');
  public static bool ValidProjectId(string id) => ProjectIdentity.ValidId(id) && id != ProjectIdentity.IndependentId;

  /// F6/F7: a project's registered folder resolved ONCE to its real folder (projects may be registered through a link
  /// or junction); links below it stay refused. Forbidden: the real folder is the home folder, a folder above it, or a
  /// whole disk: nothing travels from it, nothing is written into it.
  public enum RootKind { Ok, Missing, Forbidden }
  public static (RootKind Kind, string? Path) RealRoot(string registered, string home)
  {
    if (CloudProjectSecretFilesDisk.FinalFolder(registered) is not { } real) return (RootKind.Missing, null);
    if (IsVolumeRoot(real)) return (RootKind.Forbidden, null);
    // R5: the home folder under another spelling (a link, a junction) is the same folder: both are resolved.
    foreach (var start in new[] { home, CloudProjectSecretFilesDisk.FinalFolder(home) ?? home }.Distinct(StringComparer.OrdinalIgnoreCase))
    {
      string? up = Trim(start);
      while (up is not null)
      {
        if (string.Equals(Trim(real), up, StringComparison.OrdinalIgnoreCase)) return (RootKind.Forbidden, null);
        up = Path.GetDirectoryName(up) is { Length: > 0 } parent && !string.Equals(parent, up, StringComparison.OrdinalIgnoreCase) ? Trim(parent) : null;
      }
    }
    return (RootKind.Ok, real);
  }
  private static string Trim(string path) => path.Length > 1 && (path.EndsWith('\\') || path.EndsWith('/')) && Path.GetPathRoot(path) != path ? path.TrimEnd('\\', '/') : path;
  private static bool IsVolumeRoot(string real)
  {
    var root = Path.GetPathRoot(real);
    return root is not null && string.Equals(Trim(root), Trim(real), StringComparison.OrdinalIgnoreCase) || real.Contains("Volume{", StringComparison.OrdinalIgnoreCase);
  }
}

/// The Code page's secret-file kinds (lane K's CodeBackupReader.KindOf / PrivateKey, the Mac's
/// BackendCodeBackupGitReader.secretKind): the same lists, by the file's own name, letter case ignored. JOIN: once lane K
/// is in the same branch, these two members call `TerminalDeck.Core.Code.CodeBackupReader.KindOf` and `.PrivateKey`
/// so there is ONE decision (see the lane's result file).
public static class CodeSecrets
{
  public enum Kind { None, Credential, MaybeKey, LeaveOut }
  private static readonly string[] CredentialPatterns = [".env", ".env.local", ".env.*.local", ".dev.vars", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
    "id_rsa_sk", "id_ecdsa_sk", "id_ed25519_sk", "*.p8", "*.p12", "*.pfx", "*.jks", "*.keystore", ".netrc", "_netrc",
    ".git-credentials", ".pypirc", "credentials", "credentials*.json", ".credentials.json", "service-account*.json",
    "*.tfstate", "*.tfstate.backup", "*.kdbx", ".pgpass", ".htpasswd", ".vault-token", "*.ppk",
    "secret.json", "secrets.json", "secret.yaml", "secrets.yaml", "secret.yml", "secrets.yml", "secret.toml",
    "secrets.toml", "secret.env", "secrets.env", "*.secret.json", "*.secrets.json", "*.secret.yaml",
    "*.secrets.yaml", "*.secret.yml", "*.secrets.yml", "*.secret.toml", "*.secrets.toml"];
  private static readonly string[] CredentialFolders = [".ssh", ".aws", ".gnupg", ".kube"];
  private static readonly string[] KeyPatterns = ["*.pem", "*.key", "*.asc"];
  private static readonly string[] LeaveOutPatterns = ["GoogleService-Info.plist", "google-services.json", ".env.*", "debug.keystore", ".npmrc", ".yarnrc.yml",
    ".envrc", "*.tfvars", "*.tfvars.json", "*.mobileprovision"];
  private static readonly string[] LeaveOutFolders = [".docker", ".azure"];
  private static bool Glob(string pattern, string name)
  {
    pattern = pattern.ToLowerInvariant(); name = name.ToLowerInvariant();
    int p = 0, n = 0, star = -1, mark = 0;
    while (n < name.Length)
    {
      if (p < pattern.Length && (pattern[p] == '?' || pattern[p] == name[n])) { p++; n++; }
      else if (p < pattern.Length && pattern[p] == '*') { star = p++; mark = n; }
      else if (star >= 0) { p = star + 1; n = ++mark; }
      else return false;
    }
    while (p < pattern.Length && pattern[p] == '*') p++;
    return p == pattern.Length;
  }
  public static Kind KindOf(string path)
  {
    var parts = path.ToLowerInvariant().Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
    if (parts.Length == 0) return Kind.None;
    var name = parts[^1]; var folders = parts[..^1];
    bool Matches(IEnumerable<string> patterns) => patterns.Any(p => Glob(p, name));
    if (folders.Any(f => CredentialFolders.Contains(f))) return Kind.Credential;
    if (name == "debug.keystore") return Kind.LeaveOut;
    if (Matches(CredentialPatterns)) return Kind.Credential;
    if (Matches(KeyPatterns)) return Kind.MaybeKey;
    if (Matches(LeaveOutPatterns) || folders.Any(f => LeaveOutFolders.Contains(f))) return Kind.LeaveOut;
    return Kind.None;
  }
  public const int KeyBytes = 256 * 1024;
  public static bool PrivateKey(ReadOnlySpan<byte> data) => Encoding.UTF8.GetString(data[..Math.Min(data.Length, KeyBytes)]).Contains("PRIVATE KEY", StringComparison.Ordinal);
}

/// Whether every computer of the account can take project secret files yet, and if not, the true reason.
public enum CloudProjectSecretFilesGate { Open, WaitingForDevices, CloudMemoryOff }

/// One project secret file, as sealed (byte for byte the Mac's BackendProjectSecretFileValue). `Data` is base64.
public sealed record CloudProjectSecretFileValue(int V, string ProjectId, string Folder, string Path, int Mode, string Data, string Mark, string? Base, long At, string From)
{
  public CloudJson ToJson() => CloudJson.Obj(("v", CloudJson.From(V)), ("projectId", CloudJson.From(ProjectId)), ("folder", CloudJson.From(Folder)),
    ("path", CloudJson.From(Path)), ("mode", CloudJson.From(Mode)), ("data", CloudJson.From(Data)), ("mark", CloudJson.From(Mark)),
    ("base", Base is { } b ? CloudJson.From(b) : null), ("at", CloudJson.From(At)), ("from", CloudJson.From(From)));
  public CloudSecretRecord Record(string recordId) => new(CloudProjectSecretFilesRules.SourceId, recordId, CloudSecretsDomains.Project, ToJson());
  /// Strict, as the Mac decodes it: what is written back must be exactly what arrived (no unknown member, no other form).
  public static CloudProjectSecretFileValue Decode(CloudSecretRecord record)
  {
    if (record.SourceId != CloudProjectSecretFilesRules.SourceId || record.Domain != CloudSecretsDomains.Project || record.RecordId.Length == 0
      || record.Payload is not CloudJson.Object o) throw new CloudFailure("invalid_request");
    var value = new CloudProjectSecretFileValue((int)CloudFields.Integer(o, "v"), CloudFields.Text(o, "projectId"), CloudFields.Text(o, "folder"),
      CloudFields.Text(o, "path"), (int)CloudFields.Integer(o, "mode"), CloudFields.Text(o, "data"), CloudFields.Text(o, "mark"), CloudFields.OptionalText(o, "base"),
      CloudFields.Integer(o, "at"), CloudFields.Text(o, "from"));
    if (!CloudCanonical.Encode(value.ToJson()).AsSpan().SequenceEqual(CloudCanonical.Encode(record.Payload))) throw new CloudFailure("invalid_request");
    return value;
  }
  public byte[]? Bytes()
  {
    try { var bytes = Convert.FromBase64String(Data); return Convert.ToBase64String(bytes) == Data ? bytes : null; }
    catch (FormatException) { return null; }
  }
}

/// The tool's and the pages' view: names, sizes, dates and plain words. Never a secret's content, never an id.
public sealed class CloudProjectSecretFilesStatus
{
  public sealed record File(string Folder, string Path, int Bytes, long? At, string? From, string State, bool Travels);
  public sealed record Project(string Id, string Name, IReadOnlyList<File> Files);
  public List<Project> Projects { get; } = [];
  public bool KeepOnThisPc { get; set; }
  public bool WaitingForDevices { get; set; }
  public string? WaitingWhy { get; set; }
  public int RefusedArrivals { get; set; }
  public long? LookedAt { get; set; }
  public string? BinNotice { get; set; }
}

public static class CloudProjectSecretFilesWords
{
  public const string Travels = "travels with your saved passwords";
  public const string KeepSwitch = "Keep project secret files on this PC only";
  public static string Arrived(string from) => "arrived from " + from;
  public static string Differs(string from) => "different on " + from + ", yours kept";
  public const string WaitingFolder = "waiting for the project's folder on this PC";
  public const string WaitingSetting = "waiting: kept on this PC only is on";
  public const string WaitingBlocked = "waiting: a link or another file is in its place";
  public const string TooLarge = "too large to travel (over 32 KB)";
  public const string TooMany = "not sent: this project has more than 40 secret files or 512 KB";
  public const string KeptHere = "kept on this PC only";
  /// F11: the mark that says "this device takes them" travels with Cloud memory, so the wait names that.
  public const string WaitingDevices = "waits until each of your computers runs the new version with Cloud memory on";
  public const string WaitingMemory = "waits: Cloud memory is off on this PC (turn it on so your computers can agree)";
  public static string? Waiting(CloudProjectSecretFilesGate gate) => gate switch
  {
    CloudProjectSecretFilesGate.Open => null, CloudProjectSecretFilesGate.WaitingForDevices => WaitingDevices, _ => WaitingMemory
  };
  public const string StaysHere = "stays on this PC: it can make a program run";
  public const string RefusedPrograms = "not placed: it can make a program run";
  public const string RefusedCaps = "not placed: this project already has 40 secret files or 512 KB here (or 400 in all)";
  public const string RefusedWaitingFull = "not kept: too many files are already waiting on this PC";
  public const string PutBackPrograms = "not put back: it can make a program run (it stays in the Bin)";
  public const string PutBackCaps = "not put back: this project already has 40 secret files or 512 KB here (or 400 in all)";
  public const string NotRemovedWholeFolder = "not removed here: this project's folder here is your home folder or a whole disk";
  public static string NotRemovedSameName(string folder) => "not removed here: two folders of this project here are both called “" + folder + "” (rename one)";
  public const string BinDamaged = CloudSecretsKeeper.BinDamaged;
  public static string SameName(string folder) => "not sent: two folders of this project are both called “" + folder + "” (rename one)";
  public static string WaitingSameName(string folder) => "waiting: two folders of this project here are both called “" + folder + "” (rename one)";
  public const string WholeFolder = "nothing travels: this project's folder is your home folder or a whole disk";
  public const string WaitingWholeFolder = "waiting: this project's folder here is your home folder or a whole disk";
  public const string KeepSwitchDetail = "Stops sending this PC's project secret files and placing arriving ones here. It does not take back copies your other devices already have.";
  public const string KeepNotSaved = "Could not save this setting, so nothing changed. Try again.";
  /// A file that goes between his devices (sent from here, or arrived from another one): not "not sent to GitHub".
  public static bool Travelling(string state) => state == Travels || state.StartsWith("arrived from ", StringComparison.Ordinal);
  /// The Code page (lane K): the held-back secret files of a project that travel, by path (the Mac's `decorate`).
  /// Several folders: keyed "<folder name>/<path>"; one folder: the path.
  public static IReadOnlyDictionary<string, string> TravellingFiles(CloudProjectSecretFilesStatus? status, string projectId)
  {
    var result = new Dictionary<string, string>(StringComparer.Ordinal);
    if (status?.Projects.FirstOrDefault(p => p.Id == projectId) is not { } known) return result;
    foreach (var file in known.Files.Where(f => f.Travels || f.State.StartsWith("different", StringComparison.Ordinal)))
      result.TryAdd(file.Folder.Length == 0 ? file.Path : file.Folder + "/" + file.Path, file.State);
    return result;
  }
  public static string Date(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(ms).ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
}
