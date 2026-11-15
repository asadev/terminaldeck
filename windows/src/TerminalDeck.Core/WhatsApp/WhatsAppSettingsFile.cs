using System.Text.Json;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.WhatsApp;

/// The synced settings door on Windows (the Mac's BackendWhatsAppSettingsStore): one setting `whatsapp.agent.&lt;id&gt;` per
/// agent, a JSON text in the Mac's shape, kept in one file of the app's data folder. The same settings travel through
/// Cloud as the Mac's (`setting:whatsapp.agent.&lt;id&gt;`, field `value`), through CloudSettingsOwner's family
/// (CloudFamily below): newest change wins on every computer. Never a key.
public sealed class WhatsAppSettingsFile : IWhatsAppSettingsPort
{
  public const string Prefix = "whatsapp.agent.";
  private readonly string? file;
  private readonly Lock gate = new();
  private Dictionary<string, string> values;
  private readonly List<Action> observers = [];

  /// `file` null = in memory (tests).
  public WhatsAppSettingsFile(string? file)
  {
    this.file = file;
    values = Load(file);
  }
  private static Dictionary<string, string> Load(string? file)
  {
    try { return file is not null && File.Exists(file) ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllBytes(file)) ?? [] : []; }
    catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException) { return []; }
  }
  private void Save()
  {
    if (file is null) return;
    Directory.CreateDirectory(Path.GetDirectoryName(file)!);
    new CloudFileSlot(file).Write(JsonSerializer.SerializeToUtf8Bytes(values.OrderBy(v => v.Key, StringComparer.Ordinal).ToDictionary(v => v.Key, v => v.Value)));
  }
  private void Tell() { Action[] all; lock (gate) all = observers.ToArray(); foreach (var o in all) o(); }

  public Task<IReadOnlyList<WhatsAppAgentRecord>> RecordsAsync()
  {
    lock (gate)
      return Task.FromResult<IReadOnlyList<WhatsAppAgentRecord>>(values
        .Select(v => (v.Key, Record: WhatsAppAgentRecord.FromJson(v.Value)))
        .Where(v => v.Record is { } r && v.Key == Prefix + r.Id && WhatsAppAgentIds.Valid(r.Id))
        .Select(v => v.Record!).ToArray());
  }
  public Task SaveAsync(WhatsAppAgentRecord record)
  {
    var text = record.ToJson();
    if (text.Length > 16_384) throw new WhatsAppProblem("That name is too long.");
    lock (gate) { values[Prefix + record.Id] = text; Save(); }
    Tell();
    return Task.CompletedTask;
  }
  public void Observe(Action changed) { lock (gate) observers.Add(changed); }

  // ---- Cloud: the family of settings `setting:whatsapp.agent.<id>` ----

  /// What CloudSettingsOwner reads and writes: every record as its JSON text, by setting key.
  public IReadOnlyDictionary<string, CloudJson> CloudValues() { lock (gate) return values.ToDictionary(v => v.Key, v => (CloudJson)CloudJson.From(v.Value)); }
  /// A value from another computer (already accepted by CloudAccepts).
  public void CloudWrite(string key, CloudJson value)
  {
    if (CloudRecordJson.Text(value) is not { } text || !CloudAccepts(key, value)) throw new ArgumentException("This WhatsApp agent's setting is not one this PC can use.");
    lock (gate) { values[key] = text; Save(); }
    Tell();
  }
  /// A value this PC can use: a record in the Mac's shape whose id names this key.
  public static bool CloudAccepts(string key, CloudJson value) =>
    CloudRecordJson.Text(value) is { Length: <= 16_384 } text && WhatsAppAgentRecord.FromJson(text) is { } r && key == Prefix + r.Id && WhatsAppAgentIds.Valid(r.Id);

  public CloudSettingFamily CloudFamily() => new("setting:" + Prefix, CloudValues, CloudWrite, CloudAccepts);
}
