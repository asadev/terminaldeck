using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private bool PhoneHootHas(ApprovedDevice device, string kind, string id)
  {
    if (device.Access == PhoneAccess.Full) return true;
    if (device.Access == PhoneAccess.Hoot) return kind == "hoot" && id == "main";
    if (device.Access == PhoneAccess.Look) return false;
    return kind switch
    {
      "projects" => TaskGrants.HasProject(device, id),
      "folders" => Projects.List().Any(p => TaskGrants.HasProject(device, p.Id) && p.Folders.Any(f => McpCallerScopes.Within(f, id))),
      "sessions" => Sessions.Any(s => s.Definition.Id == id && Remote.Grants.Allows(device, s)) || Chats.List().Any(c => c.Definition.Id == id && Remote.Grants.Allows(device, TerminalDeck.Core.Chats.ChatSessions.Session(c))),
      "agents" => Agents.List().Any(a => a.Id == id && TaskGrants.HasProject(device, a.ProjectId)),
      "tasks" => Tasks.List().Any(t => t.Id == id && TaskGrants.HasProject(device, t.ProjectId)),
      "hoot" => id == "main",
      _ => false
    };
  }
  private sealed class PhoneHootScope(AppRuntime runtime) : IMcpCallerScope
  {
    public bool Has(string kind, string id)
    {
      var state = HootStorage.At(runtime.Root).Load() ?? runtime.Hoot.Read();
      if (HootPhoneAuthority.Device(state) is not { } phone) return McpCallerScopes.Everything.Has(kind, id);
      var current = runtime.Remote.Trust.List().FirstOrDefault(d => d.Id == phone);
      return current is not null && runtime.PhoneHootHas(current, kind, id);
    }
  }
}
