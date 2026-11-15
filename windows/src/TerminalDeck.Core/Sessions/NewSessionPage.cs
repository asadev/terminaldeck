using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Sessions;

// The New session page (Mac: NativeLanding, 14 Nov). The app opens on it: the chat window with no
// session yet. Nothing is made while it is shown or while a choice changes; the one session is
// made when the person sends the first message. These are the page's rules without any window,
// so they run in the Core tests on every pull request.

// Settings > General > "When Terminal Deck opens". Windows has no Overview page, so it offers
// the first two; a stored "overview" opens where he left off.
public static class OpensOn
{
  public const string NewSession = "new-session";
  public const string WhereILeftOff = "where-i-left-off";
  public const string Overview = "overview";
  public static IReadOnlyList<string> OnWindows { get; } = [NewSession, WhereILeftOff];
  public static string Label(string value) => value switch
  {
    WhereILeftOff => "Where I left off",
    Overview => "Overview",
    _ => "New session"
  };
  public static string Normal(string? value) => value switch
  {
    WhereILeftOff or Overview => WhereILeftOff,
    _ => NewSession
  };
  public static bool ShowsNewSession(string? value) => Normal(value) == NewSession;
}

// What the page starts. Mode is "chat" or "terminal". A null model or effort means the app-wide
// "New sessions start with" choice (Settings > Coding AIs), so nothing stale is pinned.
public sealed record NewSessionStart(string ProjectId, string? AgentId, string Provider, string? AccountId, string? Model, string? Effort, string Mode);

public sealed record NewSessionAgent(string Id, string Name, string ProjectId, string Provider, bool Lead = false);

// What exists on this PC right now. Providers are in the order the page lists them.
public sealed record NewSessionWorld(
  IReadOnlyList<string> ProjectIds,
  IReadOnlyList<NewSessionAgent> Agents,
  IReadOnlyList<string> Providers,
  Func<string, IReadOnlyList<string>> Accounts,
  Func<string, string?> DefaultAccount,
  string DefaultProvider);

public static class NewSessionPresets
{
  public static bool CanChat(string provider) => provider is "claude" or "codex" or "gemini";
  public static bool UsesAccount(string provider) => CanChat(provider);
  public static bool AgentFits(NewSessionAgent agent, string projectId) => agent.ProjectId == projectId || agent.ProjectId == ProjectIdentity.IndependentId;
  // The project's lead first, then by name (the same order as the full New session form).
  public static IReadOnlyList<NewSessionAgent> AgentsFor(string projectId, NewSessionWorld world) =>
    world.Agents.Where(a => AgentFits(a, projectId)).OrderByDescending(a => a.Lead && a.ProjectId == projectId).ThenBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();

  // The last start he made on this PC presets the page; whatever no longer exists falls back
  // quietly (a deleted project to No project, a removed account to the AI's default).
  // A New session pressed inside a project starts in that project.
  public static NewSessionStart Resolve(NewSessionStart? last, NewSessionWorld world, string? pressedInProject = null)
  {
    var project = pressedInProject is { } pressed && Exists(world, pressed) ? pressed
      : last?.ProjectId is { } kept && Exists(world, kept) ? kept : ProjectIdentity.IndependentId;
    var agent = last?.AgentId is { } agentId && last.ProjectId == project
      ? AgentsFor(project, world).FirstOrDefault(a => a.Id == agentId) : null;
    var provider = agent?.Provider
      ?? (last?.Provider is { } lastAi && world.Providers.Contains(lastAi) ? lastAi
      : world.Providers.Contains(world.DefaultProvider) ? world.DefaultProvider
      : world.Providers.FirstOrDefault() ?? "claude");
    var sameAi = last is not null && last.Provider == provider;
    var account = Account(world, provider, sameAi ? last!.AccountId : null);
    var mode = !CanChat(provider) ? "terminal" : sameAi && last!.Mode == "terminal" ? "terminal" : "chat";
    return new(project, agent?.Id, provider, account, sameAi ? last!.Model : null, sameAi ? last!.Effort : null, mode);
  }

  // Picking a project keeps the AI; an agent of another project is let go.
  public static NewSessionStart WithProject(NewSessionStart current, string projectId, NewSessionWorld world)
  {
    var project = Exists(world, projectId) ? projectId : ProjectIdentity.IndependentId;
    var agent = current.AgentId is { } id ? AgentsFor(project, world).FirstOrDefault(a => a.Id == id) : null;
    return current with { ProjectId = project, AgentId = agent?.Id };
  }

  // An agent brings its own AI; "No agent" keeps the AI that was showing.
  public static NewSessionStart WithAgent(NewSessionStart current, string? agentId, NewSessionWorld world)
  {
    var agent = agentId is null ? null : AgentsFor(current.ProjectId, world).FirstOrDefault(a => a.Id == agentId);
    if (agent is null) return current with { AgentId = null };
    var next = agent.Provider == current.Provider ? current : WithProvider(current, agent.Provider, world);
    return next with { AgentId = agent.Id };
  }

  // Picking another AI (or one of its accounts) picks that AI: its account, default model and
  // effort; an agent of another AI is let go; an AI that cannot chat opens in Terminal.
  public static NewSessionStart WithProvider(NewSessionStart current, string provider, NewSessionWorld world, string? accountId = null)
  {
    var keepAgent = current.AgentId is { } id && world.Agents.Any(a => a.Id == id && a.Provider == provider);
    var same = current.Provider == provider;
    return current with
    {
      Provider = provider,
      AgentId = keepAgent ? current.AgentId : null,
      AccountId = Account(world, provider, accountId ?? (same ? current.AccountId : null)),
      Model = same ? current.Model : null,
      Effort = same ? current.Effort : null,
      Mode = CanChat(provider) ? current.Mode : "terminal"
    };
  }

  public static NewSessionStart WithMode(NewSessionStart current, string mode) =>
    current with { Mode = mode == "terminal" || !CanChat(current.Provider) ? "terminal" : "chat" };

  private static bool Exists(NewSessionWorld world, string projectId) => projectId == ProjectIdentity.IndependentId || world.ProjectIds.Contains(projectId);
  private static string? Account(NewSessionWorld world, string provider, string? wanted)
  {
    if (!UsesAccount(provider)) return null;
    var accounts = world.Accounts(provider);
    if (wanted is not null && accounts.Contains(wanted)) return wanted;
    if (world.DefaultAccount(provider) is { } fallback && accounts.Contains(fallback)) return fallback;
    return accounts.FirstOrDefault();
  }
}

// Whether a send happens is decided AT THE PRESS from the text in the box right then, never from
// a value kept since the box was last drawn (the Mac fault of 14 Nov: an arrow drawn while the box
// was empty refused a message typed afterwards, and the other way round).
public static class NewSessionSend
{
  public static bool Allowed(string liveText, int files, bool starting) => !starting && (!string.IsNullOrWhiteSpace(liveText) || files > 0);
  // Only the sent text leaves the box: words typed while the session was being made stay.
  public static string AfterSend(string boxNow, string sent)
  {
    if (boxNow == sent) return "";
    if (sent.Length > 0 && boxNow.StartsWith(sent, StringComparison.Ordinal)) return boxNow[sent.Length..].TrimStart('\r', '\n');
    return boxNow;
  }
  // No project: a folder of its own under the home folder, never the home folder itself.
  public static string IndependentFolder(string homeFolder) => Path.Combine(homeFolder, Brand.Name, "Independent");
}

public enum NewSessionOutcome { NotSent, NotReady, Started, Failed }
public sealed record NewSessionResult(NewSessionOutcome Outcome, string? SessionId = null, string? Message = null);

// One send: waits a little for the app to be ready, makes exactly one session, never a second one
// for a second press while the first is being made, and keeps the text when anything fails.
public sealed class NewSessionFlow(Func<NewSessionStart, string, CancellationToken, Task<string>> start)
{
  public const string NotReadyMessage = "Terminal Deck is still getting ready. Your message is kept here: press Return again in a moment.";
  public bool Starting { get; private set; }
  public async Task<NewSessionResult> SendAsync(string liveText, int files, NewSessionStart choices, Task ready, TimeSpan readyWait, CancellationToken ct = default)
  {
    if (!NewSessionSend.Allowed(liveText, files, Starting)) return new(NewSessionOutcome.NotSent);
    Starting = true;
    try
    {
      if (!ready.IsCompleted && await Task.WhenAny(ready, Task.Delay(readyWait, ct)) != ready) return new(NewSessionOutcome.NotReady, Message: NotReadyMessage);
      if (!ready.IsCompletedSuccessfully) return new(NewSessionOutcome.NotReady, Message: "Terminal Deck could not connect to its session service. Your message is kept here.");
      var id = await start(choices, liveText, ct);
      return new(NewSessionOutcome.Started, id);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      return new(NewSessionOutcome.Failed, Message: ex is ArgumentException or InvalidOperationException or IOException ? ex.Message : "The session could not start. Your message and choices are kept here.");
    }
    finally { Starting = false; }
  }
}

// The last start he made on THIS PC (never synced, never written by tools, Hoot or phones) and the
// unsent text, so the page comes back as he left it.
public sealed class NewSessionMemory(IStateStore<NewSessionStart> last, IStateStore<NewSessionDraft> draft)
{
  public NewSessionMemory(AppDataRoot root) : this(new JsonStateStore<NewSessionStart>(root, "new-session-last"), new JsonStateStore<NewSessionDraft>(root, "new-session-draft")) { }
  public NewSessionStart? Last()
  {
    try { return last.Load(); }
    catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException or UnauthorizedAccessException) { return null; }
  }
  public void Remember(NewSessionStart start) => last.Save(start);
  public string Draft()
  {
    try { return draft.Load()?.Text ?? ""; }
    catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException or UnauthorizedAccessException) { return ""; }
  }
  public void KeepDraft(string text) => draft.Save(new(text));
}
public sealed record NewSessionDraft(string Text);
