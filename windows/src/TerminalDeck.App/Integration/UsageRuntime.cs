using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Usage;
using TerminalDeck.Platform.Windows;
using TerminalDeck.Platform.Windows.Usage;

namespace TerminalDeck.App.Integration;

// The session header's usage meter and `usage.read` read one service: each session's OWN login
// (its account's folder), its transcript or its chat's reported turns. Hoot is its chat ("hoot").
public sealed partial class AppRuntime
{
  private UsageService? usage;
  public UsageService Usage => usage ??= new(UsageSubjectFor, UsageAccounts,
    new WindowsClaudeUsageProbe(Root, WindowsProviderLaunchPlanner.BundledToolsDirectory, id => Accounts.List().FirstOrDefault(a => a.Id == id)),
    model => ModelNames.Display(model, Accounts.List().SelectMany(a => Accounts.CachedModels(a.Id)?.Models ?? [])));

  private void RegisterUsageTools() => UsageMcpTools.Register(Door, Usage, UsageAlias);
  private string UsageAlias(string id) => id == "hoot" && Hoot?.Read().ChatId is { } chat ? chat : id;

  private UsageSubject? UsageSubjectFor(string id)
  {
    id = UsageAlias(id);
    var session = Sessions.FirstOrDefault(s => s.Definition.Id == id)?.Definition;
    var chat = session is null ? Chats?.List().FirstOrDefault(c => c.Definition.Id == id) : null;
    if (session is null && chat is null) return null;
    var provider = session?.Provider ?? chat!.Definition.Provider;
    var cwd = session?.Cwd ?? chat!.Definition.Cwd;
    if (session?.ServerId is not null) return new(id, provider, cwd, null, OnServer: true);
    if (provider is not ("claude" or "codex" or "gemini")) return new(id, provider, cwd, null);
    var accountId = session?.AccountId ?? chat?.Definition.AccountId;
    var profile = accountId is null ? null : Accounts.List().FirstOrDefault(a => a.Id == accountId);
    var homeId = session?.AccountHome ?? chat?.Definition.AccountHome ?? profile?.HomeId;
    return new(id, provider, cwd, new(provider, accountId, profile?.Name, homeId is null ? null : UsageHome(provider, homeId), profile?.Authentication == AccountAuthentication.ApiKey),
      session?.ConversationId, Chat: chat);
  }
  private IReadOnlyList<UsageAccount> UsageAccounts() =>
    Accounts.List().Select(a => new UsageAccount(a.Provider, a.Id, a.Name, UsageHome(a.Provider, a.HomeId), a.Authentication == AccountAuthentication.ApiKey)).ToArray();
  private string? UsageHome(string provider, string homeId)
  {
    try { return AccountHomes.Resolve(Root, provider, homeId, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), StableChannel.IsStable(AppContext.BaseDirectory)); }
    catch (Exception ex) when (ex is ArgumentException or InvalidOperationException) { return null; }
  }
}
