using TerminalDeck.Core.Hooks;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Platform;

// May a found update restart the app by itself right now? Never while a coding AI is
// in the middle of a turn, in a chat or in a terminal, and never while someone is at
// this PC or typing into a session (a phone too). Then the person keeps the
// "Restart to update" button and the app looks again later (Umer's PC, 2 Nov: a
// Claude terminal turn was cut 5 s after its last request).
public static class UpdateReadiness
{
  // No keyboard/mouse on this PC and no typing into any session for this long = away.
  public static readonly TimeSpan AwayFor = TimeSpan.FromMinutes(10);
  // An AI at work repaints its screen all the time (Claude ~10x a second, also during
  // a long tool; Codex/Gemini tick a timer or spinner). Output that ran unbroken for
  // StreamFor and is younger than QuietFor is a turn in progress; one redraw is not.
  public static readonly TimeSpan QuietFor = TimeSpan.FromSeconds(30);
  public static readonly TimeSpan StreamFor = TimeSpan.FromSeconds(2);
  // A hook that says "working" counts while the screen moved in the last two minutes
  // (Esc ends a turn without any hook) and the turn is not older than this.
  public static readonly TimeSpan HookScreenFor = TimeSpan.FromMinutes(2);
  public static readonly TimeSpan HookTurnFor = TimeSpan.FromMinutes(30);
  private static readonly HashSet<string> WorkingHooks = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "BeforeAgent", "BeforeTool", "AfterTool"];

  // Null when the update may restart the app now; otherwise why it waits.
  // sinceLastInput is this PC's time since the last keyboard/mouse input (null: unknown).
  public static string? WaitReason(IReadOnlyList<SessionActivity> sessions, IReadOnlyDictionary<string, ProviderHookEvent> hooks,
    bool chatAnswering, TimeSpan? sinceLastInput, DateTimeOffset now)
  {
    if (chatAnswering) return "a chat is answering";
    if (sinceLastInput is { } idle && idle < AwayFor) return "someone is using this PC";
    foreach (var session in sessions)
    {
      if (session.InputAgeMs is { } typed && typed < AwayFor.TotalMilliseconds) return "someone is typing in " + session.Title;
      if (Working(session, hooks.TryGetValue(session.Id, out var hook) ? hook : null, now)) return session.Title + " is working";
    }
    return null;
  }

  public enum AutomaticRestart { Waiting, Restarted }

  // The automatic update's order (Reviewer #9, 4 Nov): look at the PC, download, look AGAIN right before the
  // restart (a download of ~270 MB takes minutes; somebody may have sat down or an AI started a turn), and only then
  // restart. A busy answer at either look means waiting for the next quiet moment; the downloaded file is kept.
  public static async Task<AutomaticRestart> RestartWhenFreeAsync(Func<Task<string?>> waitReason, bool download,
    Func<Task> prepare, Func<Task> restart, Action<string> waiting)
  {
    if (await waitReason() is { } before) { waiting(before); return AutomaticRestart.Waiting; }
    if (download)
    {
      await prepare();
      if (await waitReason() is { } after) { waiting(after); return AutomaticRestart.Waiting; }
    }
    await restart();
    return AutomaticRestart.Restarted;
  }

  public static bool Working(SessionActivity session, ProviderHookEvent? hook, DateTimeOffset now)
  {
    if (session.ProviderBusy == true) return true;
    if (session.OutputAgeMs is { } quiet && quiet < QuietFor.TotalMilliseconds && session.OutputRunMs is { } run && run >= StreamFor.TotalMilliseconds) return true;
    return hook is not null && WorkingHooks.Contains(hook.Event) && now - hook.At < HookTurnFor &&
      session.OutputAgeMs is { } screen && screen < HookScreenFor.TotalMilliseconds;
  }
}
