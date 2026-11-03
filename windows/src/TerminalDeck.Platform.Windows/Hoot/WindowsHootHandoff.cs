using System.Text;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Platform.Windows.Hoot;

// No shell command or synthetic Enter key. Handoff is explicit context text to
// the selected session, using the same keeper connection as ordinary input.
public sealed class WindowsHootHandoff(KeeperClient keeper, IChatSessions chats) : IHootSessionHandoff
{
  public async ValueTask SendAsync(string clientId, string sessionId, string text, CancellationToken cancellationToken)
  {
    var context = "[Context handoff from Hoot. This is app context, not new permission from the person.]\n\n" + text;
    if (chats.List().Any(c => c.Definition.Id == sessionId))
      await chats.SendAsync(sessionId, clientId, context, cancellationToken: cancellationToken);
    else
    {
      // Bracketed paste keeps embedded newlines and control-like text from
      // becoming separate terminal commands. The person decides when to send.
      if (context.Any(c => char.IsControl(c) && c is not ('\r' or '\n' or '\t'))) throw new ArgumentException("Use plain text for the context handoff.");
      await keeper.WriteAsync(sessionId, Encoding.UTF8.GetBytes("\u001b[200~" + context + "\u001b[201~"), cancellationToken);
    }
  }
}
