using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Mcp;

// Chat and job lanes supply these services at composition, sharing this same
// permission door, account lookup and launch definition rather than new routes.
public interface IIntegratedChatLauncher
{
  ValueTask<JsonElement> StartAsync(JsonElement arguments, AccountProfile account, CancellationToken ct);
}
public interface IIntegratedJobPlanner
{
  ValueTask<SessionDefinition> PrepareAsync(JsonElement arguments, AccountProfile account, CancellationToken ct);
}
public sealed class IntegratedSessionLaunch(AppDataRoot root) : IDeckSessionStarter
{
  public IIntegratedJobPlanner? Jobs { get; set; }
  public ValueTask<SessionDefinition> PrepareAsync(JsonElement arguments, AccountProfile? account, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    string? Text(string key) => arguments.TryGetProperty(key, out var value) ? value.GetString() : null;
    var folder = Text("cwd")!; var provider = Text("provider") ?? account?.Provider ?? "claude";
    if (!Directory.Exists(folder)) throw new ArgumentException("Choose an existing folder.");
    if (provider != "shell" && account is null || account is not null && provider != account.Provider) throw new McpRefusal("Choose an account for this AI.");
    if (Text("job") is not null || arguments.TryGetProperty("differ", out _))
      return account is not null && Jobs is not null ? Jobs.PrepareAsync(arguments, account, ct) : ValueTask.FromException<SessionDefinition>(new McpRefusal("Job playbook rows are not connected on Windows yet. Start without job or differ; to start a session as a saved agent, use agents_add_hand with that agent and the job text."));
    var brief = Text("brief"); var title = Text("title");
    if (brief is not null && (provider == "shell" || brief.Length is < 40 or > 8000 || string.IsNullOrWhiteSpace(title))) throw new McpRefusal("Use a title and a brief of 40 to 8000 characters for an AI session.");
    var definition = new SessionDefinition(Guid.NewGuid().ToString(), provider, folder, title ?? (provider == "shell" ? "PowerShell" : provider), account?.Id, account?.HomeId, Text("conversation"), InitialPrompt: brief);
    if (definition.ConversationId is not null && !Guid.TryParse(definition.ConversationId, out _)) throw new McpRefusal("Choose an exact saved conversation identity.");
    if (arguments.TryGetProperty("resume", out var resume) && resume.GetBoolean() && definition.ConversationId is null)
      definition = definition with { ConversationId = new ConversationFiles(root).MostRecent(definition) };
    if (definition.ConversationId is not null && brief is not null) throw new McpRefusal("Resume the saved conversation first, then send its new brief.");
    if (provider == "shell" && definition.ConversationId is not null) throw new McpRefusal("Shells cannot resume an AI conversation.");
    definition.Validate(); return ValueTask.FromResult(definition);
  }
}
