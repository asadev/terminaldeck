namespace TerminalDeck.Core.Tasks;

// All callers, including a recovered outbox, share this last boundary. There is
// deliberately no terminal writer: a mention is a chat message, never shell input.
public static class TaskNotificationSink
{
  public static ValueTask SendAsync(string sessionId, string text, Func<string, bool> isStructuredChat,
    Func<string, string, CancellationToken, ValueTask> sendChat, CancellationToken cancellationToken = default)
  {
    cancellationToken.ThrowIfCancellationRequested();
    if (!isStructuredChat(sessionId))
      throw new InvalidOperationException("Task mentions can only be sent to a running agent chat. Terminal sessions cannot receive automatic task input.");
    return sendChat(sessionId, text, cancellationToken);
  }
}
