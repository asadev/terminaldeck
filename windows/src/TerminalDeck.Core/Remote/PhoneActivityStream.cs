using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

// The phone's Activity page and Overview glance (capability `activity`, as the
// Mac's BackendPhoneActivity): `activity.watch {top}` starts a 2-second stream of
// `activity.sample` to that connection, `activity.unwatch` (or the connection
// closing) ends it. Nothing is read while no phone is watching.
public sealed class PhoneActivityStream : IDisposable
{
  public static readonly TimeSpan Beat = TimeSpan.FromSeconds(2);
  private readonly ISystemActivityReader reader;
  private readonly Func<string, byte[], ValueTask> send;
  private readonly ConcurrentDictionary<string, bool> watchers = new();
  private readonly object gate = new();
  private CancellationTokenSource? clock;

  public PhoneActivityStream(ISystemActivityReader reader, Func<string, byte[], ValueTask> send) { this.reader = reader; this.send = send; }

  public int Watching => watchers.Count;

  // The first frame at once, so the page is not empty for two seconds.
  public JsonObject Watch(string channel, bool top)
  {
    watchers[channel] = top;
    Start();
    return Frame(Read(top));
  }

  public void Unwatch(string channel)
  {
    watchers.TryRemove(channel, out _);
    lock (gate) if (watchers.IsEmpty && clock is not null) { clock.Cancel(); clock.Dispose(); clock = null; }
  }

  private void Start()
  {
    CancellationToken token;
    lock (gate)
    {
      if (clock is not null) return;
      clock = new CancellationTokenSource(); token = clock.Token;
    }
    _ = Task.Run(async () =>
    {
      try
      {
        while (!token.IsCancellationRequested)
        {
          await Task.Delay(Beat, token);
          if (watchers.IsEmpty) continue;
          // One reading a beat for everyone; the process table only when somebody has the full page open.
          var reading = Read(watchers.Values.Any(top => top));
          var lean = (JsonObject)reading.DeepClone(); lean.Remove("topCPU"); lean.Remove("topMemory");
          foreach (var (channel, top) in watchers)
            await send(channel, JsonSerializer.SerializeToUtf8Bytes(Frame(top ? reading : lean)));
        }
      }
      catch (OperationCanceledException) { }
    }, CancellationToken.None);
  }

  private JsonObject Read(bool top)
  {
    try { return reader.Sample(top); }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
    { return new JsonObject { ["at"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), ["cpu"] = new JsonObject { ["total"] = null, ["cores"] = new JsonArray(), ["count"] = 0 }, ["memory"] = new JsonObject() }; }
  }

  public static JsonObject Frame(JsonObject reading)
  {
    var frame = new JsonObject { ["t"] = "activity.sample" };
    foreach (var (key, value) in reading) frame[key] = value?.DeepClone();
    return frame;
  }

  public void Dispose() { watchers.Clear(); lock (gate) { clock?.Cancel(); clock?.Dispose(); clock = null; } }
}
