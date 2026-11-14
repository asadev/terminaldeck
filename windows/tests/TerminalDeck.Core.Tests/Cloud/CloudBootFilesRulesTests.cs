using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// 7C-3: the Mac's boot-file rules, list for list (td-mac-next Tests/TerminalDeckBackendTests/CloudBootFilesRulesTests.swift,
// CloudBootFilesRefusalTests.swift), and the record as the Mac's file engine makes it. The Mac's own tests use random
// version ids, so there is no Swift-made record to compare byte for byte; the ids below are computed outside this code
// (SHA-256 shaped as BackendCloudBrainMemoryHash.operationId / uuid do) and the payload is spelled out in full.
public sealed class CloudBootFilesRulesTests
{
  private static CloudBootFilesRefusal? R(CloudBootFilesPlaceKind kind, string path) => CloudBootFilesFormat.Refusal(kind, path);

  [Fact]
  public void These_are_boot_files()
  {
    var p = CloudBootFilesPlaceKind.Project;
    (CloudBootFilesPlaceKind, string)[] allowed =
    [
      (p, "CLAUDE.md"), (p, "AGENTS.md"), (p, "GEMINI.md"), (p, ".claude/agents/reviewer.md"), (p, ".claude/skills/review/SKILL.md"),
      (p, ".claude/skills/review/scripts/run.sh"), (p, ".claude/commands/ship.md"), (p, ".claude/commands/team/ship.md"), (p, ".agents/skills/x/SKILL.md"),
      (p, ".codex/skills/y/SKILL.md"), (p, ".gemini/skills/z/SKILL.md"), (p, ".claude/skills/café/SKILL.md"),
      (CloudBootFilesPlaceKind.Claude, "CLAUDE.md"), (CloudBootFilesPlaceKind.Claude, "agents/a.md"), (CloudBootFilesPlaceKind.Claude, "skills/s/SKILL.md"),
      (CloudBootFilesPlaceKind.Claude, "commands/c.md"), (CloudBootFilesPlaceKind.Codex, "AGENTS.md"), (CloudBootFilesPlaceKind.Codex, "skills/s/SKILL.md"),
      (CloudBootFilesPlaceKind.Gemini, "GEMINI.md"), (CloudBootFilesPlaceKind.Gemini, "skills/s/SKILL.md"), (CloudBootFilesPlaceKind.Agents, "skills/s/SKILL.md")
    ];
    foreach (var (kind, path) in allowed) Assert.True(R(kind, path) is null, kind + " " + path);
  }

  [Fact]
  public void Nothing_else_is_a_boot_file()
  {
    var p = CloudBootFilesPlaceKind.Project;
    var c = CloudBootFilesPlaceKind.Claude;
    var x = CloudBootFilesPlaceKind.Codex;
    var g = CloudBootFilesPlaceKind.Gemini;
    var notListed = CloudBootFilesRefusal.NotListed;
    var never = CloudBootFilesRefusal.Never;
    var hidden = CloudBootFilesRefusal.Hidden;
    var path = CloudBootFilesRefusal.Path;
    (CloudBootFilesPlaceKind, string, CloudBootFilesRefusal)[] refused =
    [
      (p, "claude.md", notListed), (p, "src/CLAUDE.md", notListed), (p, "README.md", notListed), (p, ".claude/settings.json", notListed),
      (p, ".claude/settings.local.json", notListed), (p, ".mcp.json", notListed), (p, ".Claude/skills/x/SKILL.md", notListed), (p, ".claude/skills", notListed),
      (p, ".claude/agent-memory/r/MEMORY.md", notListed), (x, "CLAUDE.md", notListed),
      (c, "projects/-Users-x-app/memory/MEMORY.md", notListed), (c, "projects/-Users-x-app/chat.jsonl", notListed), (c, "settings.json", notListed),
      (c, ".credentials.json", notListed), (c, "history.jsonl", notListed), (x, "memories/m.md", notListed), (x, "sessions/2026/s.jsonl", notListed),
      (x, "auth.json", notListed), (x, "config.toml", notListed), (g, "tmp/abc/chats/session-1.json", notListed), (g, "settings.json", notListed),
      (g, "oauth_creds.json", notListed),
      (p, ".claude/skills/x/settings.json", never), (p, ".claude/skills/x/Settings.JSON", never), (p, ".claude/skills/x/settings.local.json", never),
      (p, ".claude/skills/x/hooks/pre.sh", never), (p, ".claude/agents/hooks.json", never), (p, ".claude/skills/x/mcp.json", never),
      (p, ".claude/skills/x/config.toml", never), (p, ".claude/skills/x/server.pem", never), (p, ".claude/skills/x/aws-credentials.md", never),
      (p, ".claude/skills/x/id_rsa", never), (p, ".claude/skills/x/run.lock", never), (p, ".claude/skills/x/auth.json", never),
      (p, ".claude/skills/x/.env", hidden), (p, ".claude/skills/x/.mcp.json", hidden), (x, "skills/.system/own/SKILL.md", hidden),
      (p, ".claude/skills/x/.terminaldeck-copy", hidden), (p, ".claude/skills/x/node_modules/p/readme.md", CloudBootFilesRefusal.Rebuildable),
      (p, ".claude/skills/../../outside.md", path), (p, "../outside.md", path), (p, "/etc/passwd", path), (p, ".claude/skills//x.md", path),
      (p, ".claude/skills/x/./y.md", path), (p, ".claude\\skills\\x.md", path), (p, ".claude/skills/x/a\0b.md", path), (p, ".claude/skills/x/a‮b.md", path),
      (p, ".claude/skills/x/a\nb.md", path), (p, ".claude/skills/café/SKILL.md", path), (p, ".claude/skills/́x/SKILL.md", path), (p, "", path),
      (p, ".claude/skills/x/", path)
    ];
    foreach (var (kind, file, why) in refused) Assert.True(R(kind, file) == why, kind + " " + file + " gave " + R(kind, file));
  }

  [Fact]
  public void Common_secret_file_names_never_travel_whatever_their_case()
  {
    foreach (var name in new[] { "token.json", "Token.JSON", "secrets.yaml", "secrets.yml", "SECRETS.json", "prod.env", "staging.ENV", "prod.env.local",
      "apikey.txt", "api_key.md", "api-key.txt", "service-account-prod.json", "service_account.json", "password.txt", "server.pem", "tls.KEY", "AuthKey_X.p8",
      "release.jks", "a.keystore", "putty.ppk", "id_rsa", "id_ed25519.pub", "ID_ECDSA", "id_custom", "my-private-key.md", "github-token.md" })
      Assert.True(R(CloudBootFilesPlaceKind.Project, ".claude/skills/x/" + name) == CloudBootFilesRefusal.Never, name);
    foreach (var name in new[] { "SKILL.md", "reference.md", "env-setup.md", "keys-and-values.md", "identity.md" })
      Assert.True(R(CloudBootFilesPlaceKind.Project, ".claude/skills/x/" + name) is null, name);
  }

  [Fact]
  public void Only_text_is_a_boot_file_and_paths_split_at_slashes()
  {
    Assert.True(CloudBootFilesFormat.IsText(Encoding.UTF8.GetBytes("plain é\n")));
    Assert.True(CloudBootFilesFormat.IsText([]));
    Assert.False(CloudBootFilesFormat.IsText([0x41, 0x00, 0x42]));
    Assert.False(CloudBootFilesFormat.IsText([0xff, 0xfe, 0x41]));
    Assert.Null(CloudBootFilesFormat.Parts("a/́b"));
    Assert.Equal(new[] { "a", "b", "c" }, CloudBootFilesFormat.Parts("a/b/c")!);
  }

  [Fact]
  public void The_one_rule_rule_J_first_then_the_later_time_then_the_device()
  {
    const long now = 1_000_000;
    Assert.Equal(500L, CloudBootFilesFormat.Clamp(500, null, now));
    Assert.Equal(now, CloudBootFilesFormat.Clamp(2_000_000, null, now));
    Assert.Equal(700L, CloudBootFilesFormat.Clamp(500, 700, now));
    Assert.Equal(now, CloudBootFilesFormat.Clamp(500, 5_000_000, now));
    // A first saved copy loses, even when it is newer.
    Assert.Equal(CloudBootFilesNewest.Arrived, CloudBootFilesFormat.Newest(new(900, "b", FirstCopy: true), new(100, "a"), now));
    Assert.Equal(CloudBootFilesNewest.Local, CloudBootFilesFormat.Newest(new(100, "a"), new(900, "b", FirstCopy: true), now));
    Assert.Equal(CloudBootFilesNewest.Local, CloudBootFilesFormat.Newest(new(900, "a"), new(100, "b"), now));
    // A clock that runs ahead does not win: both are capped at now, then the larger device id.
    Assert.Equal(CloudBootFilesNewest.Local, CloudBootFilesFormat.Newest(new(now, "b"), new(9_000_000, "a"), now));
    Assert.Equal(CloudBootFilesNewest.Arrived, CloudBootFilesFormat.Newest(new(now, "a"), new(now, "b"), now));
  }

  [Fact]
  public void What_can_run_a_command_waits()
  {
    static IReadOnlyList<string> Runs(string path, string text) => CloudBootFilesFormat.RunReasons(path, Encoding.UTF8.GetBytes(text));
    Assert.Empty(Runs("CLAUDE.md", "Use tabs.\nSee @docs/style.md\n"));
    Assert.Equal(new[] { "import:~/.ssh/config" }, Runs("CLAUDE.md", "Read @~/.ssh/config first\n"));
    Assert.Equal(new[] { "import:../outside.md" }, Runs("GEMINI.md", "@../outside.md\n"));
    Assert.Empty(Runs(".claude/skills/r/SKILL.md", "---\nname: review\ndescription: \"Reviews code\"\n---\nBody\n"));
    Assert.Equal(new[] { "header:allowed-tools" }, Runs(".claude/agents/a.md", "---\nname: a\nallowed-tools: Bash\n---\nBody\n"));
    Assert.Equal(new[] { "header:hooks", CloudBootFilesFormat.UnclearHeader }, Runs(".claude/agents/a.md", "---\nhooks: {x: 1}\n---\n"));
    Assert.Equal(new[] { "script-or-settings", "script" }, Runs(".claude/skills/r/run.sh", "#!/bin/sh\necho hi\n"));
    Assert.Equal(new[] { "inline-command" }, Runs(".claude/commands/c.md", "Status: !`git status`\n"));
  }

  private const string StoreA = "2b7e1516-28ae-4d2a-a6d2-abf7158809cf", MacA = "e3c75f30-363e-4323-a592-cf07fe14c4a6";
  private const string Version = "11111111-2222-4333-8444-555555555555";

  [Fact]
  public void A_record_is_the_Macs_record_byte_for_byte()
  {
    Assert.Equal("7031", CloudBootFilesFormat.Token("p1"));
    Assert.Equal("p1", CloudBootFilesFormat.Untoken("7031"));
    Assert.Equal("project/7031", CloudBootFilesFormat.SourceId(CloudBootFilesPlaceKind.Project, "p1"));
    Assert.Equal("home/claude/73797374656d", CloudBootFilesFormat.SourceId(CloudBootFilesPlaceKind.Claude, "system"));
    Assert.StartsWith("h", CloudBootFilesFormat.Token(new string('x', 41)));
    const string key = "file/project/7031/CLAUDE.md";
    var op = Assert.Single(CloudBootFilesFormat.Records(StoreA, key, "project/7031", Version, [], Encoding.UTF8.GetBytes("rules\n"), MacA, 1_763_000_000_000, "p1", "primary"));
    const string hash = "a73e36ec19ff2a725608408e2b396eadd2ac6046cfa31e010f8d62daab565165";
    Assert.Equal("3582aa76-70a7-4e32-bd56-97daa052a213", op.OpId);
    Assert.Equal(op.OpId, op.Revision);
    Assert.Equal("5cab0792-91de-5664-a5ad-35d1db555ec8", op.EntityId);
    Assert.Equal("brain/files/i09", op.Domain);
    Assert.Equal("put", op.Kind);
    Assert.Equal("p1", op.ProjectId);
    Assert.Equal("primary", op.RootId);
    Assert.Equal(new CloudSourceReference("files/I09/project/7031", key, 0, hash), op.Source);
    // No `stamp`, no `baseline`: the Mac's file engine accepts exactly these keys.
    Assert.Equal("{\"bytes\":\"6\",\"count\":1,\"data\":\"cnVsZXMK\",\"format\":\"td-memory-part-1\",\"index\":0,\"inventoryRow\":\"I09\",\"key\":\"" + key
      + "\",\"parents\":[],\"resourceHash\":\"" + hash + "\",\"storeId\":\"" + StoreA + "\",\"version\":\"" + Version + "\"}",
      Encoding.UTF8.GetString(CloudCanonical.Encode(op.Payload)));
    var described = CloudBootFilesFormat.Describe(op);
    Assert.Equal("project/7031", described.SourceId);
    Assert.Equal("CLAUDE.md", described.Relative);
    // A part with a parent names the parent's part as its own parent.
    var child = CloudBootFilesFormat.Records(StoreA, key, "project/7031", "21111111-2222-4333-8444-555555555555", [Version], Encoding.UTF8.GetBytes("more\n"), MacA, 1, "p1", "primary")[0];
    Assert.Equal(new[] { op.OpId }, child.Parents);
    // Large files travel in parts of 32 KiB.
    Assert.Equal(3, CloudBootFilesFormat.Records(StoreA, key, "project/7031", Version, [], new byte[70_000].Select(_ => (byte)'a').ToArray(), MacA, 1, "p1", "primary").Count);
  }

  [Fact]
  public void A_record_that_is_not_a_boot_file_is_refused()
  {
    const string project = "file/project/7031/";
    foreach (var key in new[] { project + ".claude/skills/../../../outside.md", project + "../outside.md", project + ".claude/skills/x/..",
      project + ".claude/settings.json", project + ".claude/settings.local.json", project + ".mcp.json", project + ".claude/skills/review/settings.json",
      project + ".claude/skills/review/hooks/pre.md", project + ".claude/agents/hooks.json", project + ".claude/skills/review/mcp.json",
      project + ".claude/skills/review/auth.json", project + ".claude/skills/review/.env", project + ".claude/skills/review/.credentials.json",
      "file/home/claude/73797374656d/projects/-Users-x-app/memory/MEMORY.md", "file/home/claude/73797374656d/.credentials.json",
      "file/home/claude/73797374656d/settings.json", "file/idle/idle", "file/project/NOT-A-TOKEN/CLAUDE.md", "notes/x.md", "file/home/project/78/CLAUDE.md" })
    {
      var op = CloudBootFilesFormat.Records(StoreA, key, "project/7031", Version, [], Encoding.UTF8.GetBytes("planted\n"), MacA, 1, "p1", "primary")[0];
      Assert.Equal("invalid_request", Assert.Throws<CloudFailure>(() => CloudBootFilesFormat.Describe(op)).Code);
    }
    // Binary bytes, a payload with a field the Mac does not know, and a record of another row are refused too.
    var binary = CloudBootFilesFormat.Records(StoreA, project + "CLAUDE.md", "project/7031", Version, [], [0x41, 0, 0x42], MacA, 1, "p1", "primary")[0];
    Assert.Throws<CloudFailure>(() => CloudBootFilesFormat.Describe(binary));
    var good = CloudBootFilesFormat.Records(StoreA, project + "CLAUDE.md", "project/7031", Version, [], Encoding.UTF8.GetBytes("x\n"), MacA, 1, "p1", "primary")[0];
    var stamped = ((CloudJson.Object)good.Payload).Members.Append(KeyValuePair.Create("stamp", CloudJson.From("5"))).ToArray();
    var extra = good with { Payload = new CloudJson.Object(stamped), PayloadHash = CloudOperation.PayloadHashOf(new CloudJson.Object(stamped)) };
    Assert.Throws<CloudFailure>(() => CloudBootFilesFormat.Describe(extra));
    Assert.Throws<CloudFailure>(() => CloudBootFilesFormat.Describe(good with { Domain = "brain/files/i08" }));
  }

  [Fact]
  public void A_file_is_written_only_over_the_bytes_expected_and_only_where_nothing_is()
  {
    var root = Path.Combine(Path.GetTempPath(), "td-7c3-disk-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(root);
    try
    {
      File.WriteAllText(Path.Combine(root, "CLAUDE.md"), "edited here");
      var wrong = CloudMemoryFormat.Hash(Encoding.UTF8.GetBytes("what this PC last saw"));
      Assert.Equal("changed", Assert.Throws<CloudBootFilesDisk.Stop>(() => CloudBootFilesDisk.Replace(root, "CLAUDE.md", Encoding.UTF8.GetBytes("from Cloud"), wrong)).Reason);
      Assert.Equal("edited here", File.ReadAllText(Path.Combine(root, "CLAUDE.md")));
      Assert.Equal("changed", Assert.Throws<CloudBootFilesDisk.Stop>(() => CloudBootFilesDisk.Create(root, "CLAUDE.md", Encoding.UTF8.GetBytes("from Cloud"))).Reason);
      Assert.Equal("edited here", File.ReadAllText(Path.Combine(root, "CLAUDE.md")));
      var right = CloudMemoryFormat.Hash(Encoding.UTF8.GetBytes("edited here"));
      Assert.Equal("edited here", Encoding.UTF8.GetString(CloudBootFilesDisk.Replace(root, "CLAUDE.md", Encoding.UTF8.GetBytes("from Cloud"), right)));
      Assert.Equal("from Cloud", File.ReadAllText(Path.Combine(root, "CLAUDE.md")));
      CloudBootFilesDisk.Create(root, ".claude/commands/new.md", Encoding.UTF8.GetBytes("new"));
      Assert.Equal("new", File.ReadAllText(Path.Combine(root, ".claude", "commands", "new.md")));
      // A name that differs only in letter case from one already there stops the write.
      Assert.Equal("twin", Assert.Throws<CloudBootFilesDisk.Stop>(() => CloudBootFilesDisk.Create(root, ".claude/commands/NEW.md", Encoding.UTF8.GetBytes("x"))).Reason);
      // Nothing of the staging is left behind.
      Assert.DoesNotContain(Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories), f => Path.GetFileName(f).StartsWith(".td-cloud-", StringComparison.Ordinal));
    }
    finally { Directory.Delete(root, recursive: true); }
  }
}
