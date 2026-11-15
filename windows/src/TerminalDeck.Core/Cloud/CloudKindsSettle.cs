using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

/// "Send the settled value" (the Mac's BackendCloudKindsSettle): a task or setting is handed on only after it has stayed the
/// same for `quiet` milliseconds. Until then the owner keeps answering with the value it last handed on, so a value that
/// flickers (a slider dragged, a task an agent keeps updating) becomes ONE record, not dozens. A record seen for the first
/// time, and a removal, go at once.
public sealed class CloudKindsSettle(double quiet, Func<double> now)
{
  private readonly object gate = new();
  private readonly Dictionary<string, CloudJson.Object> shown = new(StringComparer.Ordinal);
  private readonly Dictionary<string, (CloudJson.Object Value, double Since)> seen = new(StringComparer.Ordinal);

  /// `same`: the part of a value whose change counts (a task's `updatedAt` alone never restarts the wait).
  public Dictionary<string, CloudJson.Object> Pass(IReadOnlyDictionary<string, CloudJson.Object> current, Func<CloudJson.Object, CloudJson.Object, bool> same)
  {
    lock (gate)
    {
      if (quiet <= 0)
      {
        shown.Clear(); seen.Clear();
        foreach (var (entity, value) in current) shown[entity] = value;
        return new(current, StringComparer.Ordinal);
      }
      var time = now();
      var result = new Dictionary<string, CloudJson.Object>(StringComparer.Ordinal);
      foreach (var (entity, value) in current)
      {
        if (!shown.TryGetValue(entity, out var before)) { shown[entity] = value; result[entity] = value; continue; }
        if (same(before, value)) { shown[entity] = value; seen.Remove(entity); result[entity] = value; continue; }
        if (seen.TryGetValue(entity, out var waiting) && same(waiting.Value, value))
        {
          if (time - waiting.Since >= quiet) { shown[entity] = value; seen.Remove(entity); result[entity] = value; }
          else result[entity] = before;
        }
        else { seen[entity] = (value, time); result[entity] = before; }
      }
      foreach (var entity in shown.Keys.Where(e => !current.ContainsKey(e)).ToArray()) { shown.Remove(entity); seen.Remove(entity); }
      return result;
    }
  }
  /// A value written here from the Cloud is this PC's value at once (never handed back as a change of its own).
  public void Wrote(string entity, CloudJson.Object? value)
  {
    lock (gate)
    {
      if (value is null) shown.Remove(entity); else shown[entity] = value;
      seen.Remove(entity);
    }
  }
}

/// The Mac's BackendCloudKindsKept: when a value from another device replaces a different value here, the value this PC
/// had is written to one small file on this PC and kept for 30 days. Costs no Cloud writes; never sent.
public sealed class CloudKindsKept(string file, Func<long> now)
{
  public sealed record Entry(string Record, string Value, long ReplacedAt, long KeptUntil);
  public const long Days = 30;
  public const int MaximumEntries = 2_000;
  private readonly object gate = new();

  private List<Entry> Read()
  {
    try { return File.Exists(file) ? JsonSerializer.Deserialize<List<Entry>>(File.ReadAllBytes(file)) ?? [] : []; }
    catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException) { return []; }
  }
  public IReadOnlyList<Entry> Entries() { lock (gate) { var at = now(); return Read().Where(e => e.KeptUntil > at).ToArray(); } }
  public void Keep(string record, CloudJson value)
  {
    lock (gate)
    {
      var at = now();
      var all = Read().Where(e => e.KeptUntil > at).ToList();
      all.Add(new(record, CloudRecordJson.Encode(value), at, at + Days * 86_400_000));
      if (all.Count > MaximumEntries) all.RemoveRange(0, all.Count - MaximumEntries);
      new CloudFileSlot(file).Write(JsonSerializer.SerializeToUtf8Bytes(all));
    }
  }
}
