using System.Text.Json;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// The AI delete witness, case for case from the Mac's BackendAIDeleteWitnessTests.swift and DeleteWitnessTests.swift
// (td-mac-next2): real-shaped hook payloads for Claude Code, Codex and Gemini, the time-overlap rule, the link rule (J-2),
// a hand delete during an unrelated AI command, a restart mid-command, a background command, denied commands. Plus the
// Windows words (PowerShell and cmd removals, scripts). The Mac's `claude mcp remove` stand-in path is not ported (the MCP
// servers that travel are lane S's).
public sealed class CloudDeleteWitnessTests : IDisposable
{
  private const string Home = "/Users/a", Project = "/Users/a/Projects/site";
  private static readonly DateTimeOffset T0 = DateTimeOffset.FromUnixTimeSeconds(1_794_000_000);
  private static readonly CloudWitnessSession Row = new("site", "Builder");
  private readonly string scratch = Path.Combine(Path.GetTempPath(), "td-witness-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(scratch, recursive: true); } catch (DirectoryNotFoundException) { } }

  private static DateTimeOffset At(double s) => T0.AddMilliseconds(s * 1000);
  private static CloudAiDeleteWitness Witness(string? dir = null, double start = -600) => new(dir, Home, At(start));
  private static JsonElement J(object value) => JsonSerializer.SerializeToElement(value);
  private static CloudHookToolEvent Claude(string name, object input, string tool = "Bash", string id = "toolu_01", double at = 0) =>
    new("claude", name, "td-1", tool, J(input), Project, id, null, At(at));
  private static CloudAiDeleteWitness.Verdict V(CloudAiDeleteWitness w, string path, double from, double to, double now = 1_000) =>
    w.Assessment(path, At(from), At(to), At(now)).Verdict;
  private static bool Ai(CloudAiDeleteWitness w, string path, double from, double to, double now = 1_000) => V(w, path, from, to, now) == CloudAiDeleteWitness.Verdict.ByAi;
  private const CloudAiDeleteWitness.Verdict ByHand = CloudAiDeleteWitness.Verdict.ByHand, CannotKnow = CloudAiDeleteWitness.Verdict.CannotKnow;
  private static List<CloudAiDeleteWitness.Cover> Covers(string command, bool powershell = false) => CloudAiDeleteWitness.ShellCovers(command, Project, Home, 0, powershell).Covers;
  private static CloudAiDeleteWitness.Cover P(string value, bool subtree = false) => new(CloudAiDeleteWitness.CoverKind.Path, value, subtree);

  [Fact]
  public async Task Maps_AI_with_names_and_command_start_and_one_command_has_one_group()
  {
    var w = Witness();
    w.Accept(Claude("PreToolUse", new { command = "rm -rf build" }), Row);
    w.Accept(Claude("PostToolUse", new { command = "rm -rf build" }, at: 1), Row);
    var (verdict, window) = w.Assessment(Project + "/build/app.js", At(-5), At(3), At(1_000));
    Assert.Equal(CloudAiDeleteWitness.Verdict.ByAi, verdict);
    Assert.Equal(("td-1", "Builder", At(0)), (window!.Session, window.AgentName, DateTimeOffset.FromUnixTimeMilliseconds((long)(window.Start * 1000))));
    Assert.True(Ai(w, Project + "/build", -5, 3));
    Assert.Equal(ByHand, V(w, Project + "/src/app.js", -5, 3));
    var a = w.Assessment(Project + "/build/a", At(-5), At(3), At(1_000)).Window!;
    var b = w.Assessment(Project + "/build/b", At(-5), At(3), At(1_000)).Window!;
    Assert.Equal(a.Group, b.Group);
    Assert.True(CloudDeleteText.IsUuid(a.Group));
    // The next command (same text) gets another group.
    w.Accept(Claude("PreToolUse", new { command = "rm -rf build" }, id: "toolu_02", at: 100), Row);
    Assert.NotEqual(a.Group, w.Assessment(Project + "/build/a", At(99), At(101), At(1_000)).Window!.Group);
    _ = await Task.FromResult(0);
  }

  [Fact]
  public async Task The_answer_names_session_and_seat_and_never_the_session_id()
  {
    var w = new CloudAiDeleteWitness(null, Home, DateTimeOffset.UtcNow.AddMinutes(-10));
    var now = DateTimeOffset.UtcNow;
    w.Accept(Claude("PreToolUse", new { command = "rm notes.md" }) with { At = now.AddSeconds(-2) }, Row);
    var answer = await w.WhoAsync(Project + "/notes.md", now.AddSeconds(-3), now);
    Assert.Equal((CloudDeleteWitnessAnswer.Kinds.Ai, "site", "Builder"), (answer.Kind, answer.Session, answer.Agent));
    // The app's own name is not a seat; no title = cannot know (never the routing id).
    var plain = new CloudAiDeleteWitness(null, Home, DateTimeOffset.UtcNow.AddMinutes(-10));
    plain.Accept(Claude("PreToolUse", new { command = "rm notes.md" }) with { At = now.AddSeconds(-2) }, new CloudWitnessSession("site", "Claude Code"));
    Assert.Null((await plain.WhoAsync(Project + "/notes.md", now.AddSeconds(-3), now)).Agent);
    var nameless = new CloudAiDeleteWitness(null, Home, DateTimeOffset.UtcNow.AddMinutes(-10));
    nameless.Accept(Claude("PreToolUse", new { command = "rm notes.md" }) with { At = now.AddSeconds(-2) }, null);
    Assert.Equal(CloudDeleteWitnessAnswer.CannotKnow, await nameless.WhoAsync(Project + "/notes.md", now.AddSeconds(-3), now));
    Assert.Equal(CloudDeleteWitnessAnswer.NotAi, await w.WhoAsync(Project + "/other.md", now.AddSeconds(-3), now));
    Assert.Equal(CloudDeleteWitnessAnswer.CannotKnow, await w.WhoAsync("notes.md", now.AddSeconds(-3), now));
  }

  [Fact]
  public void Codex_argv_command_with_cd_and_tool_use_id()
  {
    var w = Witness();
    var input = new { command = new[] { "bash", "-lc", "cd src && rm old.txt" } };
    w.Accept(new("codex", "PreToolUse", "td-1", "Bash", J(input), Project, "call_7", null, At(0)), null);
    w.Accept(new("codex", "PostToolUse", "td-1", "Bash", J(input), Project, "call_7", null, At(2)), null);
    var found = w.Assessment(Project + "/src/old.txt", At(1), At(4), At(1_000));
    Assert.Equal((CloudAiDeleteWitness.Verdict.ByAi, "Codex"), (found.Verdict, found.Window!.AgentName));
    Assert.Equal(ByHand, V(w, Project + "/src/other.txt", 1, 4));
    Assert.Equal(ByHand, V(w, Project + "/old.txt", 1, 4));
  }

  [Fact]
  public void Gemini_glob_in_directory_pairs_without_id()
  {
    var w = Witness();
    var input = J(new { command = "rm *.log", dir_path = "logs", description = "tidy" });
    w.Accept(new("gemini", "BeforeTool", "td-1", "run_shell_command", input, Project, null, null, At(0)), Row);
    w.Accept(new("gemini", "AfterTool", "td-1", "run_shell_command", input, Project, null, null, At(1)), Row);
    Assert.True(Ai(w, Project + "/logs/a.log", 0, 2));
    Assert.Equal(ByHand, V(w, Project + "/logs/a.txt", 0, 2));
    Assert.Equal(ByHand, V(w, Project + "/logs/old/b.log", 0, 2));
  }

  [Fact]
  public void Patch_delete_and_move_name_the_exact_path_and_a_real_delete_tool_counts()
  {
    var w = Witness();
    var patch = "*** Begin Patch\n*** Delete File: docs/old.md\n*** Update File: a.txt\n*** Move to: b.txt\n@@\n-x\n+y\n*** End Patch";
    var input = J(new { command = patch });
    w.Accept(new("codex", "PreToolUse", "td-1", "apply_patch", input, Project, "call_p", null, At(10)), null);
    w.Accept(new("codex", "PostToolUse", "td-1", "apply_patch", input, Project, "call_p", null, At(10.5)), null);
    Assert.True(Ai(w, Project + "/docs/old.md", 9, 11));
    Assert.True(Ai(w, Project + "/a.txt", 9, 11));
    Assert.Equal(ByHand, V(w, Project + "/b.txt", 9, 11));
    w.Accept(Claude("PreToolUse", new { path = Project + "/old.md" }, tool: "mcp__files__delete_file", id: "toolu_d", at: 20), Row);
    w.Accept(Claude("PostToolUse", new { path = Project + "/old.md" }, tool: "mcp__files__delete_file", id: "toolu_d", at: 20.3), Row);
    Assert.True(Ai(w, Project + "/old.md", 19, 21));
  }

  [Fact]
  public void Overlap_needs_the_span_within_two_seconds()
  {
    var w = Witness();
    w.Accept(Claude("PreToolUse", new { command = "rm notes.md" }, at: 100), Row);
    w.Accept(Claude("PostToolUse", new { command = "rm notes.md" }, at: 101), Row);
    var path = Project + "/notes.md";
    Assert.True(Ai(w, path, 90, 98.5));
    Assert.Equal(ByHand, V(w, path, 90, 97));
    Assert.True(Ai(w, path, 102.5, 110));
    Assert.Equal(ByHand, V(w, path, 104, 110));
  }

  [Fact]
  public void A_hand_delete_during_an_unrelated_AI_command_is_by_hand()
  {
    var w = Witness();
    w.Accept(Claude("PreToolUse", new { command = "rm -rf /Users/a/Other/tmp && npm test" }), Row);
    w.Accept(Claude("PreToolUse", new { command = "ls -la && cat notes.md" }, id: "toolu_02"), Row);
    Assert.Equal(ByHand, V(w, Project + "/notes.md", 1, 5));
    Assert.True(Ai(w, "/Users/a/Other/tmp/x", 1, 5));
  }

  [Fact]
  public void Hidden_targets_fall_back_to_the_working_folder_only_for_plain_removals()
  {
    var w = Witness();
    w.Accept(Claude("PreToolUse", new { command = "rm -rf \"$DIR\"" }), Row);
    Assert.True(Ai(w, Project + "/dist/a.js", 0, 1));
    Assert.Equal(ByHand, V(w, "/Users/a/Elsewhere/a.js", 0, 1));
    var other = Witness();
    other.Accept(Claude("PreToolUse", new { command = "git clean -n" }), Row);
    other.Accept(Claude("PreToolUse", new { command = "cd \"$DIR\" && rm -rf *" }, id: "toolu_04"), Row);
    Assert.Equal(ByHand, V(other, Project + "/dist/a.js", 0, 1));
    foreach (var command in new[] { "xargs rm", "cat list.txt | xargs rm -rf", "$(printf rm) \"$DIR\"", "\"$COMMAND\" \"$DIR\"", "rimraf \"$DIR\"", "npx rimraf \"$DIR\"",
      "rsync --delete source/ \"$DIR\"" })
    {
      var x = Witness();
      x.Accept(Claude("PreToolUse", new { command }), Row);
      Assert.Equal(ByHand, V(x, Project + "/CLAUDE.md", 0, 1));
    }
    foreach (var command in new[] { "unlink \"$FILE\"", "trash \"$FILE\"", "find \"$DIR\" -delete", "mv \"$FILE\" /tmp/out" })
    {
      var x = Witness();
      x.Accept(Claude("PreToolUse", new { command }), Row);
      Assert.True(Ai(x, Project + "/notes/a.md", 0, 1), command);
    }
  }

  [Fact]
  public void Link_reading_cases()
  {
    Assert.Equal([P(Project + "/a.txt", true)], Covers("mv a.txt b.txt"));
    Assert.Empty(Covers("git rm --cached a.txt"));
    Assert.Equal([P(Project + "/notes/a.md")], Covers("xargs rm notes/a.md"));
    Assert.Equal([P(Project + "/notes", true)], Covers("npx rimraf notes"));
    Assert.Empty(Covers("echo rm -rf build"));
    Assert.Equal([P(Project + "/my file.txt")], Covers("rm -f 'my file.txt' > /dev/null 2>&1"));
    Assert.Equal([P(Project, true) with { Name = "*.tmp" }], Covers("find . -name '*.tmp' -delete"));
    Assert.Equal([P(Project, true)], Covers("find . -delete"));
    Assert.Equal([P(Home + "/x.txt")], Covers("sudo rm ~/x.txt"));
    Assert.Equal([P(Project + "/cache", true)], Covers("bash -c 'rm -r cache'"));
    Assert.Empty(Covers("make clean"));
    Assert.Empty(Covers("python3 -c \"import shutil; shutil.rmtree('x')\""));
    Assert.Equal([new CloudAiDeleteWitness.Cover(CloudAiDeleteWitness.CoverKind.Folder, Project, true)], Covers("rm $(cat list.txt)"));
    Assert.Empty(Covers("cat a.txt | grep x"));
  }

  [Fact]
  public void Git_build_and_clean_removals_are_by_hand_and_scripts_cannot_be_known()
  {
    foreach (var command in new[] { "git checkout other-branch", "git checkout -- CLAUDE.md", "git clean -fdx", "git switch other", "git reset --hard", "git stash",
      "git rebase main", "git pull", "git merge main", "git restore CLAUDE.md", "git worktree remove ../other", "git rm CLAUDE.md", "git -C /Users/a/Other clean -fdx",
      "make clean", "npm run clean", "npm run build", "yarn clean", "pnpm run build", "bun run clean", "cargo clean", "gradle clean", "./gradlew build", "xcodebuild clean",
      "swift build", "swift package clean", "swift build --build-path output.swift", "dotnet clean", "msbuild /t:Clean" })
    {
      var w = Witness();
      w.Accept(Claude("PreToolUse", new { command }), Row);
      Assert.Equal(ByHand, V(w, Project + "/CLAUDE.md", 0, 1));
      Assert.Equal(ByHand, V(w, "/Users/a/Other/CLAUDE.md", 0, 1));
    }
    foreach (var command in new[] { "python3 -c \"import os; os.remove('CLAUDE.md')\"", "node -e \"require('fs').unlinkSync('CLAUDE.md')\"", "ruby -e \"File.delete('CLAUDE.md')\"",
      "python cleanup.py", "node cleanup.js", "bash cleanup.sh", "./cleanup.sh", "./cleanup", "/Users/a/bin/cleanup", "swift cleanup.swift", "swift -O cleanup.swift",
      "powershell -File cleanup.ps1", "cleanup.bat", "cmd /c \"del %TEMP%\\x\"" })
    {
      var w = Witness();
      w.Accept(Claude("PreToolUse", new { command }), Row);
      Assert.Equal(CannotKnow, V(w, Project + "/CLAUDE.md", 0, 1));
      Assert.Equal(CannotKnow, V(w, "/Users/a/Other/CLAUDE.md", 0, 1));
    }
  }

  [Fact]
  public void Scripts_supply_no_link_but_named_removals_still_count()
  {
    var w = Witness();
    w.Accept(Claude("PreToolUse", new { command = "rm notes/a.md" }), Row);
    w.Accept(Claude("PreToolUse", new { command = "python3 cleanup.py" }, id: "script"), Row);
    Assert.True(Ai(w, Project + "/notes/a.md", 0, 1));
    Assert.Equal(CannotKnow, V(w, Project + "/notes/b.md", 0, 1));
    var hidden = Witness();
    hidden.Accept(Claude("PreToolUse", new { command = "rm -rf \"$DIR\" && python3 cleanup.py" }), Row);
    Assert.Equal(CannotKnow, V(hidden, Project + "/notes/a.md", 0, 1));
  }

  [Fact]
  public void A_restart_mid_command_keeps_the_start_and_never_the_command_text()
  {
    var before = Witness(scratch);
    before.Accept(Claude("PreToolUse", new { command = "rm -rf build && echo TOKEN-sk-123" }), Row);
    var saved = File.ReadAllText(Path.Combine(scratch, CloudAiDeleteWitness.FileName));
    Assert.DoesNotContain("TOKEN-sk-123", saved);
    Assert.DoesNotContain("echo", saved);
    var after = Witness(scratch, start: 30);
    after.Accept(Claude("PostToolUse", new { command = "rm -rf build && echo TOKEN-sk-123" }, at: 40), Row);
    var found = after.Assessment(Project + "/build/x", At(5), At(35), At(1_000));
    Assert.Equal((CloudAiDeleteWitness.Verdict.ByAi, 0d), (found.Verdict, found.Window!.Start - At(0).ToUnixTimeMilliseconds() / 1000.0));
    Assert.Equal(CannotKnow, V(after, Project + "/src/x", 5, 35));
    Assert.Equal(ByHand, V(after, Project + "/src/x", 50, 60));
  }

  [Fact]
  public void A_background_command_outlives_its_tool_call_and_an_open_window_is_capped()
  {
    var w = Witness();
    var input = new { command = "rm -rf node_modules", run_in_background = true };
    w.Accept(Claude("PreToolUse", input), Row);
    w.Accept(Claude("PostToolUse", input, at: 0.1), Row);
    w.Accept(Claude("Stop", new { }, at: 5), Row);
    Assert.True(Ai(w, Project + "/node_modules/x/index.js", 50, 60));
    w.Accept(Claude("SessionEnd", new { }, at: 120), Row);
    Assert.Equal(ByHand, V(w, Project + "/node_modules/y/index.js", 200, 300));
    var fg = Witness();
    fg.Accept(Claude("PreToolUse", new { command = "rm -rf node_modules" }), Row);
    fg.Accept(Claude("PostToolUse", new { command = "rm -rf node_modules" }, at: 1), Row);
    Assert.Equal(ByHand, V(fg, Project + "/node_modules/x/index.js", 50, 60));
    Assert.True(CloudAiDeleteWitness.ShellCovers("nohup rm -rf big &", Project, Home, 0).Background);
    var open = Witness();
    open.Accept(Claude("PreToolUse", new { command = "rm -r out" }), Row);
    Assert.True(Ai(open, Project + "/out/a", 600, 700, now: 800));
    Assert.Equal(ByHand, V(open, Project + "/out/a", 4000, 4100, now: 5000));
    open.SessionEnded("td-1", At(10));
    Assert.Equal(ByHand, V(open, Project + "/out/a", 600, 700, now: 800));
  }

  [Fact]
  public void Write_or_edit_then_a_hand_delete_is_by_hand()
  {
    foreach (var (provider, tool) in new[] { ("claude", "Write"), ("claude", "Edit"), ("claude", "MultiEdit"), ("claude", "NotebookEdit"), ("gemini", "write_file"),
      ("gemini", "replace"), ("codex", "edit_file"), ("codex", "create_file") })
    {
      var w = Witness();
      var input = J(new { file_path = Project + "/notes/a.md", path = Project + "/notes/a.md", content = "x" });
      w.Accept(new(provider, provider == "gemini" ? "BeforeTool" : "PreToolUse", "td-1", tool, input, Project, "t1", null, At(0)), Row);
      w.Accept(new(provider, provider == "gemini" ? "AfterTool" : "PostToolUse", "td-1", tool, input, Project, "t1", null, At(0.5)), Row);
      Assert.Equal(ByHand, V(w, Project + "/notes/a.md", -1, 61));
      Assert.Null(CloudAiDeleteWitness.Reading(tool, input, Project, Home));
    }
  }

  [Fact]
  public void Rmdir_after_a_hand_emptied_folder_is_by_hand_for_the_files()
  {
    var w = Witness();
    w.Accept(Claude("PreToolUse", new { command = "rmdir notes/old" }, at: 8), Row);
    w.Accept(Claude("PostToolUse", new { command = "rmdir notes/old" }, at: 9), Row);
    Assert.Equal(ByHand, V(w, Project + "/notes/old/a.md", 0, 10));
    Assert.True(Ai(w, Project + "/notes/old", 0, 10));
    var hidden = Witness();
    hidden.Accept(Claude("PreToolUse", new { command = "rmdir \"$DIR\"" }, at: 8), Row);
    Assert.Equal(ByHand, V(hidden, Project + "/notes/a.md", 0, 10));
    foreach (var command in new[] { "rmdir notes/*", "rmdir */" }) Assert.Empty(Covers(command));
  }

  [Fact]
  public void A_find_name_pattern_does_not_claim_other_files()
  {
    var w = Witness();
    w.Accept(Claude("PreToolUse", new { command = "find . -name '*.pyc' -delete" }), Row);
    Assert.Equal(ByHand, V(w, Project + "/notes.md", 0, 1));
    Assert.True(Ai(w, Project + "/src/x.pyc", 0, 1));
    var caseless = Witness();
    caseless.Accept(Claude("PreToolUse", new { command = "find ~/Documents -iname .DS_STORE -delete" }), Row);
    Assert.True(Ai(caseless, Home + "/Documents/a/.DS_Store", 0, 1));
    Assert.Equal(ByHand, V(caseless, Home + "/Documents/a/report.pdf", 0, 1));
    var plain = Witness();
    plain.Accept(Claude("PreToolUse", new { command = "find . -name a -o -name b -delete" }), Row);
    Assert.True(Ai(plain, Project + "/notes.md", 0, 1));
  }

  [Fact]
  public void A_denied_command_never_counts_and_an_end_without_a_start_gives_no_window()
  {
    var w = Witness();
    w.Accept(Claude("PreToolUse", new { command = "rm notes.md" }), Row);
    w.Accept(Claude("PermissionRequest", new { command = "rm notes.md" }, at: 0.1), Row);
    w.Accept(Claude("Stop", new { }, at: 20), Row);
    Assert.Equal(ByHand, V(w, Project + "/notes.md", 5, 10));
    var ok = Witness();
    ok.Accept(Claude("PreToolUse", new { command = "rm notes.md" }), Row);
    ok.Accept(Claude("PermissionRequest", new { command = "rm notes.md" }, at: 0.1), Row);
    ok.Accept(Claude("PostToolUse", new { command = "rm notes.md" }, at: 3), Row);
    Assert.True(Ai(ok, Project + "/notes.md", 1, 4));
    var g = Witness();
    var input = J(new { command = "rm notes.md" });
    g.Accept(new("gemini", "BeforeTool", "td-1", "run_shell_command", input, Project, null, null, At(0)), Row);
    g.Accept(new("gemini", "Notification", "td-1", null, null, Project, null, "ToolPermission", At(0.1)), Row);
    g.Accept(new("gemini", "AfterAgent", "td-1", null, null, Project, null, null, At(20)), Row);
    Assert.Equal(ByHand, V(g, Project + "/notes.md", 5, 10));
    var late = Witness(start: -7200);
    late.Accept(Claude("PostToolUse", new { command = "rm notes.md" }, at: 100), Row);
    Assert.Equal(CannotKnow, V(late, Project + "/notes.md", 0, 50));
    Assert.Equal(ByHand, V(late, Project + "/other.md", 0, 50));
  }

  [Fact]
  public void An_unfollowable_working_folder_claims_nothing()
  {
    Assert.Empty(Covers("pushd src && popd && rm a.txt"));
    Assert.Empty(Covers("(cd src && rm a.txt); rm b.txt"));
    Assert.Empty(Covers("{ cd src; }; rm a.txt"));
    Assert.Empty(Covers("cd - && rm a.txt"));
    Assert.Empty(Covers("cd \"$X\" && rm a.txt"));
    Assert.Equal([P("/Users/a/x.txt")], Covers("popd; rm /Users/a/x.txt"));
  }

  [Fact]
  public void Windows_removal_words_are_read_like_the_Macs()
  {
    const string win = "C:/Users/a/Projects/site";
    List<CloudAiDeleteWitness.Cover> W(string command, bool powershell = true) => CloudAiDeleteWitness.ShellCovers(command, win, "C:/Users/a", 0, powershell).Covers;
    Assert.Equal([P(win + "/notes/a.md")], W("Remove-Item notes\\a.md"));
    Assert.Equal([P(win + "/build", true)], W("Remove-Item -Recurse -Force build"));
    Assert.Equal([P(win + "/build", true)], W("rm -r -fo build"));
    Assert.Equal([P(win + "/old.txt", true)], W("Move-Item old.txt archive\\old.txt"));
    Assert.Equal([P(win + "/x.log")], W("cmd /c del x.log", powershell: false));
    Assert.Equal([P(win + "/logs", true)], W("cmd /c del /s /q logs", powershell: false));
    Assert.Equal([P("C:/Temp/x.txt")], W("cmd /c del C:\\Temp\\x.txt", powershell: true));
    Assert.Equal([P(win + "/src/a.txt")], W("Set-Location src; Remove-Item a.txt"));
    Assert.Equal([P(win + "/a.txt")], W("Remove-Item -Force a.txt"));
    Assert.Equal([new CloudAiDeleteWitness.Cover(CloudAiDeleteWitness.CoverKind.Folder, win, true)], W("Remove-Item $path"));
    Assert.Equal([new CloudAiDeleteWitness.Cover(CloudAiDeleteWitness.CoverKind.Folder, win, true)], W("Remove-Item * -Include *.log"));
    Assert.Empty(W("git clean -fdx"));
    Assert.Empty(W("dotnet clean"));
    Assert.True(CloudAiDeleteWitness.ShellCovers("powershell -File cleanup.ps1", win, "C:/Users/a", 0).Uncertain);
    // Git Bash spells C:\ as /c/: the same place.
    Assert.Equal(3, CloudAiDeleteWitness.Strength(P(CloudAiDeleteWitness.Normalize("/c/Users/a/x.txt")), CloudAiDeleteWitness.Normalize("C:\\Users\\a\\x.txt")));
    var w = Witness();
    w.Accept(new("claude", "PreToolUse", "td-1", "PowerShell", J(new { command = "Remove-Item -Recurse dist" }), win, "t1", null, At(0)), Row);
    Assert.True(Ai(w, "C:\\Users\\a\\Projects\\site\\dist\\a.js", 0, 1));
    Assert.Equal(ByHand, V(w, "C:\\Users\\a\\Projects\\site\\src\\a.js", 0, 1));
  }
}
