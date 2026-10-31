namespace TerminalDeck.Core.Chats;

public enum ComposerEnterAction { PassThrough, Send, Swallow }

// One rule for every message box (chat, Hoot, task comments): Enter sends,
// Shift+Enter is a new line, and Enter that belongs to an input method (picking
// or committing a candidate) is never a send. Pasted multi-line text never goes
// through here, so it stays text.
public sealed class ComposerEnter(Func<long>? clock = null)
{
  private const long CommitGuardMs = 150;
  private readonly Func<long> now = clock ?? (() => Environment.TickCount64);
  private bool composing;
  private long endedAt = long.MinValue / 2;
  public void CompositionStarted() => composing = true;
  public void CompositionEnded() { composing = false; endedAt = now(); }
  public bool Composing => composing || now() - endedAt < CommitGuardMs;
  public ComposerEnterAction Decide(bool isEnter, bool shift, bool canSend)
  {
    if (!isEnter || shift || Composing) return ComposerEnterAction.PassThrough;
    return canSend ? ComposerEnterAction.Send : ComposerEnterAction.Swallow;
  }
}
