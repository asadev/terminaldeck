using System.Security.Cryptography;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Servers;

public sealed class ServerStore
{
  private readonly JsonStateStore<SavedServer[]> store;
  private readonly ISecretStore secrets;
  public string CredentialPrefix { get; }
  public ServerStore(AppDataRoot root, ISecretStore secrets)
  {
    store = new(root, "servers-v2"); this.secrets = secrets;
    CredentialPrefix = Brand.Name + "/" + root.NamespaceId + "/servers/";
  }
  public string PasswordName(string id) { ServerValidation.Id(id); return CredentialPrefix + id; }
  public SavedServer[] List()
  {
    var rows = store.Load() ?? [];
    if (rows.Length > 1000 || rows.Select(s => s.Id).Distinct().Count() != rows.Length) throw new IOException("The saved server list is invalid.");
    foreach (var row in rows)
    {
      ServerValidation.Id(row.Id); ServerValidation.Draft(new(row.Name, row.Host, row.Port, row.User, row.Authentication, row.ProjectId)); ServerValidation.Access(row.Access);
    }
    return rows;
  }
  public SavedServer Get(string id) { ServerValidation.Id(id); return List().SingleOrDefault(s => s.Id == id) ?? throw new ServerRefusal("That server is no longer saved."); }
  public async ValueTask<SavedServer> AddAsync(ServerDraft draft, ReadOnlyMemory<byte> password, CancellationToken ct)
  {
    ServerValidation.Draft(draft);
    if (draft.Authentication == ServerAuthentication.Password && password.Length is < 1 or > 2560) throw new ServerRefusal("Enter the SSH password.");
    if (password.Span.Contains((byte)'\n') || password.Span.Contains((byte)'\r')) throw new ServerRefusal("The password cannot contain a line break.");
    using var lease = await store.AcquireWriteAsync(ct);
    var row = new SavedServer(Guid.NewGuid().ToString("N"), draft.Name.Trim(), draft.Host, draft.Port, draft.User, draft.Authentication, ServerAccess.Default, draft.ProjectId);
    var bytes = password.ToArray();
    try
    {
      if (bytes.Length > 0) await secrets.WriteAsync(PasswordName(row.Id), bytes, ct);
      store.Save([.. List(), row]); return row;
    }
    catch { await secrets.DeleteAsync(PasswordName(row.Id), CancellationToken.None); throw; }
    finally { CryptographicOperations.ZeroMemory(bytes); }
  }
  public async ValueTask SetAccessAsync(string id, ServerAccess access, CancellationToken ct)
  {
    ServerValidation.Access(access); using var lease = await store.AcquireWriteAsync(ct); _ = Get(id);
    store.Save(List().Select(s => s.Id == id ? s with { Access = access } : s).ToArray());
  }
  public async ValueTask RenameAsync(string id, string name, CancellationToken ct)
  {
    using var lease = await store.AcquireWriteAsync(ct); var current = Get(id);
    ServerValidation.Draft(new(name, current.Host, current.Port, current.User, current.Authentication, current.ProjectId));
    store.Save(List().Select(s => s.Id == id ? s with { Name = name.Trim() } : s).ToArray());
  }
  public async ValueTask RemoveAsync(string id, CancellationToken ct)
  {
    using var lease = await store.AcquireWriteAsync(ct); _ = Get(id);
    await secrets.DeleteAsync(PasswordName(id), ct); store.Save(List().Where(s => s.Id != id).ToArray());
  }
}
