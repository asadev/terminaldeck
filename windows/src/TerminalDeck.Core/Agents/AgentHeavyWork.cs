using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Agents;

public sealed record AgentWorkTicket(string Ticket, string SessionId, string Label, DateTimeOffset CreatedAt, bool Granted = false);
public sealed record AgentWorkState(int Version, AgentWorkTicket[] Tickets);

// The one shared queue survives an app restart. Only a positively ended session loses its tickets automatically.
public sealed class AgentHeavyWork(JsonStateStore<AgentWorkState> store, Func<string, bool?> alive)
{
  private readonly SemaphoreSlim gate = new(1, 1);
  private readonly object signalGate = new();
  private TaskCompletionSource changed = new(TaskCreationOptions.RunContinuationsAsynchronously);
  public bool HasTickets { get; private set; } = true;
  private AgentWorkState Read()
  {
    var state = store.Load();
    if (state is null) return new(1, []);
    if (state.Version != 1 || state.Tickets is null) throw new IOException("The work-lock queue could not be read. It was kept.");
    return state;
  }
  public async Task ReconcileAsync(CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try
    {
      using var lease = await store.AcquireWriteAsync(ct); var state = Read();
      var rows = state.Tickets.Where(t => alive(t.SessionId) != false).ToArray();
      if (rows.Length > 0) rows[0] = rows[0] with { Granted = true };
      HasTickets = rows.Length > 0;
      if (!state.Tickets.SequenceEqual(rows)) { store.Save(new(1, rows)); Changed(); }
    }
    finally { gate.Release(); }
  }
  private void Changed() { lock (signalGate) { var old = changed; changed = new(TaskCreationOptions.RunContinuationsAsynchronously); old.TrySetResult(); } }
  public async Task<IReadOnlyList<AgentWorkTicket>> ListAsync(CancellationToken ct)
  {
    await gate.WaitAsync(ct);
    try { using var lease = await store.AcquireWriteAsync(ct); return Read().Tickets; }
    finally { gate.Release(); }
  }
  public async Task<AgentWorkTicket> AcquireAsync(string session, string label, CancellationToken ct)
  {
    if (string.IsNullOrWhiteSpace(label) || label.Length > 120 || label.Any(char.IsControl)) throw new ArgumentException("Name the build or test in a few words.");
    await gate.WaitAsync(ct);
    try
    {
      using var lease = await store.AcquireWriteAsync(ct);
      var before = Read(); var rows = before.Tickets.Where(t => alive(t.SessionId) != false).ToList();
      if (rows.Count > 0) rows[0] = rows[0] with { Granted = true };
      if (rows.FirstOrDefault(t => t.SessionId == session) is { } held)
      {
        if (!before.Tickets.SequenceEqual(rows)) { store.Save(new(1, rows.ToArray())); Changed(); }
        HasTickets = true; return held;
      }
      var ticket = new AgentWorkTicket(Guid.NewGuid().ToString("D"), session, label.Trim(), DateTimeOffset.UtcNow, rows.Count == 0);
      rows.Add(ticket); HasTickets = true; store.Save(new(1, rows.ToArray())); Changed(); return ticket;
    }
    finally { gate.Release(); }
  }
  public async Task ReleaseAsync(string session, string ticket, bool owner, CancellationToken ct)
  {
    await gate.WaitAsync(ct);
    try
    {
      using var lease = await store.AcquireWriteAsync(ct); var state = Read();
      var current = state.Tickets.FirstOrDefault(t => t.Ticket == ticket) ?? throw new McpRefusal("This work ticket is no longer current.");
      if (!owner && current.SessionId != session) throw new McpRefusal("Another agent's work ticket is outside this session.");
      var rows = state.Tickets.Where(t => t.Ticket != ticket && alive(t.SessionId) != false).ToArray();
      if (rows.Length > 0) rows[0] = rows[0] with { Granted = true };
      HasTickets = rows.Length > 0; store.Save(new(1, rows)); Changed();
    }
    finally { gate.Release(); }
  }
  public async Task<AgentWorkTicket> WaitAsync(string session, string ticket, CancellationToken ct)
  {
    while (true)
    {
      Task next; lock (signalGate) next = changed.Task;
      var current = (await ListAsync(ct)).FirstOrDefault(t => t.Ticket == ticket && t.SessionId == session) ?? throw new McpRefusal("This work ticket is no longer current.");
      if (current.Granted) return current;
      await next.WaitAsync(ct);
    }
  }
}

public static class AgentHeavyWorkMcp
{
  public const string Id = "agents.work";
  public static IReadOnlyList<McpToolSpec> Specs => [new(Id, "agents_work", McpTier.Act, JsonDocument.Parse("""
    {"type":"object","properties":{"action":{"type":"string","enum":["list","acquire","wait","release"]},"label":{"type":"string","maxLength":120},"ticket":{"type":"string","maxLength":36}},"required":["action"],"additionalProperties":false}
    """).RootElement.Clone())];
  public static McpTier Tier(JsonElement args) => args.GetProperty("action").GetString() is "list" or "wait" ? McpTier.Read : McpTier.Act;
  public static void Register(AgentHeavyWork work, McpDoor door)
  {
    door.Register(Id, async (context, args, ct) =>
    {
      var session = context.Grant.SessionId ?? throw new McpRefusal("Use this tool from an agent's session.");
      context.Require("sessions", session);
      var action = args.GetProperty("action").GetString();
      var ticket = args.TryGetProperty("ticket", out var value) ? value.GetString() ?? "" : "";
      if (action == "list")
      {
        var rows = await work.ListAsync(ct);
        return JsonSerializer.SerializeToElement(new { busy = rows.Any(t => t.Granted), tickets = rows.Where(t => t.SessionId == session || context.Grant.OwnerApplication) });
      }
      if (action == "wait") return JsonSerializer.SerializeToElement(await work.WaitAsync(session, ticket, ct));
      await context.EnsureCurrentAsync(ct);
      if (action == "acquire") return JsonSerializer.SerializeToElement(await work.AcquireAsync(session, args.GetProperty("label").GetString() ?? "", ct));
      if (action == "release") { await work.ReleaseAsync(session, ticket, context.Grant.OwnerApplication, ct); return JsonSerializer.SerializeToElement(new { released = true }); }
      throw new McpRefusal("Choose a work-lock action.");
    });
  }
}
