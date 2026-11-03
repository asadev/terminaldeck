using TerminalDeck.Core.Platform;

namespace TerminalDeck.Core.Sessions;

public enum SessionState { Starting, Running, Held, Exited }
public sealed record SessionDefinition(string Id, string Provider, string Cwd, string Title, string? AccountId = null,
  string? AccountHome = null, string? ConversationId = null, string? DeviceId = null, string? Purpose = null, string? InitialPrompt = null, string? Model = null, string? Effort = null, string? Permission = null, string? ServerId = null)
{
  public TerminalDeck.Core.Servers.ServerCodingTask? ServerCodingTask { get; init; }
  public string? ServerStartIn { get; init; }
  public void Validate()
  {
    if (ServerStartIn is not null) { if (ServerId is null) throw new ArgumentException("A remote folder needs a saved SSH server."); TerminalDeck.Core.Servers.ServerValidation.Path(ServerStartIn); }
    if (ServerCodingTask is not null) { if (ServerId is null) throw new ArgumentException("Coding AI setup needs a saved SSH server."); ServerCodingTask.Validate(); }
    if (ServerId is not null && (Provider != "shell" || !Guid.TryParseExact(ServerId, "N", out _)) || !Guid.TryParse(Id, out _) || (Provider is not ("claude" or "codex" or "gemini" or "shell") && !CustomTerminalProviders.IsKey(Provider)) ||
      string.IsNullOrWhiteSpace(Cwd) || Cwd.Contains('\0') || Title.Length > 120 || Title.Any(char.IsControl) ||
      Purpose is not (null or "sign-in") || InitialPrompt is { Length: > 8000 } || InitialPrompt?.Contains('\0') == true || Model is { Length: > 128 } || Effort is not (null or "low" or "medium" or "high" or "xhigh" or "max") || Permission is not (null or "ask" or "plan" or "auto" or "acceptEdits" or "bypass") || ConversationId is { Length: > 128 } || AccountId is { Length: > 128 })
      throw new ArgumentException("Choose a valid session, folder and provider.");
  }
}

public sealed record SessionRecord(SessionDefinition Definition, string CreationKey, SessionState State,
  string? LeaseIdentity = null, string Replay = "", int? ExitCode = null, long CreatedAt = 0, bool HasStarted = false, bool Resume = false, long AccountRevision = 0, string? LastAccountSwitch = null,
  SessionDefinition? PendingAccount = null, string? PendingAccountSwitch = null, string ReplayPrefix = "", bool AccountRollback = false, TerminalSize? ReplaySize = null,
  bool DeclaredConversation = false);
// What the update check needs to know about one open terminal right now. Ages are
// milliseconds; null means never seen since this keeper started. OutputRunMs is how
// long the latest unbroken stretch of output has lasted (an AI at work repaints all
// the time; a single redraw is short). ProviderBusy is what the AI itself reports.
public sealed record SessionActivity(string Id, string Provider, string Title, long? OutputAgeMs = null, long? OutputRunMs = null,
  long? InputAgeMs = null, bool? ProviderBusy = null);
public sealed record SessionLedger(int Version, ulong Sequence, SessionRecord[] Sessions);
public sealed record SessionEvent(ulong Sequence, string Id, string Kind, string? Text = null, int? ExitCode = null, TerminalSize? ReplaySize = null);
public sealed record SessionSnapshot(ulong Sequence, SessionRecord Session, string Replay);
public enum ProcessPresence { Live, Dead, Unknown }
// ProcessId/ProcessStartedAt name the terminal's own program (the AI itself for an
// AI session), so the AI's own status file can be matched to this exact session.
public sealed record ProcessObservation(ProcessPresence Presence, string? LeaseIdentity = null,
  bool ForegroundBusy = false, int BackgroundChildren = 0, bool ActivityKnown = true, int? ProcessId = null, long? ProcessStartedAt = null)
{
  public bool Idle => Presence == ProcessPresence.Live && ActivityKnown && !ForegroundBusy && BackgroundChildren == 0;
}

// The platform owns durable process leases. A PID alone is never evidence of identity.
// Ensure is idempotent by creationKey, including a lost reply before journal update.
// Observe must include descendants, and Unknown must never be treated as Dead.
public interface ISessionProcessKeeper
{
  ValueTask<ProcessObservation> ObserveAsync(SessionRecord session, CancellationToken cancellationToken);
  ValueTask<ProcessObservation> EnsureAsync(SessionRecord session, bool resume, CancellationToken cancellationToken);
  ValueTask WriteAsync(string leaseIdentity, ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken);
  ValueTask ResizeAsync(string leaseIdentity, TerminalSize size, CancellationToken cancellationToken);
  ValueTask QuitAsync(string leaseIdentity, CancellationToken cancellationToken);
}
