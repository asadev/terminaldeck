using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Servers;

// Server keys travel: the Servers owner's narrow door for a server that arrived from another device with its key copy
// (add-only, same id, look only, the SSH settings name kept). Its key stays in the saved passwords' own folder; the
// dialer uses that copy while this PC has no key of its own for the server.
public sealed partial class ServerStore
{
  public async Task CloudAddSshIfAbsentAsync(string id, CloudSecretsServerDefinition definition, string alias)
  {
    ServerValidation.Id(id);
    var draft = new ServerDraft(definition.Name, definition.Address, definition.Port, definition.Username, ServerAuthentication.Key, definition.ProjectId) { SshAlias = alias };
    ServerValidation.Draft(draft);
    using var lease = await store.AcquireWriteAsync(CancellationToken.None);
    var list = List();
    if (list.Any(s => s.Id == id)) return;
    store.Save([.. list, new SavedServer(id, draft.Name.Trim(), draft.Host, draft.Port, draft.User, draft.Authentication, ServerAccess.Default, draft.ProjectId) { SshAlias = alias }]);
  }
}
