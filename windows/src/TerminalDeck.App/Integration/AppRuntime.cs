using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Projects;
using TerminalDeck.Platform.Windows.Chats;
using TerminalDeck.Platform.Windows.Projects;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime : IAsyncDisposable
{
  public AppDataRoot Root { get; }
  public TerminalDeck.Core.Settings.GeneralSettings General { get; }
  public KeeperClient Keeper { get; private set; } = null!;
  public AccountService Accounts { get; }
  public ApiAccountService ApiAccounts { get; }
  private bool accountNotificationsReady;
  public WindowsChatSessionsClient Chats { get; private set; } = null!;
  public ProjectService Projects { get; }
  public AgentService Agents { get; }
  public LocalProjectFolders ProjectFolders { get; }
  private ChatMcpTools? chatTools;
  public IProjectAgentPageActions? ProjectAgentPages { get; set; }
  public IntegratedSessionLaunch SessionLaunch { get; }
  public AccountSwitchCoordinator AccountSwitches { get; }
  public KeeperConversationRuntime Conversations { get; }
  public RemoteService Remote { get; }
  public OtherComputersService OtherComputers { get; }
  public McpManager Mcp { get; }
  public McpDoor Door { get; }
  public McpCallerAuthority CallerAuthority { get; } = new();
  public Func<Func<Task>, Task>? ReceiverDispatcher { get; set; }
  public Uri? LocalToolAddress { get; set; }
  public event Action? Changed;
  private SessionRecord[] sessions = [];
  public IReadOnlyList<SessionRecord> Sessions => Volatile.Read(ref sessions);
  public string KeeperExecutable { get; }
  public AppRuntime(AppDataRoot root, IMcpPermissionBroker? permissions, Func<McpToolSpec, McpToolHandler, McpToolHandler> dispatch)
  {
    Root = root;
    General = new(new JsonStateStore<TerminalDeck.Core.Settings.GeneralPreferences>(root, "general-settings"));
    TerminalDeck.App.Views.Agents.NewSessionPicker.Services = new(RecentFolders,
      provider => TerminalDeck.Core.Settings.LaunchDefaults.For(provider, General.Read()), provider => General.NewChatPermission(provider));
    WindowsPrivateDirectory.Ensure(root.DirectoryPath);
    var keeperBundle = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "keeper-location.txt")).Trim();
    if (keeperBundle.Length != 17 || !keeperBundle.All(char.IsAsciiDigit)) throw new IOException("The keeper bundle is missing.");
    KeeperExecutable = Path.Combine(AppContext.BaseDirectory, "keeper", keeperBundle, "TerminalDeck.Keeper.exe");
    var providers = new[] { "claude", "codex", "gemini" }.Select(p => new WindowsAccountProvider(p, root, WindowsProviderLaunchPlanner.BundledToolsDirectory, StartSignInAsync));
    Accounts = new(new JsonStateStore<AccountState>(root, "accounts"), providers);
    // Account status arrives before session hydration. Reconcile saved tabs only
    // after the keeper has supplied its real session snapshot.
    Accounts.Changed += () => { if (accountNotificationsReady) Changed?.Invoke(); };
    ApiAccounts = new(Accounts, new AccountCredentials(new WindowsCredentialStore(root), root), root);
    SessionLaunch = new(root);
    ProjectFolders = new(root);
    Projects = new(new JsonStateStore<ProjectState>(root, "projects"), ProjectFolders, new WindowsProjectPictures(root));
    Agents = new(new JsonStateStore<AgentState>(root, "agents"), Projects, new AgentInstructions(root), Accounts,
      new KeeperAgentSessionGateway(async (definition, ct) =>
      {
        var row = (await Keeper.CreateAsync(definition, ct)).Session ?? throw new IOException("The session could not start.");
        await RefreshSessionsAsync(); return row;
      }, StartAgentChatAsync, async (id, _) => await StopAsync(id)));
    Projects.Changed += () => Changed?.Invoke(); Agents.Changed += () => Changed?.Invoke();
    Conversations = new(() => Keeper, new ConversationFiles(root));
    AccountSwitches = new(Accounts, Conversations, new JsonStateStore<AccountSwitchJournal>(root, "account-switches"));
    Remote = new(root, () => Sessions);
    OtherComputers = new(root);
    TerminalDeck.App.Views.Agents.NewSessionPicker.Computers = OtherComputers;
    Mcp = new(new JsonStateStore<McpManagerState>(root, "mcp"), new WindowsCredentialStore(root), root, new WindowsMcpCommandResolver(), new ManagedMcpFactory());
    Door = new(permissions ?? CallerAuthority, wrap: dispatch, preflight: PreflightV2);
    CallerAuthority.Authorized += action =>
    {
      var directory = Path.Combine(Root.DirectoryPath, "mcp"); WindowsPrivateDirectory.Ensure(directory);
      lock (CallerAuthority)
      {
        var path = Path.Combine(directory, "actions.jsonl");
        if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024) File.Move(path, path + ".previous", true);
        File.AppendAllText(path, JsonSerializer.Serialize(action) + "\n");
      }
    };
    InitializeQualityTools();
    InitializeCustomTerminalProviders();
    InitializePreferenceTools();
    Remote.McpBridge = new McpRelayBridge(Door);
    OtherComputersTools.Register(Door, OtherComputers, this);
  }
  public async Task InitializeAsync()
  {
    foreach (var provider in new[] { "claude", "codex", "gemini" })
      await Accounts.EnsureDefaultAsync(provider, StableChannel.IsStable(AppContext.BaseDirectory));
    foreach (var account in Accounts.List())
      try { await Accounts.RefreshAsync(account.Id); } catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException) { }
    _ = Accounts.WarmModelsAsync();
    await ReconnectAsync(); await RefreshSessionsAsync(); accountNotificationsReady = true;
    await AccountSwitches.RecoverAsync();
    await InitializeHootAsync(); InitializeTaskRuntime();
    await InitializeReceiverAsync(ReceiverDispatcher ?? (work => work()));
    Remote.ReceiverApplication = ReceiverRelay;
    Remote.ReceiverTransportRequired = () => Receiver.Sources().Any(s => s.Enabled);
    ReceiverSources.Changed += EnsureReceiverTransport;
    InitializeSessionNotifications();
    InitializeProviderHooks();
    InitializeRoutineEvents();
    InitializePhoneWorkspace();
    InitializePhoneManagementTools();
    await Remote.StartAsync(); Changed?.Invoke();
  }
  private readonly KeeperReconnectGate reconnectGate = new();
  public long KeeperGeneration => reconnectGate.Generation;
  // While the keeper hands over for an update, nothing may start another one
  // from this (old) package: it would hold the files again.
  private readonly TerminalDeck.Core.Platform.KeeperHandover handover = new();
  public Task ReconnectAsync(long? observedGeneration = null) => reconnectGate.ReconnectAsync(async () =>
    {
      if (handover.Active) throw new IOException("Terminal Deck is updating. Your sessions reopen after the update.");
      Keeper = await KeeperConnection.AttachAsync(Root, KeeperExecutable);
      if (Chats is null)
      {
        Chats = await WindowsChatSessionsClient.ConnectAsync(Root, KeeperCredentials.GetOrCreate(Root));
        Chats.SignInRequested = Accounts.SignInAsync;
        Chats.Changed += () => { Agents.ReconcileSessions(ProjectSessions()); RetireStaleChatTools(); usage?.ChatsChanged(); Changed?.Invoke(); };
      }
      else await Chats.RefreshAsync();
    }, observedGeneration);
  public async Task RefreshSessionsAsync()
  {
    var response = await Keeper.ListAsync();
    Volatile.Write(ref sessions, response.Sessions?.ToArray() ?? []);
    if (Chats is not null) await Chats.RefreshAsync();
    Agents.ReconcileSessions(ProjectSessions()); TaskSessionsChanged(); Changed?.Invoke();
  }
  public async Task<SessionRecord> StartAsync(string provider, string folder, string? accountId = null, string? title = null)
  {
    if (!Directory.Exists(folder)) throw new ArgumentException("Choose an existing folder.");
    if (TerminalDeck.Core.Sessions.CustomTerminalProviders.IsKey(provider)) return await StartCustomTerminalAsync(provider, folder, title);
    AccountProfile? account = null;
    if (provider != "shell")
    {
      account = accountId is null ? Accounts.Preferred(provider, folder) : Accounts.Get(accountId);
      if (account is null) throw new InvalidOperationException("Sign in to this AI under Coding AIs first.");
      if (account.Provider != provider) throw new ArgumentException("Choose an account for the selected AI.");
      account = await Accounts.RequireSignedInAsync(account.Id);
    }
    var response = await Keeper.CreateAsync(new(Guid.NewGuid().ToString(), provider, folder, title ?? (provider == "shell" ? "PowerShell" : provider), account?.Id, account?.HomeId));
    await RefreshSessionsAsync(); return response.Session ?? throw new IOException("The session could not start.");
  }
  public async Task<SessionRecord> StartShellForProjectAsync(string folder, string projectId)
  {
    _ = Projects.Get(projectId);
    var row = await StartAsync("shell", folder);
    Projects.BindSession(row.Definition.Id, projectId); return row;
  }
  public Func<string, bool, Task>? InstallAiRequested { get; set; }
  public Func<string, string, Task<JsonElement>>? InstallFlowRequested { get; set; }
  public Func<string, string, Task<JsonElement>>? SignInFlowRequested { get; set; }
  public Task InstallAiAsync(string provider, bool alreadyApproved = false) => InstallAiRequested?.Invoke(provider, alreadyApproved) ?? throw new InvalidOperationException("Open Coding AIs to install this AI.");
  public Func<AccountProfile, string, Task>? SignInRequested { get; set; }
  private Task StartSignInAsync(AccountProfile account, string folder) => SignInRequested?.Invoke(account, folder)
    ?? throw new InvalidOperationException("Open this account in Coding AIs to sign in.");
  // Folders recently used by terminals and chats, newest first (New session dropdown).
  public IEnumerable<string> RecentFolders()
  {
    IEnumerable<string> chats;
    try { chats = Chats is null ? [] : Chats.List().OrderByDescending(c => c.Events.LastOrDefault()?.At).Select(c => c.Definition.Cwd).ToArray(); }
    catch (Exception ex) when (ex is IOException or InvalidOperationException) { chats = []; }
    return Sessions.Reverse().Where(s => s.Definition.Provider != "shell" || s.Definition.ServerId is null).Select(s => s.Definition.Cwd).Concat(chats)
      .Where(f => !string.IsNullOrWhiteSpace(f) && !NewSessionFolders.Internal(f, Root.DirectoryPath)).DistinctBy(NewSessionFolders.Key, StringComparer.OrdinalIgnoreCase).ToArray();
  }
  public IReadOnlyList<ProjectSession> ProjectSessions() => Sessions.Select(s => new ProjectSession(s.Definition.Id, s.Definition.Title, s.Definition.Provider, s.Definition.Cwd, s.State.ToString()))
    .Concat(Chats is null ? [] : Chats.List().Select(c => new ProjectSession(c.Definition.Id, c.Definition.Title, c.Definition.Provider, c.Definition.Cwd, c.Ended ? "ended" : c.Busy ? "working" : "waiting", Mode: "chat"))).ToArray();
  private async ValueTask<AgentSessionStarted> StartAgentChatAsync(AgentLaunchPlan plan, CancellationToken ct)
  {
    if (!Directory.Exists(plan.Folder)) throw new ArgumentException("Choose an existing folder.");
    var chat = await Chats.CreateAsync(new(plan.SessionId, plan.Provider, plan.Folder, plan.Title, plan.AccountId, plan.AccountHome, new(plan.Model, plan.Effort), plan.Instructions,
      plan.Permission is { } chosen && ChatPermissionModes.Supported(plan.Provider).Contains(chosen) ? chosen : General.NewChatPermission(plan.Provider)),
      customTitle: plan.Title != TerminalDeck.Core.Agents.AgentSeats.ProviderName(plan.Provider), cancellationToken: ct);
    ConnectChatTools(chat.Definition.Id);
    if (plan.Job.Length > 0) await Chats.SendAsync(chat.Definition.Id, plan.SessionId, plan.Job, cancellationToken: ct);
    await RefreshSessionsAsync(); return new(chat.Definition.Id, "chat");
  }
  public async Task StopAsync(string id)
  {
    if (Chats.List().Any(c => c.Definition.Id == id)) await Chats.StopAsync(id); else await Keeper.StopAsync(id);
    await RefreshSessionsAsync();
  }
  private readonly System.Collections.Concurrent.ConcurrentDictionary<string, SemaphoreSlim> inputGates = [];
  public async Task SendAsync(string id, string text)
  {
    var gate = inputGates.GetOrAdd(id, _ => new(1)); await gate.WaitAsync();
    try
    {
      if (Chats.List().Any(c => c.Definition.Id == id)) await Chats.SendAsync(id, Guid.NewGuid().ToString(), text.TrimEnd('\r'));
      else await Keeper.WriteAsync(id, Encoding.UTF8.GetBytes(text));
    } finally { gate.Release(); }
  }
  public Task SendBrowserContextAsync(string id, string draft) =>
    SendAsync(id, TerminalDeck.Core.Browser.BrowserContext.TerminalMessage(draft));
  private bool remoteTools;
  public bool RemoteToolsEnabled => remoteTools;
  public async Task SetRemoteToolsAsync(bool enabled)
  {
    if (enabled) await Remote.StartAsync();
    remoteTools = enabled;
    if (!enabled)
      foreach (var policy in CallerAuthority.List().Where(p => p.Relay)) RevokeCaller(policy.CallerId);
    Changed?.Invoke();
  }
  public McpRegistration ConnectCaller(string name, string sessionId, AiPermissionMode mode, string[] origins, bool relay = false, McpCallContext? parent = null)
  {
    if (string.IsNullOrWhiteSpace(name) || name.Length > 80 || name.Any(char.IsControl)) throw new ArgumentException("Choose a short AI app name.");
    var terminal = Sessions.FirstOrDefault(s => s.Definition.Id == sessionId);
    var chat = Chats.List().FirstOrDefault(s => s.Definition.Id == sessionId);
    if (terminal is null && chat is null || terminal?.State == SessionState.Exited || chat?.Ended == true)
      throw new ArgumentException("Choose an active conversation for this AI connection.");
    // Session/seat facts come from the keeper and agent ledger, never an HTTP header.
    var run = Agents.Runs().FirstOrDefault(r => r.SessionId == sessionId);
    var folder = terminal?.Definition.Cwd ?? chat!.Definition.Cwd;
    var account = terminal?.Definition.AccountId ?? chat?.Definition.AccountId;
    var resources = new List<string> { "sessions:" + sessionId, "folders:" + folder, "profiles:default" };
    if (account is not null) resources.Add("accounts:" + account);
    if (Tasks is not null && Tasks.Runs().FirstOrDefault(r => r.SessionId == sessionId) is { } taskRun)
    {
      var task = Tasks.Get(taskRun.TaskId); resources.Add("tasks:" + task.Id); resources.Add("projects:" + task.ProjectId);
      resources.Add("folders:" + task.Folder);
    }
    if (run is not null) { resources.Add("projects:" + run.ProjectId); if (run.AgentId is { } agent) resources.Add("agents:" + agent); }
    foreach (var origin in origins)
    {
      var uri = TerminalDeck.Core.Browser.BrowserModel.Address(origin);
      if (uri.Scheme is not ("https" or "http") || uri.GetLeftPart(UriPartial.Authority) != origin)
        throw new ArgumentException("Grant a complete http or https origin, without a path, query or password.");
      resources.Add("origins:" + origin);
    }
    if (relay && !RemoteToolsEnabled) throw new InvalidOperationException("Enable remote tools first.");
    var policy = new McpCallerPolicy("ai:" + Guid.NewGuid().ToString("N"), sessionId, run?.SeatKey, mode,
      McpCatalogue.Load().Select(t => t.Id).ToArray(), Enum.GetValues<McpTier>(), resources.ToArray(), relay);
    if (parent is not null)
    {
      if (sessionId != parent.Grant.SessionId || mode != parent.Grant.PermissionMode || relay && !parent.Grant.AllowRelay)
        throw new McpRefusal("A delegated AI connection must keep this caller’s session, mode and relay boundary.");
      foreach (var resource in policy.Resources)
      {
        var separator = resource.IndexOf(':'); parent.Require(resource[..separator], resource[(separator + 1)..]);
      }
    }
    var registration = CallerAuthority.Provision(Door, policy, p =>
      (parent is null || CallerAuthority.IsCurrent(parent.Grant.CallerId)) && (!p.Relay || RemoteToolsEnabled) && (Sessions.Any(s => s.Definition.Id == p.SessionId && s.State != SessionState.Exited) || Chats.List().Any(c => c.Definition.Id == p.SessionId && !c.Ended)) &&
      Agents.Runs().FirstOrDefault(r => r.SessionId == p.SessionId)?.SeatKey == p.SeatId);
    var directory = Path.Combine(Root.DirectoryPath, "mcp", "callers"); WindowsPrivateDirectory.Ensure(directory);
    var file = Path.Combine(directory, registration.Id.ToString("N") + ".json");
    File.WriteAllText(file, JsonSerializer.Serialize(new { name, callerId = policy.CallerId, sessionId, seatId = policy.SeatId, permissionMode = mode.ToString(),
      nativeAiPermissionFlow = true, resources, url = relay ? Remote.McpAddress : LocalToolAddress?.AbsoluteUri, token = registration.Token }));
    Changed?.Invoke(); return registration;
  }
  public void RevokeCaller(string id)
  {
    CallerAuthority.Revoke(Door, id);
    var directory = Path.Combine(Root.DirectoryPath, "mcp", "callers");
    if (Directory.Exists(directory)) foreach (var path in Directory.EnumerateFiles(directory, "*.json"))
    {
      using var document = JsonDocument.Parse(File.ReadAllText(path));
      if (document.RootElement.GetProperty("callerId").GetString() == id) File.Delete(path);
    }
    Changed?.Invoke();
  }
  private TerminalDeck.Core.Code.GitHubClient? copyGitHub;
  public TerminalDeck.Core.Code.GitHubClient CopyGitHub => copyGitHub ??= TerminalDeck.Core.Code.GitHubClient.ForCopy(Root.DirectoryPath,
    TerminalDeck.Core.Code.GitHubClient.IsRealCopy(Root.DirectoryPath, AppContext.BaseDirectory, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)));
  public void RegisterTools()
  {
    KeeperSessionTools.Register(Door, () => Keeper);
    new TerminalDeck.Core.Code.CodeMcp(new(), new(), CopyGitHub).Register(Door);
    var projectTools = new ProjectsAgentsMcp(Projects, Agents, ProjectFolders, ProjectSessions, Accounts, ProjectAgentPages);
    chatTools = new ChatMcpTools(Chats, General.NewChatPermission);
    McpToolHandler start = async (c, a, ct) =>
    {
      var folder = a.GetProperty("cwd").GetString()!; c.Require("folders", folder);
      var provider = a.TryGetProperty("provider", out var p) ? p.GetString()! : "claude";
      // No account named: the calling chat's own (same AI) first, never an unsigned placeholder.
      var callerAccount = Chats.List().FirstOrDefault(x => x.Definition.Id == c.Grant.SessionId)?.Definition.AccountId ?? Sessions.FirstOrDefault(x => x.Definition.Id == c.Grant.SessionId)?.Definition.AccountId;
      var account = a.TryGetProperty("account", out var choice) ? Accounts.Get(choice.GetString()!) : Accounts.Preferred(provider, folder, callerAccount);
      if (!a.TryGetProperty("provider", out _) && account is not null) provider = account.Provider;
      if (provider == "shell") account = null;
      if (account is not null) c.Require("accounts", account.Id);
      var mode = a.TryGetProperty("mode", out var selectedMode) ? selectedMode.GetString()! : provider == "shell" ? "terminal" : "chat";
      if (provider == "shell" && mode == "chat") throw new McpRefusal("PowerShell uses the terminal view. Choose terminal mode.");
      if (provider != "shell" && account is null) throw new McpRefusal("Choose an account first.");
      var special = a.TryGetProperty("brief", out _) || a.TryGetProperty("resume", out _) || a.TryGetProperty("conversation", out _) || a.TryGetProperty("job", out _) || a.TryGetProperty("differ", out _);
      if (provider != "shell" && !special)
      {
        var run = await projectTools.StartAsync(new(null, a.TryGetProperty("projectId", out var project) ? project.GetString() : null, folder, provider, account!.Id, mode, Title: a.TryGetProperty("title", out var title) ? title.GetString() : null), c, ct);
        await RefreshSessionsAsync(); return run;
      }
      if (mode != "chat" && account is not null) account = await Accounts.RequireSignedInAsync(account.Id, ct);
      var definition = await SessionLaunch.PrepareAsync(a, account, ct);
      if (definition.Cwd != folder || definition.Provider != provider || account is not null && (definition.AccountId != account.Id || definition.AccountHome != account.HomeId)) throw new McpRefusal("The launch does not match this folder and account.");
      var projectId = Projects.Resolve(a.TryGetProperty("projectId", out var binding) ? binding.GetString() : null, folder); c.Require("projects", projectId);
      await c.EnsureCurrentAsync(ct);
      if (mode == "chat")
      {
        var chat = await Chats.CreateAsync(new(definition.Id, provider, folder, definition.Title, account!.Id, account.HomeId, new(), PermissionMode: General.NewChatPermission(provider)), definition.ConversationId, ct);
        Projects.BindSession(chat.Definition.Id, projectId); ConnectChatTools(chat.Definition.Id);
        if (definition.InitialPrompt is { Length: > 0 } prompt) await Chats.SendAsync(chat.Definition.Id, definition.Id, prompt, cancellationToken: ct);
        Projects.BindSession(chat.Definition.Id, projectId); c.NoteSessionStarted(chat.Definition.Id); await RefreshSessionsAsync(); return ChatMcpTools.View(chat);
      }
      var result = await Keeper.CreateAsync(definition, ct); await RefreshSessionsAsync();
      Projects.BindSession(result.Session!.Definition.Id, projectId); c.NoteSessionStarted(result.Session.Definition.Id); return JsonSerializer.SerializeToElement(result.Session);
    };
    Door.Register("sessions.start", projectTools.SessionStartHandler(start));
    KeeperAccountTools.Register(Door, Accounts, () => Keeper, Conversations, AccountSwitches, account => Chats.List().Any(c => c.Definition.AccountId == account));
    AccountReadinessTools.Register(Door, Accounts);
    AccountMcp.Register(Door, Accounts, ApiAccounts, General, () => Projects.List(), RecentFolders,
      () => Agents.List().Where(x => x.Status == TerminalDeck.Core.Agents.SavedAgentStatus.Active).Select(x => new NewSessionAgentChoice(x.Id, x.Name, x.ProjectId, x.Provider, Projects.List().Any(p => p.Id == x.ProjectId && p.Lead == "agent:" + x.Id))),
      account => Sessions.Any(s => s.Definition.AccountId == account && s.State != SessionState.Exited) || Chats.List().Any(c => c.Definition.AccountId == account && !c.Ended));
    AccountFlowTools.Register(Door, Accounts, provider => InstallAiAsync(provider, alreadyApproved: true),
      (provider, action) => InstallFlowRequested?.Invoke(provider, action) ?? throw new McpRefusal("Open Coding AIs in the app."),
      (id, action) => SignInFlowRequested?.Invoke(id, action) ?? throw new McpRefusal("Open this account in Coding AIs."));
    chatTools.Register(Door);
    projectTools.Register(Door);
    Door.Compose("sessions.list", terminal => async (c, a, ct) =>
    {
      await Chats.RefreshAsync(ct);
      var rows = await terminal!(c, a, ct);
      var chats = Chats.List().Where(chat => c.Has("sessions", chat.Definition.Id) && c.Has("accounts", chat.Definition.AccountId) && c.Has("folders", chat.Definition.Cwd) && SessionRows.InFolder(a, chat.Definition.Cwd));
      // Live first, newest first, bounded: a listing must fit an AI's tool-result limit.
      return JsonSerializer.SerializeToElement(rows.EnumerateArray().Select(r => (object)r).Concat(chats.OrderBy(chat => chat.Ended).ThenByDescending(chat => chat.Events.LastOrDefault()?.At).Select(SessionRows.Chat)).Take(SessionRows.Limit));
    });
    RegisterTaskTools(); RegisterReceiverTools(); RegisterUsageTools();
    serverTools?.Register(Door);
    serverSettingsTools?.Register(Door);
    if (serverCapabilityTools is not null) foreach (var contribution in serverCapabilityTools.Contributions()) Door.Register(contribution.Spec.Id, contribution.Handler);
    new TerminalDeck.Core.Hoot.HootMcpTools(Hoot, HootSurface).Register(Door);
    RegisterPhoneWorkspaceTools();
    DeckCoreTools.RegisterManager(Door, Mcp);
    Door.Register("mcp.callers", async (c, a, ct) =>
    {
      var action = a.GetProperty("action").GetString();
      var id = a.TryGetProperty("callerId", out var supplied) ? supplied.GetString() : c.Grant.CallerId;
      if (id != c.Grant.CallerId && !c.Grant.OwnerApplication) throw new McpRefusal("Another AI’s connection must be changed in Settings.");
      if (action == "create")
      {
        if (c.Grant.SessionId is null) throw new McpRefusal("Choose this AI’s conversation before connecting another app.");
        await c.EnsureCurrentAsync(ct);
        var registration = ConnectCaller(a.GetProperty("name").GetString()!, c.Grant.SessionId, c.Grant.PermissionMode,
          a.TryGetProperty("origins", out var origins) ? origins.EnumerateArray().Select(o => o.GetString()!).ToArray() : [], parent: c);
        return JsonSerializer.SerializeToElement(new { connectionFile = "mcp/callers/" + registration.Id.ToString("N") + ".json", inheritsSessionAndMode = true });
      }
      if (action == "revoke") { await c.EnsureCurrentAsync(ct); RevokeCaller(id!); }
      return JsonSerializer.SerializeToElement(CallerAuthority.List().Where(p => c.Grant.OwnerApplication || p.CallerId == c.Grant.CallerId));
    });
    Door.Register("mcp.remote", async (c, a, ct) =>
    {
      c.Require("settings", "mcp"); if (!c.Grant.OwnerApplication) throw new McpRefusal("Only the owner can change remote tool access.");
      if (a.TryGetProperty("enabled", out var enabled)) { await c.EnsureCurrentAsync(ct); await SetRemoteToolsAsync(enabled.GetBoolean()); }
      return JsonSerializer.SerializeToElement(new { enabled = RemoteToolsEnabled, connectionDirectory = "mcp/callers", permissionFlow = "calling AI" });
    });
    Door.Register("remote.status", (c, a, ct) =>
    {
      c.Require("settings", "remote"); return ValueTask.FromResult(JsonSerializer.SerializeToElement(new { service = Remote.State.ToString(), devices = Remote.Trust.List().Where(d => c.Has("devices", d.Id)), pending = Remote.Trust.Pending().Where(d => c.Has("devices", d.Id)), pairingOpen = Remote.Trust.Pairing.IsOpen }));
    });
    Door.Register("remote.manage", async (c, a, ct) =>
    {
      c.Require("settings", "remote"); await c.EnsureCurrentAsync(ct);
      var action = a.GetProperty("do").GetString();
      switch (action)
      {
        case "open-web":
          if (c.Grant.DeviceId is not null) throw new McpRefusal("Open the web version from this computer.");
          await Remote.OpenWebAsync(!a.TryGetProperty("openBrowser", out var browserOpen) || browserOpen.GetBoolean()); break;
        case "start": await Remote.StartAsync(); break;
        case "show-code": var offer = await Remote.ShowCodeAsync(); return JsonSerializer.SerializeToElement(new { code = offer.Code, expiresAt = offer.ExpiresAt });
        case "cancel-code": Remote.Trust.Pairing.Cancel(); break;
        case "approve": case "revoke":
          var id = a.GetProperty("deviceId").GetString()!; c.Require("devices", id);
          if (action == "approve") ApprovePhone(id); else Remote.Trust.Revoke(id); break;
        default: throw new McpRefusal("That remote action is not connected yet.");
      }
      return JsonSerializer.SerializeToElement(new { done = true });
    });
  }
  private async void EnsureReceiverTransport()
  {
    try { await Remote.EnsureReceiverTransportAsync(); }
    catch (Exception e) when (e is IOException or OperationCanceledException or InvalidOperationException) { }
  }
  private int runtimeDisposed;
  public async ValueTask DisposeAsync() {
    if (Interlocked.Exchange(ref runtimeDisposed, 1) != 0) return;
    accountNotificationsReady = false;
    if (receiverSources is not null) receiverSources.Changed -= EnsureReceiverTransport;
    await DisposeServerSigninAsync();
    await Remote.DisposeAsync();
    DisposeSessionNotifications(); DisposePhoneExtendedWorkspace(); providerHookHost?.Dispose();
    usage?.Dispose();
    if (hootToolConnection is not null) await hootToolConnection.DisposeAsync();
    await DisposeReceiverAsync(); await DisposeTaskRuntimeAsync();
    if (Hoot is IAsyncDisposable hootClient) await hootClient.DisposeAsync(); foreach (var policy in CallerAuthority.List()) RevokeCaller(policy.CallerId); await SetRemoteToolsAsync(false); await OtherComputers.DisposeAsync(); await Mcp.DisposeAsync(); chatTools?.Dispose();
  }
  internal bool AnswerInProgress => Chats?.List().Any(c => !c.Ended && c.Busy) == true;
  // Why a found update may not restart the app by itself right now (null: it may):
  // a chat answering, a terminal AI mid-turn, or someone at this PC or typing into a
  // session. A keeper that cannot say (an older one) also makes it wait for the click.
  internal async Task<string?> UpdateWaitReasonAsync()
  {
    if (AnswerInProgress) return "a chat is answering";
    IReadOnlyList<TerminalDeck.Core.Sessions.SessionActivity> activity;
    try
    {
      using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
      activity = (await Keeper.ActivityAsync(deadline.Token)).Activity ?? throw new IOException("The session service did not report its sessions.");
    }
    catch (Exception ex) when (ex is IOException or TimeoutException or OperationCanceledException or InvalidOperationException or UnauthorizedAccessException)
    { return "the session service did not say whether its sessions are working"; }
    return TerminalDeck.Core.Platform.UpdateReadiness.WaitReason(activity, HookSessionEvents, false, Services.WindowsUpdateStatus.SinceLastInput(), DateTimeOffset.UtcNow);
  }
  // Asks the keeper to save every session for the next version and exit, then
  // waits until that exact supervisor process has gone.
  internal async Task HandOverForUpdateAsync()
  {
    var identityPath = Path.Combine(Root.DirectoryPath, "keeper", "supervisor.identity.json");
    (int Pid, long Ticks)? supervisor = null;
    try
    {
      using var json = JsonDocument.Parse(File.ReadAllBytes(identityPath));
      supervisor = (json.RootElement.GetProperty("Pid").GetInt32(), json.RootElement.GetProperty("StartedUtcTicks").GetInt64());
    }
    catch (Exception ex) when (ex is IOException or JsonException or KeyNotFoundException or UnauthorizedAccessException) { }
    // Every failure (the keeper refuses, or exits too slowly) ends the hand-over state at once (review #27 item 4).
    await handover.RunAsync(async () =>
    {
      using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(60));
      await Keeper.PrepareUpdateAsync(deadline.Token);
    }, async () =>
    {
      var until = DateTime.UtcNow.AddSeconds(20);
      while (supervisor is { } owner && DateTime.UtcNow < until)
      {
        try
        {
          using var process = System.Diagnostics.Process.GetProcessById(owner.Pid);
          if (process.HasExited || process.StartTime.ToUniversalTime().Ticks != owner.Ticks) return;
        }
        catch (ArgumentException) { return; }
        await Task.Delay(200);
      }
      if (supervisor is not null) throw new IOException("The session service did not close for the update. Your sessions were kept.");
    });
  }
  // Downloads and checks the offered package without stopping anything (the automatic restart looks at the PC again after).
  internal Task<string> PrepareUpdateAsync() => Services.WindowsUpdateStatus.PrepareAsync(Path.Combine(Root.DirectoryPath, "updates"));
  internal Task<string> RestartToUpdateAsync() => Services.WindowsUpdateStatus.RestartToUpdateAsync(Path.Combine(Root.DirectoryPath, "updates"), HandOverOrReconnectAsync, SettleSignInsAsync, async () =>
  {
    handover.Done();
    await ReconnectAsync(); await RefreshSessionsAsync(); Changed?.Invoke();
  });
  // The running session keeper is an older build's (3 Nov, umar-pc: 0.20.3.1's keeper under the 0.20.4.1 app). Windows can
  // apply an update by itself (staged in the background, registered at sign-in) while the app is closed and the keeper
  // runs on outside the package; the reopened app then sees no update to apply, so the handover never ran and the old
  // keeper kept serving every session. True when the supervisor on record is alive and its build stamp is older than this
  // build's (a newer keeper, from a newer copy sharing the data root, is left alone).
  internal bool KeeperFromOlderBuild()
  {
    try
    {
      using var json = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(Root.DirectoryPath, "keeper", "supervisor.identity.json")));
      var pid = json.RootElement.GetProperty("Pid").GetInt32(); var ticks = json.RootElement.GetProperty("StartedUtcTicks").GetInt64();
      using var process = System.Diagnostics.Process.GetProcessById(pid);
      if (process.HasExited || process.StartTime.ToUniversalTime().Ticks != ticks) return false;
      return TerminalDeck.Core.Platform.KeeperBuild.IsOlder(process.MainModule?.FileName, KeeperExecutable);
    }
    catch (Exception ex) when (ex is IOException or JsonException or KeyNotFoundException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { return false; }
  }
  // Moves every session onto this (newer) build's keeper, the same handover as an update with nothing to install: the old
  // keeper saves its sessions and exits, sign-ins settle, then this build's keeper starts and the sessions reopen.
  internal async Task<string> MoveSessionsToThisBuildAsync()
  {
    await TerminalDeck.Core.Platform.PackageUpdateSequence.RunAsync(HandOverOrReconnectAsync, SettleSignInsAsync, () => Task.CompletedTask, async () =>
    {
      handover.Done();
      await ReconnectAsync(); await RefreshSessionsAsync(); Changed?.Invoke();
    });
    return "Your sessions now run on this version of Terminal Deck.";
  }
  // A failed hand-over (refused, or the keeper exited too slowly) reconnects at once: to the same keeper if it stayed,
  // else to a fresh one from this build, so the window never sits without sessions (review #27 item 4).
  private async Task HandOverOrReconnectAsync()
  {
    try { await HandOverForUpdateAsync(); }
    catch
    {
      try { await ReconnectAsync(); await RefreshSessionsAsync(); Changed?.Invoke(); }
      catch (Exception ex) when (ex is IOException or TimeoutException or InvalidOperationException or UnauthorizedAccessException) { }
      throw;
    }
  }
  // Windows ends every app process at once when it replaces the package. Let any
  // Claude sign-in renewal in this install's Claude folders finish saving first.
  internal Task SettleSignInsAsync() => TerminalDeck.Core.Accounts.SignInRenewal.WaitAllAsync(
    TerminalDeck.Core.Accounts.SignInRenewal.ClaudeFolders(Root, Accounts.List("claude"), Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), StableChannel.IsStable(AppContext.BaseDirectory)),
    TerminalDeck.Core.Accounts.SignInRenewal.Patience);
  internal void ReleaseIdleStableKeeper()
  {
    if (!StableChannel.IsStable(AppContext.BaseDirectory) || Keeper is null) return;
    // Closed has no async deferral. Complete this tiny IO exchange before WinUI
    // ends the last window's message loop; no UI work runs on the worker thread.
    Task.Run(async () =>
    {
      try { using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(3)); await Keeper.ShutdownIdleAsync(deadline.Token); }
      catch (Exception ex) when (ex is IOException or TimeoutException or OperationCanceledException) { }
    }).GetAwaiter().GetResult();
  }
}
