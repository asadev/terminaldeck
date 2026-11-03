using System.Collections.Concurrent;
using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Notifications;

public sealed record NotificationPreferences(bool NeedsYou = true, bool Finished = true, bool Hoot = true, bool TaskMentions = true, bool Preview = false, bool OnlyWhenAway = true, string Sound = "default", bool PlaySound = true);
public sealed record SessionNotice(string Id, string SessionId, string Kind, string Title, string Detail, DateTimeOffset At);
public sealed record NotificationTestResult(bool Accepted, string Message);
public interface ISessionNotificationSink
{
  ValueTask ShowAsync(SessionNotice notice, string sound, CancellationToken ct);
  ValueTask<NotificationTestResult> TestAsync(string sound, bool soundOnly, CancellationToken ct) => ValueTask.FromResult(new NotificationTestResult(false, "This notification sink cannot check delivery."));
}
public sealed record SessionNotificationObservation(string Id, string Title, bool Busy, bool Waiting, bool Ended = false, string? Detail = null, bool Hoot = false);

// Native toasts, desktop settings and MCP use one persisted preference owner.
// Transition memory starts with a baseline; opening the app never replays old
// finished sessions as new notifications or starts an AI turn.
public sealed partial class SessionNotifications(IStateStore<NotificationPreferences> store, ISessionNotificationSink sink, Func<bool> focused)
{
  private readonly object gate = new();
  private readonly Dictionary<string, SessionNotificationObservation> observations = [];
  private readonly ConcurrentDictionary<string, byte> sent = new();
  public event Action? Changed;
  public NotificationPreferences Read()
  { var value = store.Load() ?? new(); return value.Sound == "none" ? value with { Sound = "chime", PlaySound = false } : value; }
  public NotificationPreferences Save(NotificationPreferences value)
  {
    if (value.Sound is not ("default" or "im" or "reminder" or "chime" or "blip" or "knock" or "none")) throw new ArgumentException("Choose a supported notification sound.");
    store.Save(value); Changed?.Invoke(); return value;
  }
  public async ValueTask ObserveAsync(SessionNotificationObservation next, CancellationToken ct = default)
  {
    SessionNotificationObservation? previous;
    lock (gate) { observations.TryGetValue(next.Id, out previous); observations[next.Id] = next; if (observations.Count > 4096) foreach (var id in observations.Where(p => p.Value.Ended).Select(p => p.Key).Take(1024).ToArray()) observations.Remove(id); }
    if (previous is null || next.Ended) return;
    var kind = !previous.Waiting && next.Waiting ? "needs-you" : previous.Busy && !next.Busy && !next.Waiting ? next.Hoot ? "hoot" : "finished" : null;
    if (kind is null) return;
    await NotifyAsync(new(Guid.NewGuid().ToString("N"), next.Id, kind, next.Title, next.Detail ?? "", DateTimeOffset.UtcNow), ct);
  }
  public async ValueTask NotifyAsync(SessionNotice notice, CancellationToken ct = default)
  {
    ct.ThrowIfCancellationRequested(); var settings = Read();
    if (!(notice.Kind switch { "needs-you" => settings.NeedsYou, "finished" => settings.Finished, "hoot" => settings.Hoot, "mention" => settings.TaskMentions, _ => false }) || settings.OnlyWhenAway && focused()) return;
    if (!sent.TryAdd(notice.Id, 0)) return;
    if (sent.Count > 4096) sent.Clear();
    var safe = notice with { Title = Clean(notice.Title, 120), Detail = settings.Preview ? TerminalDeck.Core.Remote.PhonePushFeatures.Redact(Clean(notice.Detail, 1000)) : notice.Kind == "needs-you" ? "Open the app to answer." : "Open the app to see it." };
    await sink.ShowAsync(safe, settings.PlaySound ? settings.Sound : "none", ct);
  }
  private static string Clean(string text, int max) => new(text.Where(c => !char.IsControl(c)).Take(max).ToArray());
}
public static class NotificationTools
{
  public static IReadOnlyList<McpToolSpec> Specs => [
    new("notifications.read", "notifications_read", McpTier.Read, JsonSerializer.SerializeToElement(new { type = "object", properties = new { }, additionalProperties = false })),
    new("notifications.set", "notifications_set", McpTier.Alter, JsonDocument.Parse("""{"type":"object","properties":{"needsYou":{"type":"boolean"},"finished":{"type":"boolean"},"hoot":{"type":"boolean"},"taskMentions":{"type":"boolean"},"preview":{"type":"boolean"},"onlyWhenAway":{"type":"boolean"},"playSound":{"type":"boolean"},"sound":{"type":"string","enum":["default","im","reminder","chime","blip","knock","none"]}},"additionalProperties":false}""").RootElement.Clone())
    ,new("notifications.test", "notifications_test", McpTier.Act, JsonDocument.Parse("""{"type":"object","properties":{"kind":{"type":"string","enum":["banner","sound","settings"]}},"required":["kind"],"additionalProperties":false}""").RootElement.Clone())
  ];
}
