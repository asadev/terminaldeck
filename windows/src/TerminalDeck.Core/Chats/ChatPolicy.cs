using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Chats;

public sealed partial class ChatSessions
{
  public async ValueTask RenameAsync(string id, string title, CancellationToken cancellationToken = default)
  {
    title = title.Trim();
    if (title.Length > 40 || title.Any(char.IsControl)) throw new ArgumentException("Use up to 40 characters on one line.");
    await gate.WaitAsync(cancellationToken);
    try
    {
      var chat = Get(id);
      var name = title.Length > 0 ? title : ChatText.FolderTitle(chat.Definition.Cwd);
      Save(chat with { Definition = chat.Definition with { Title = name }, HasCustomTitle = title.Length > 0 });
    }
    finally { gate.Release(); }
  }
  public async ValueTask SetPermissionAsync(string id, AiPermissionMode mode, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var chat = Get(id); RequireIdle(chat);
      ChatPermissionModes.Validate(chat.Definition.Provider, mode);
      if (chat.Definition.PermissionMode == mode) return;
      // The next worker must receive this mode in its real launch arguments.
      // Changing a label alone would leave the old worker's access in force.
      await RetireWorkerAsync(chat, cancellationToken);
      Save(chat with { Definition = chat.Definition with { PermissionMode = mode }, CreationKey = Guid.NewGuid().ToString("N"), WorkerSequence = 0 });
    }
    finally { gate.Release(); }
  }
}
