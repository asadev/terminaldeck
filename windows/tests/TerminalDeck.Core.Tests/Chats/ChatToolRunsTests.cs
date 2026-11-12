using System.Text.Json;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.Core.Tests.Chats;

// Asad, 6 Nov: a run of tool steps between two messages is ONE compact row, not a card per step.
public sealed class ChatToolRunsTests
{
  private static string Json(object value) => JsonSerializer.Serialize(value);
  private static ChatRow Bash(string id, string command, bool waiting = false, string status = "Done", string? description = null) =>
    new("tool", id, "Bash", "", waiting, Status: waiting ? "" : status, Input: Json(description is null ? new { command } : (object)new { command, description }), Output: waiting ? "" : "ok");

  [Fact] public async Task RecordedClaudeRunBetweenTwoMessagesFoldsIntoOneRowWithMacWording()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var events = new List<ChatEvent> { new(1, "user", "u", "Check the build"), new(2, "message", "a1", "Checking.") };
    for (var i = 0; i < 12; i++)
    {
      events.Add(new(events.Count + 1, "toolCall", "t" + i, "Bash", Data: JsonSerializer.SerializeToElement(new { command = "git status " + i })));
      events.Add(new(events.Count + 1, "toolResult", "t" + i, "clean"));
    }
    events.Add(new(events.Count + 1, "message", "a2", "All clean."));
    var segments = ChatToolRuns.Segments(ChatProjection.Rows(f.Chat with { Events = events.ToArray() }));
    Assert.Equal(new[] { false, false, true, false }, segments.Select(s => s.IsRun));
    Assert.Equal(12, segments[2].Items.Count);
    var summary = ChatToolRuns.Summarize(segments[2].Items);
    Assert.Equal("Ran 12 commands", ChatToolRuns.Header(summary)); Assert.Null(summary.Running); Assert.Equal(0, summary.Failed);
    Assert.Equal("git status 3", ChatToolRuns.Title(segments[2].Items[3]));
  }

  private static string[] Shape(IEnumerable<ChatSegment<ChatRow>> segments) =>
    segments.Select(s => s.IsRun ? "run:" + string.Join(',', s.Items.Select(r => r.Id)) : s.Items[0].Kind + ":" + s.Items[0].Id).ToArray();

  // Decker, 8 Nov (D2): a single step folds too, one compact "Ran a command" line, as on the Mac and phones.
  [Fact] public void ReasoningBetweenStepsJoinsTheRunWhileMessagesAndApprovalsEndItAndOneStepFoldsToo()
  {
    var rows = new ChatRow[]
    {
      new("assistant", "a", "Looking."), Bash("1", "ls"), new("reasoning", "r1", "thinking"), Bash("2", "pwd"), new("reasoning", "r2", "after"),
      new("approval", "p", "Allow?"), Bash("3", "rm x"), new("assistant", "b", "Done."), Bash("4", "echo")
    };
    Assert.Equal(new[] { "assistant:a", "run:1,r1,2", "reasoning:r2", "approval:p", "run:3", "assistant:b", "run:4" }, Shape(ChatToolRuns.Segments(rows)));
    Assert.Equal("Ran a command", ChatToolRuns.Header(ChatToolRuns.Summarize([rows[6]])));
  }

  // Decker, 8 Nov (D1): a failed step is always its own card, never inside the fold, on all four apps.
  [Fact] public void AFailedStepEndsTheRunAndStandsAlone()
  {
    var rows = new[] { Bash("1", "ls"), Bash("2", "make", status: "Failed"), Bash("3", "pwd"), Bash("4", "make test"), Bash("5", "rm x", status: "Failed") };
    Assert.Equal(new[] { "run:1", "tool:2", "run:3,4", "tool:5" }, Shape(ChatToolRuns.Segments(rows)));
    Assert.All(ChatToolRuns.Segments(rows).Where(s => s.IsRun), run => Assert.Equal(0, ChatToolRuns.Summarize(run.Items).Failed));
    // Hoot's lines use the same rule, by their own failure test.
    var lines = new[] { ("tool", "A", false), ("tool", "A", true), ("tool", "A", false) };
    Assert.Equal(new[] { true, false, true }, ChatToolRuns.Segments(lines, l => l.Item1, (a, b) => a.Item2 == b.Item2, l => l.Item3).Select(s => s.IsRun));
  }

  [Fact] public void RunningRunNamesTheWorkingStepAndAFailedStepStandsOut()
  {
    var run = Enumerable.Range(0, 11).Select(i => Bash("d" + i, "make " + i)).Append(Bash("live", "npm test", waiting: true, description: "Run the tests")).ToArray();
    var summary = ChatToolRuns.Summarize(run);
    Assert.Equal("live", summary.Running?.Id); Assert.Equal("Ran 11 commands · Run the tests…", ChatToolRuns.Header(summary));
    var failed = run.Take(3).Select((r, i) => i == 1 ? r with { Status = "Failed" } : r).ToArray();
    var done = ChatToolRuns.Summarize(failed);
    Assert.Equal(1, done.Failed); Assert.Equal("Ran 3 commands · 1 failed", ChatToolRuns.Header(done));
    var first = ChatToolRuns.Summarize([Bash("a", "x", waiting: true), Bash("b", "y", waiting: true)]);
    Assert.Equal("y…", ChatToolRuns.Header(first));
  }

  [Fact] public void MixedStepsUseTheMacFoldedLineWithEditCounts()
  {
    var rows = new ChatRow[]
    {
      new("tool", "m", "Read", Input: Json(new { file_path = "/Users/a/memory/postgres.md" }), Status: "Done"),
      Bash("c1", "ls"), Bash("c2", "pwd"),
      new("tool", "r", "Read", Input: Json(new { file_path = "/src/ChatPage.cs" }), Status: "Done"),
      new("tool", "e", "Edit", Input: Json(new { file_path = "/src/a.cs", old_string = "one", new_string = "two\nthree" }), Status: "Done"),
      new("tool", "x", "TodoWrite", Input: Json(new { todos = Array.Empty<string>() }), Status: "Done"),
      new("tool", "s", "mcp__deck-control__sessions_list", Input: "{}", Status: "Done")
    };
    var summary = ChatToolRuns.Summarize(rows);
    Assert.Equal("Recalled a memory, ran 2 commands, read ChatPage.cs, listed sessions, edited a.cs", summary.Text);
    Assert.Equal((2, 1), (summary.Plus, summary.Minus));
    Assert.Equal("Edited a.cs", ChatToolRuns.Title(rows[4])); Assert.Equal("Reading ChatPage.cs", ChatToolRuns.Title(rows[3], live: true));
    Assert.Equal("Looked up tools", ChatToolRuns.Summarize([rows[5], rows[5] with { Id = "y" }]).Text);
  }

  [Fact] public void CodexAndGeminiStepsAreReadFromTheirOwnReports()
  {
    var command = new ChatRow("tool", "c", "git diff", Status: "Done", Input: Json(new { type = "commandExecution", id = "c", command = "git diff" }));
    var change = new ChatRow("tool", "f", "Update files", Status: "Done", Input: Json(new { type = "fileChange", changes = new[] { new { path = "C:\\repo\\a.cs" }, new { path = "C:\\repo\\b.cs" } } }));
    var exec = new ChatRow("tool", "e", "/bin/zsh -lc 'npm test'", Status: "Done");
    var mcp = new ChatRow("tool", "m", "deck-control / tasks_get", Status: "Done", Input: Json(new { type = "mcpToolCall", server = "deck-control", tool = "tasks_get" }));
    Assert.Equal("Ran 2 commands, read tasks, edited 2 files", ChatToolRuns.Summarize([command, change, exec, mcp]).Text);
    Assert.Equal(ChatToolKind.Command, ChatToolRuns.Kind(exec)); Assert.Equal("Edited 2 files", ChatToolRuns.Title(change));
    var gemini = new[] { "execute", "read", "edit", "search" }.Select(k => new ChatRow("tool", k, "Step " + k, Status: "Done",
      Input: Json(new { sessionUpdate = "tool_call", toolCallId = k, kind = k, locations = new[] { new { path = "/w/notes.md" } } }))).ToArray();
    Assert.Equal(new[] { ChatToolKind.Command, ChatToolKind.Read, ChatToolKind.Edit, ChatToolKind.Search }, gemini.Select(ChatToolRuns.Kind));
    Assert.Equal("Ran a command, read notes.md, searched files, edited notes.md", ChatToolRuns.Summarize(gemini).Text);
  }

  [Fact] public void HootLinesFoldOnlyWithinOneTurn()
  {
    var lines = new[] { ("tool", "A"), ("tool", "A"), ("tool", "B"), ("tool", "B"), ("assistant", "B") };
    var segments = ChatToolRuns.Segments(lines, l => l.Item1, (a, b) => a.Item2 == b.Item2);
    Assert.Equal(new[] { 2, 2, 1 }, segments.Select(s => s.Items.Count)); Assert.True(segments[0].IsRun && segments[1].IsRun); Assert.False(segments[2].IsRun);
  }

  // Release check, 6 Nov: Claude drew chart text in dark grey on the dark card. The appended drawing
  // instruction names the theme variables every app's sealed drawing defines.
  [Fact] public void DrawingInstructionNamesTheThemeVariables()
  {
    foreach (var name in new[] { "var(--text)", "var(--muted)", "var(--accent)", "var(--background)", "currentColor", "never fixed dark" })
      Assert.Contains(name, ChatRichContent.Instruction);
  }

  [Fact] public void PlainOutputStaysInTheStepDetailWhilePicturesAndDrawingsAreDrawn()
  {
    Assert.False(ChatToolRuns.Drawable("total 12\ndrwxr-xr-x  5 a  staff  160 src"));
    Assert.True(ChatToolRuns.Drawable("```mermaid\ngraph TD; A-->B\n```"));
    Assert.True(ChatToolRuns.Drawable("![chart](https://example.com/c.png)"));
    var mcp = new ChatRow("tool", "m", "mcp__x__y", Input: "{\"q\":1}", Output: Json(new[] { new { type = "text", text = "First" }, new { type = "text", text = "Second" } }), Status: "Done");
    Assert.Equal("Input\n{\"q\":1}\n\nOutput\nFirst\n\nSecond", ChatToolRuns.Detail(mcp));
    Assert.Equal("Input was not reported.\n\nOutput\nplain", ChatToolRuns.Detail(new("tool", "p", "Bash", Output: "plain")));
  }
}
