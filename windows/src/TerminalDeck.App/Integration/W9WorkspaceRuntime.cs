using System.Text.Json;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Servers;
using TerminalDeck.Platform.Windows;
using TerminalDeck.Platform.Windows.Hoot;
using TerminalDeck.Platform.Windows.Integration;
using TerminalDeck.Platform.Windows.Servers;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  public IHoot Hoot { get; private set; } = null!;
  public IServers Servers { get; private set; } = null!;
  public IHootSurface? HootSurface { get; set; }
  private ServersMcp? serverTools;
  private HootToolConnectionServer? hootToolConnection;
  private readonly Dictionary<string, McpRegistration> hootConnections = [];
  public void InitializeServers(IServerAuthorizer authorizer, IServerKeyPicker? keyPicker = null)
  {
    var secrets = new WindowsCredentialStore(Root);
    var runtime = new WindowsOpenSshRuntime(Root, secrets, Path.Combine(Path.GetDirectoryName(KeeperExecutable)!, "askpass", "TerminalDeck.Servers.Askpass.exe"));
    Servers = new ServerService(new(Root, secrets), runtime, authorizer, new KeeperServerTerminal(this));
    serverTools = new(Servers, keyPicker);
    Projects.BeforeRemove = id => { if (Tasks is not null) RequireTaskProjectRemovable(id); };
  }
  private void PreflightV2(McpGrant grant, McpToolSpec spec, JsonElement arguments)
  {
    if (Hoot is not null) HootPolicy.Check(grant, spec.Id, arguments, HootStorage.At(Root).Load() ?? Hoot.Read());
    if (ServersMcp.Specs.Any(s => s.Id == spec.Id) && (serverTools is null || !serverTools.Preflight(grant, spec, arguments)))
      throw new McpRefusal("This server action is outside the caller's current access.");
  }
  private async Task InitializeHootAsync()
  {
    Hoot = await WindowsHootClient.ConnectAsync(Root, KeeperCredentials.GetOrCreate(Root));
    Hoot.Changed += _ =>
    {
      // Settings changes retire tool authority immediately, including approval
      // waits already in flight. The next dispatch gets a fresh scoped key.
      lock (hootConnections)
        foreach (var id in hootConnections.Keys.ToArray())
          if (!CallerAuthority.IsCurrent("hoot:" + id))
          { CallerAuthority.Revoke(Door, "hoot:" + id); hootConnections.Remove(id); }
      Changed?.Invoke();
    };
  }
  public async Task StartHootToolConnectionAsync()
  {
    hootToolConnection = new(Root, KeeperCredentials.GetOrCreate(Root), PrepareChatToolsAsync);
    hootToolConnection.Start();
    if (Hoot.Read().ChatId is { } current) await PrepareHootToolsAsync(current, CancellationToken.None);
  }
  // Every chat's private tool bridge asks here when it has no key, or its key
  // stopped working (app restart, replaced build, permission change, expiry).
  // A still-valid key is handed back unchanged so the AI's MCP session survives.
  private async ValueTask PrepareChatToolsAsync(string chatId, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    if (HootStorage.At(Root).Load()?.ChatId == chatId) { await PrepareHootToolsAsync(chatId, ct); return; }
    if (!Chats.List().Any(c => c.Definition.Id == chatId)) await Chats.RefreshAsync(ct);
    ConnectChatTools(chatId);
  }
  private bool Live(McpRegistration registration)
  {
    try { _ = Door.Lifetime(registration.Id); return true; }
    catch (McpRefusal) { return false; }
  }
  private ValueTask PrepareHootToolsAsync(string chatId, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    var state = HootStorage.At(Root).Load() ?? throw new McpRefusal("Hoot is not ready.");
    if (state.ChatId != chatId || state.Settings is not { } settings || LocalToolAddress is null) throw new McpRefusal("Hoot's conversation is no longer current.");
    var callerId = "hoot:" + chatId;
    lock (hootConnections)
    {
      if (hootConnections.TryGetValue(chatId, out var kept) && CallerAuthority.Current(callerId) == kept && Live(kept))
      { HootToolConnection.Save(Root, chatId, new(LocalToolAddress.AbsoluteUri, kept.Token)); return ValueTask.CompletedTask; }
      hootConnections.Remove(chatId); CallerAuthority.Revoke(Door, callerId);
      // Hoot has every app capability (Mac: local caller); HootPolicy keeps his own settings fenced.
      var resources = new[] { "sessions:" + chatId, "hoot:main", "receiver:hoot", "accounts:" + settings.AccountId, "folders:" + settings.Folder,
        "profiles:default", "settings:workspace", "settings:tasks", "settings:servers", "settings:browser", "settings:mcp", "settings:receiver", "settings:projects",
        "settings:agents", "settings:remote", "tasks:*", "task-systems:*" };
      var policy = new McpCallerPolicy(callerId, chatId, HootDesk.Seat, settings.PermissionMode,
        McpCatalogue.Load().Select(s => s.Id).ToArray(), Enum.GetValues<McpTier>(), resources, ServerManagement: true, Scope: McpCallerScopes.Everything);
      var registration = CallerAuthority.Provision(Door, policy, _ =>
      {
        var current = HootStorage.At(Root).Load();
        return current?.ChatId == chatId && current.Settings == settings && LocalToolAddress is not null;
      });
      HootToolConnection.Save(Root, chatId, new(LocalToolAddress.AbsoluteUri, registration.Token));
      hootConnections.Add(chatId, registration);
    }
    return ValueTask.CompletedTask;
  }
  private readonly Dictionary<string, McpRegistration> chatConnections = [];
  // One rule for every signed-in AI chat (hand, task run, tool-started or plain):
  // its seat, project scope and the chat's own permission mode. The AI's own
  // permission setting decides asking; this grant decides what it may reach.
  private void ConnectChatTools(string chatId)
  {
    if (LocalToolAddress is null) throw new IOException("The app tools are still connecting. Wait before starting this agent.");
    var chat = Chats.List().FirstOrDefault(c => c.Definition.Id == chatId && !c.Ended) ?? throw new McpRefusal("This chat is not running.");
    var callerId = "chat:" + chatId;
    lock (chatConnections)
    {
      if (chatConnections.TryGetValue(chatId, out var kept) && CallerAuthority.Current(callerId) == kept && Live(kept))
      { HootToolConnection.Save(Root, chatId, new(LocalToolAddress.AbsoluteUri, kept.Token)); return; }
      chatConnections.Remove(chatId); CallerAuthority.Revoke(Door, callerId);
      var definition = chat.Definition; var folder = definition.Cwd;
      var run = Agents.Runs().LastOrDefault(r => r.SessionId == chatId);
      var projectId = run?.ProjectId ?? TaskSessionProject(chatId) ?? Projects.Resolve(null, folder);
      var resources = new HashSet<string> { "sessions:" + chatId, "accounts:" + definition.AccountId, "folders:" + folder, "projects:" + projectId, "profiles:default" };
      if (run?.AgentId is { } agent) resources.Add("agents:" + agent);
      foreach (var taskRun in Tasks.Runs().Where(r => r.SessionId == chatId)) resources.Add("tasks:" + taskRun.TaskId);
      var policy = new McpCallerPolicy(callerId, chatId, run?.SeatKey, definition.PermissionMode,
        McpCatalogue.Load().Select(s => s.Id).ToArray(), Enum.GetValues<McpTier>(), resources.ToArray(),
        Scope: McpCallerScopes.Session(new CallerFacts(this), chatId, projectId, folder, run?.SeatKey));
      var registration = CallerAuthority.Provision(Door, policy, p => Chats.List().Any(c => c.Definition.Id == chatId && !c.Ended &&
        c.Definition.AccountId == definition.AccountId && c.Definition.Cwd == folder && c.Definition.PermissionMode == p.Mode) &&
        Agents.Runs().LastOrDefault(r => r.SessionId == chatId)?.SeatKey == p.SeatId);
      HootToolConnection.Save(Root, chatId, new(LocalToolAddress.AbsoluteUri, registration.Token));
      chatConnections.Add(chatId, registration);
    }
  }
  // A chat whose permission mode, account or seat changed loses its old key at
  // once; its bridge then asks again and gets one matching the new settings.
  private void RetireStaleChatTools()
  {
    lock (chatConnections)
      foreach (var id in chatConnections.Keys.ToArray())
        if (!CallerAuthority.IsCurrent("chat:" + id)) { CallerAuthority.Revoke(Door, "chat:" + id); chatConnections.Remove(id); }
  }
  private sealed class CallerFacts(AppRuntime runtime) : ISessionCallerFacts
  {
    public IReadOnlyList<string> ProjectFolders(string projectId) => runtime.Projects.List().FirstOrDefault(p => p.Id == projectId)?.Folders.ToArray() ?? [];
    public string? SessionFolder(string sessionId) => runtime.ProjectSessions().FirstOrDefault(s => s.Id == sessionId)?.Folder;
    public string? SessionProject(string sessionId) => runtime.ProjectSessions().Any(s => s.Id == sessionId) ? runtime.TaskSessionProject(sessionId) : null;
    public string? TaskProject(string taskId) { try { return runtime.Tasks.Get(taskId).ProjectId; } catch (Exception ex) when (ex is ArgumentException or KeyNotFoundException or InvalidOperationException) { return null; } }
    public string? AgentProject(string agentId) => runtime.Agents.List().FirstOrDefault(a => a.Id == agentId)?.ProjectId;
  }
  private sealed class KeeperServerTerminal(AppRuntime runtime) : IServerTerminal
  {
    public async ValueTask<string> OpenAsync(ServerTerminalRequest request, CancellationToken ct)
    {
      var definition = new TerminalDeck.Core.Sessions.SessionDefinition(Guid.NewGuid().ToString(), "shell", runtime.Root.DirectoryPath,
        request.Server.Name, ServerId: request.Server.Id);
      var reply = await runtime.Keeper.CreateAsync(definition, ct);
      var id = reply.Session?.Definition.Id ?? throw new IOException("The server terminal did not start.");
      if (request.Server.ProjectId is { } project) runtime.Projects.BindSession(id, project);
      await runtime.RefreshSessionsAsync(); return id;
    }
  }
}
