using System.Text;
using TerminalDeck.Core.AiSetup;

namespace TerminalDeck.Core.Tests.AiSetup;

// One setup for every AI (19 Nov 2026): the Windows keeper makes the Mac's bytes. The golden data is the Mac keeper's own
// run on the same fixture (AiSetupGolden.cs), so a Mac and a PC never rewrite each other's files back and forth.
public sealed class AiSetupKeeperTests : IDisposable
{
  private readonly string scratch = Path.Combine(Path.GetTempPath(), "td-ai-setup-" + Guid.NewGuid().ToString("N"));
  private readonly List<string> discarded = [];
  public void Dispose() { try { Directory.Delete(scratch, recursive: true); } catch (DirectoryNotFoundException) { } }

  private string Project => Path.Combine(scratch, "home", "work", "app");
  private string At(string relative) => Path.Combine([Project, .. relative.Split('/')]);
  private void Write(string relative, string text, long at)
  {
    var path = At(relative);
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    File.WriteAllBytes(path, Encoding.UTF8.GetBytes(text));
    File.SetLastWriteTimeUtc(path, DateTimeOffset.FromUnixTimeMilliseconds(at).UtcDateTime);
  }
  private string? Read(string relative) => File.Exists(At(relative)) ? Encoding.UTF8.GetString(File.ReadAllBytes(At(relative))) : null;
  private void Discard(string path)
  {
    var bin = Path.Combine(scratch, "bin", Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(bin);
    var to = Path.Combine(bin, Path.GetFileName(path));
    if (Directory.Exists(path)) Directory.Move(path, to); else File.Move(path, to);
    discarded.Add(Path.GetRelativePath(Project, path).Replace('\\', '/'));
  }
  private IReadOnlyList<string> Align() => AiSetupKeeper.Align(Project, Discard);
  private SortedDictionary<string, string> Snapshot() => new(Directory.EnumerateFiles(Project, "*", SearchOption.AllDirectories)
    .ToDictionary(f => Path.GetRelativePath(Project, f).Replace('\\', '/'), f => Encoding.UTF8.GetString(File.ReadAllBytes(f)), StringComparer.Ordinal), StringComparer.Ordinal);

  [Fact]
  public void The_PC_makes_the_Macs_bytes_from_the_same_project()
  {
    foreach (var (path, text, at) in AiSetupGolden.Fixture) Write(path, text, at);
    var lines = Align();
    Assert.Equal(AiSetupGolden.Lines, lines);
    foreach (var (path, text) in AiSetupGolden.Made) Assert.True(text == Read(path), path + " differs from the Mac's:\n" + Read(path));
    // The person's own files are untouched; CR LF and front-matter-less agents get no copy (as on the Mac).
    Assert.Equal("my own agents file\n", Read("AGENTS.md"));
    Assert.Equal("name = \"mine\"\n", Read(".codex/agents/mine.toml"));
    Assert.Equal("my own gemini reviewer\n", Read(".gemini/agents/reviewer.md"));
    Assert.Null(Read(".codex/agents/crlf.toml"));
    Assert.Null(Read(".codex/agents/nofront.toml"));
    // Skills: the newest copy everywhere; the replaced copy and the retired app agent went to the bin, nothing else.
    Assert.Equal("A new\n", Read(".agents/skills/a/SKILL.md"));
    Assert.Equal("#!/bin/sh\necho\n", Read(".agents/skills/a/scripts/run.sh"));
    Assert.Equal("B\n", Read(".claude/skills/b/SKILL.md"));
    Assert.Null(Read(".claude/skills/c/.terminaldeck-copy"));
    Assert.False(Directory.Exists(At(".agents/skills/notaskill")));
    Assert.False(Directory.Exists(At(".gemini/skills")));
    Assert.Equal(new[] { ".agents/skills/a", ".codex/agents/old.toml" }, discarded.Order(StringComparer.Ordinal));
    // Nothing staged is left behind.
    Assert.DoesNotContain(Snapshot().Keys, k => k.Contains(".terminaldeck-", StringComparison.Ordinal) && !k.EndsWith(AiSetupKeeper.SkillCopyMarker, StringComparison.Ordinal));

    // A second look changes nothing: no line, no write, no bin.
    var before = Snapshot();
    discarded.Clear();
    Assert.Empty(Align());
    Assert.Equal(before, Snapshot());
    Assert.Empty(discarded);
  }

  [Fact]
  public void Files_another_device_made_are_left_as_they_are()
  {
    foreach (var (path, text, at) in AiSetupGolden.Fixture) Write(path, text, at);
    // The Mac's files arrived first (the Cloud wrote them): the PC finds nothing to change in them.
    foreach (var (path, text) in AiSetupGolden.Made) Write(path, text, AiSetupGolden.T2);
    var lines = Align();
    Assert.DoesNotContain(lines, l => l.Contains("made the same for Codex", StringComparison.Ordinal) || l.Contains("made the same for Gemini", StringComparison.Ordinal)
      || l.Contains("guards", StringComparison.Ordinal) || l.Contains("GEMINI.md", StringComparison.Ordinal));
    foreach (var (path, text) in AiSetupGolden.Made) Assert.Equal(text, Read(path));
  }

  [Fact]
  public void A_guard_file_the_same_in_meaning_is_not_rewritten_and_his_own_entries_stay()
  {
    Write("CLAUDE.md", "rules\n", AiSetupGolden.T1);
    Write(".claude/settings.json", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo done\",\"timeout\":5}]}]}}", AiSetupGolden.T1);
    // His Codex file, written by hand in another layout, already holds the same guard plus one of his own.
    var his = "{ \"hooks\": { \"Stop\": [ {\"hooks\": [ {\"type\": \"command\", \"command\": \"mine\"} ]},\n"
      + " {\"hooks\": [{\"command\": \"echo done\", \"statusMessage\": \"Terminal Deck guard\", \"timeout\": 5.0, \"type\": \"command\"}]} ] } }\n";
    Write(".codex/hooks.json", his, AiSetupGolden.T1);
    Align();
    Assert.Equal(his, Read(".codex/hooks.json"));
    // Gemini: made, with the event's own name and milliseconds.
    Assert.Contains("\"AfterAgent\" : [", Read(".gemini/settings.json"));
    Assert.Contains("\"timeout\" : 5000,", Read(".gemini/settings.json"));
    // Claude's guard goes away: only the app's entries leave, his stay.
    Write(".claude/settings.json", "{}", AiSetupGolden.T2);
    Align();
    Assert.Equal("{\n  \"hooks\" : {\n    \"Stop\" : [\n      {\n        \"hooks\" : [\n          {\n            \"command\" : \"mine\",\n            \"type\" : \"command\"\n"
      + "          }\n        ]\n      }\n    ]\n  }\n}\n", Read(".codex/hooks.json"));
    Assert.Equal("{\n\n}\n", Read(".gemini/settings.json"));
  }

  [Fact]
  public void Unreadable_settings_are_left_alone_with_one_line()
  {
    Write("CLAUDE.md", "rules\n", AiSetupGolden.T1);
    Write(".claude/settings.json", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"x\"}]}]}}", AiSetupGolden.T1);
    Write(".gemini/settings.json", "{ // his comment\n \"theme\": \"x\" }\n", AiSetupGolden.T1);
    var lines = Align();
    Assert.Contains("AI setup: .gemini/settings.json is not plain settings; its guards are left as they are.", lines);
    Assert.Equal("{ // his comment\n \"theme\": \"x\" }\n", Read(".gemini/settings.json"));
    Write(".claude/settings.json", "{ not json", AiSetupGolden.T2);
    var before = Snapshot();
    Assert.Contains("AI setup: .claude/settings.json could not be read; the guards of Codex and Gemini are left as they are.", Align());
    Assert.Equal(before, Snapshot());
  }

  [Fact]
  public void A_project_is_the_nearest_folder_with_CLAUDE_md_or_claude_strictly_inside_the_home_folder()
  {
    var home = Path.Combine(scratch, "home");
    Write("CLAUDE.md", "rules\n", AiSetupGolden.T1);
    Directory.CreateDirectory(At("src/deep"));
    Assert.Equal(Project, AiSetupKeeper.ProjectRoot(At("src/deep"), home));
    Assert.Equal(Project, AiSetupKeeper.ProjectRoot(Project, home));
    // A folder of its own below wins.
    Directory.CreateDirectory(At("src/.claude"));
    Assert.Equal(At("src"), AiSetupKeeper.ProjectRoot(At("src/deep"), home));
    // Never the home folder itself, nothing outside it, nothing without a project above.
    File.WriteAllText(Path.Combine(home, "CLAUDE.md"), "home rules\n");
    Directory.CreateDirectory(Path.Combine(home, "loose"));
    Assert.Null(AiSetupKeeper.ProjectRoot(Path.Combine(home, "loose"), home));
    Assert.Null(AiSetupKeeper.ProjectRoot(home, home));
    Assert.Null(AiSetupKeeper.ProjectRoot(Project, Path.Combine(scratch, "elsewhere")));
    Assert.Null(AiSetupKeeper.ProjectRoot("relative/path", home));
  }

  [Fact]
  public void A_rule_file_is_made_only_where_none_is_and_nothing_happens_without_CLAUDE_md()
  {
    Write(".claude/skills/s/SKILL.md", "S\n", AiSetupGolden.T1);
    Align();
    Assert.Null(Read("AGENTS.md"));
    Assert.Null(Read("GEMINI.md"));
    Assert.Equal("S\n", Read(".agents/skills/s/SKILL.md"));
    Write("CLAUDE.md", "rules\n", AiSetupGolden.T1);
    Write("GEMINI.md", "his gemini\n", AiSetupGolden.T1);
    Assert.Equal(["AI setup: AGENTS.md made, pointing to CLAUDE.md."], Align());
    Assert.Equal(AiSetupKeeper.Pointer("AGENTS.md"), Read("AGENTS.md"));
    Assert.Equal("his gemini\n", Read("GEMINI.md"));
  }

  [Fact]
  public void An_app_copy_is_updated_when_the_agent_changes_and_his_edit_marks_it_as_his()
  {
    Write(".claude/agents/r.md", "---\nname: r\ndescription: one\n---\nBody one.\n", AiSetupGolden.T1);
    Align();
    Assert.Contains("description = \"one\"", Read(".codex/agents/r.toml"));
    Write(".claude/agents/r.md", "---\nname: r\ndescription: two\n---\nBody two.\n", AiSetupGolden.T2);
    Assert.Equal(["AI setup: 1 agent made the same for Codex.", "AI setup: 1 agent made the same for Gemini."], Align());
    Assert.Contains("description = \"two\"", Read(".codex/agents/r.toml"));
    // He takes the Codex copy over (the marker is gone): it is his from now on.
    Write(".codex/agents/r.toml", "name = \"r\"\ndeveloper_instructions = \"\"\"\nHis own.\"\"\"\n", AiSetupGolden.T2);
    Write(".claude/agents/r.md", "---\nname: r\ndescription: three\n---\nBody three.\n", AiSetupGolden.T2);
    Align();
    Assert.Equal("name = \"r\"\ndeveloper_instructions = \"\"\"\nHis own.\"\"\"\n", Read(".codex/agents/r.toml"));
    Assert.Contains("description: \"three\"", Read(".gemini/agents/r.md"));
  }

  [Fact]
  public void A_tie_goes_to_claude_skills_and_a_skill_copy_keeps_the_apps_marker()
  {
    Write(".claude/skills/s/SKILL.md", "from claude\n", AiSetupGolden.T1);
    Write(".agents/skills/s/SKILL.md", "from agents\n", AiSetupGolden.T1);
    Write(".agents/skills/s/" + AiSetupKeeper.SkillCopyMarker, "A copy Terminal Deck keeps of s for every AI.\n", AiSetupGolden.T1);
    Write(".gemini/skills/other/SKILL.md", "other\n", AiSetupGolden.T1);
    Align();
    Assert.Equal("from claude\n", Read(".agents/skills/s/SKILL.md"));
    Assert.Equal("A copy Terminal Deck keeps of s for every AI.\n", Read(".agents/skills/s/" + AiSetupKeeper.SkillCopyMarker));
    Assert.Equal("from claude\n", Read(".gemini/skills/s/SKILL.md"));
    Assert.Null(Read(".gemini/skills/s/" + AiSetupKeeper.SkillCopyMarker));
    Assert.Equal("other\n", Read(".claude/skills/other/SKILL.md"));
    Assert.Equal("other\n", Read(".agents/skills/other/SKILL.md"));
  }

  [Fact]
  public void The_JSON_is_written_as_the_Macs_Foundation_writes_it()
  {
    // Foundation's own output for this value (probed on the Mac, 19 Nov 2026).
    var value = SetupJson.Parse(Encoding.UTF8.GetBytes(
      "{\"s\":\"\\b\\f\\r\\u001f\\u007f\\u2028/\",\"a10\":1,\"a2\":2,\"a-b\":3,\"a_b\":4,\"aB\":5,\"ab\":6,\"Ab\":7,\"n\":[1e20,1e-5,123456789012.0,0.5,0.1],\"e\":{},\"l\":[]}"));
    Assert.Equal("{\n  \"a_b\" : 4,\n  \"a-b\" : 3,\n  \"a2\" : 2,\n  \"a10\" : 1,\n  \"ab\" : 6,\n  \"aB\" : 5,\n  \"Ab\" : 7,\n  \"e\" : {\n\n  },\n  \"l\" : [\n\n  ],\n"
      + "  \"n\" : [\n    1e+20,\n    1.0000000000000001e-05,\n    123456789012,\n    0.5,\n    0.10000000000000001\n  ],\n  \"s\" : \"\\b\\f\\r\\u001f\u007f\u2028/\"\n}",
      SetupJson.Pretty(value));
    Assert.True(SetupJson.SameMeaning(SetupJson.Parse("{\"n\":1.0,\"t\":true}"u8.ToArray()), SetupJson.Parse("{\"t\":1,\"n\":1}"u8.ToArray())));
    Assert.False(SetupJson.SameMeaning(SetupJson.Parse("{\"n\":[1,2]}"u8.ToArray()), SetupJson.Parse("{\"n\":[2,1]}"u8.ToArray())));
  }
}
