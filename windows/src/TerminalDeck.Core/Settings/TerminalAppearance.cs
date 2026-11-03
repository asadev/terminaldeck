using System.Text.Json;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Settings;

public sealed record TerminalPalette(string Id, string Name, Dictionary<string, string> Colors);
public sealed record TerminalAppearanceState(string Scheme = "follow-app", string FontFamily = "", int FontSize = 13, TerminalPalette[]? Custom = null);
public sealed record TerminalAppearanceSnapshot(string FontFamily, int FontSize, double LineHeight, string CursorStyle, bool CursorBlink, int Scrollback, bool CopyOnSelect, Dictionary<string, string> Theme);

public sealed class TerminalAppearanceService(IStateStore<TerminalAppearanceState> store, Func<bool>? copyOnSelect = null)
{
  private readonly object gate = new();
  public event Action? Changed;
  public static string[] Slots { get; } = ["background", "foreground", "cursor", "cursorAccent", "selectionBackground", "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite"];
  public static TerminalPalette[] BuiltIns { get; } = LoadBuiltIns();
  public TerminalAppearanceState Preferences() { lock (gate) { var state = store.Load() ?? new(); return state with { Custom = (state.Custom ?? []).Select(Clone).ToArray(), FontSize = Math.Clamp(state.FontSize, 9, 24) }; } }
  public TerminalPalette[] Palettes() => BuiltIns.Select(Clone).Concat(Preferences().Custom ?? []).ToArray();
  public TerminalPalette Resolved(bool dark)
  {
    var state = Preferences(); var selected = (state.Custom ?? []).FirstOrDefault(p => p.Id == state.Scheme) ?? BuiltIns.FirstOrDefault(p => p.Id == state.Scheme);
    return Clone(selected ?? BuiltIns[dark ? 0 : 1]);
  }
  public TerminalAppearanceSnapshot Read(bool dark)
  {
    var state = Preferences(); return new(state.FontFamily, state.FontSize, 1.35, "block", true, 10000, copyOnSelect?.Invoke() ?? false, Resolved(dark).Colors);
  }
  public void Set(string? scheme = null, string? fontFamily = null, int? fontSize = null)
  {
    lock (gate)
    {
      var state = Preferences(); var id = scheme ?? state.Scheme;
      if (id != "follow-app" && !Palettes().Any(p => p.Id == id)) throw new ArgumentException("Choose a saved terminal palette.");
      var family = fontFamily ?? state.FontFamily;
      if (family.Length > 500 || family.Any(char.IsControl)) throw new ArgumentException("Use a bounded font-family name.");
      if (fontSize is < 9 or > 24) throw new ArgumentException("Use a terminal font size from 9 through 24.");
      store.Save(state with { Scheme = id, FontFamily = family.Trim(), FontSize = fontSize ?? state.FontSize });
    }
    Changed?.Invoke();
  }
  public TerminalPalette Import(string json)
  {
    if (json.Length > 65536) throw new ArgumentException("Keep a palette below 64 KB.");
    using var document = JsonDocument.Parse(json); var raw = document.RootElement;
    if (raw.ValueKind == JsonValueKind.Object && raw.TryGetProperty("schemes", out var schemes)) raw = schemes.ValueKind == JsonValueKind.Array && schemes.GetArrayLength() > 0 ? schemes[0] : throw new ArgumentException("The file contains no schemes.");
    if (raw.ValueKind != JsonValueKind.Object) throw new ArgumentException("A terminal palette must be a JSON object.");
    var fields = raw.TryGetProperty("colors", out var colors) && colors.ValueKind == JsonValueKind.Object ? colors : raw;
    var values = new Dictionary<string, string>();
    foreach (var slot in Slots)
    {
      var alias = slot switch { "cursor" => "cursorColor", "magenta" => "purple", "brightMagenta" => "brightPurple", _ => slot };
      if ((fields.TryGetProperty(slot, out var value) || fields.TryGetProperty(alias, out value)) && value.ValueKind == JsonValueKind.String) values[slot] = Color(value.GetString()!);
    }
    if (!values.ContainsKey("cursorAccent") && values.TryGetValue("background", out var background)) values["cursorAccent"] = background;
    if (!values.ContainsKey("selectionBackground") && values.TryGetValue("foreground", out var foreground)) values["selectionBackground"] = foreground[..7] + "40";
    var missing = Slots.Where(s => !values.ContainsKey(s)).ToArray(); if (missing.Length > 0) throw new ArgumentException("Missing colours: " + string.Join(", ", missing));
    var name = raw.TryGetProperty("name", out var named) && named.ValueKind == JsonValueKind.String ? named.GetString()! : "Imported scheme";
    lock (gate)
    {
      var state = Preferences(); var current = state.Custom ?? []; if (current.Length >= 40) throw new InvalidOperationException("At most 40 custom terminal palettes can be saved.");
      var id = 1; while (Palettes().Any(p => p.Id == "custom-" + id)) id++;
      var palette = Validate(new("custom-" + id, name, values)); store.Save(state with { Custom = [.. current, palette], Scheme = palette.Id }); Changed?.Invoke(); return Clone(palette);
    }
  }
  public TerminalPalette Copy(string id)
  { var palette = Palettes().Single(p => p.Id == id); return Import(JsonSerializer.Serialize(new { name = palette.Name + " (yours)", colors = palette.Colors })); }
  public void Edit(string id, string name, IReadOnlyDictionary<string, string> colors)
  {
    lock (gate)
    {
      var state = Preferences(); if (!(state.Custom ?? []).Any(p => p.Id == id)) throw new ArgumentException("Copy a built-in palette before editing it.");
      var palette = Validate(new(id, name, colors.ToDictionary(p => p.Key, p => p.Value))); store.Save(state with { Custom = state.Custom!.Select(p => p.Id == id ? palette : p).ToArray() });
    }
    Changed?.Invoke();
  }
  public void Remove(string id)
  {
    lock (gate) { var state = Preferences(); if (!(state.Custom ?? []).Any(p => p.Id == id)) throw new ArgumentException("Only custom palettes can be removed."); store.Save(state with { Scheme = state.Scheme == id ? "follow-app" : state.Scheme, Custom = state.Custom!.Where(p => p.Id != id).ToArray() }); }
    Changed?.Invoke();
  }
  public string Export(string id)
  {
    var palette = Palettes().Single(p => p.Id == id); var values = palette.Colors.ToDictionary(p => p.Key, p => p.Value); values["id"] = palette.Id; values["name"] = palette.Name; values["cursorColor"] = values["cursor"]; values["purple"] = values["magenta"]; values["brightPurple"] = values["brightMagenta"]; return JsonSerializer.Serialize(values, new JsonSerializerOptions { WriteIndented = true });
  }
  public void Reset() { lock (gate) { var state = Preferences(); store.Save(state with { Scheme = "follow-app", FontFamily = "", FontSize = 13 }); } Changed?.Invoke(); }
  private static TerminalPalette Validate(TerminalPalette palette)
  {
    var name = Regex.Replace(palette.Name.Trim(), @"\s+", " "); if (name.Length is < 1 or > 48 || name.Any(char.IsControl)) throw new ArgumentException("Use a palette name of 1–48 characters.");
    return new(palette.Id, name, Slots.ToDictionary(slot => slot, slot => palette.Colors.TryGetValue(slot, out var value) ? Color(value) : throw new ArgumentException("Missing colour " + slot)));
  }
  public static string Color(string text)
  {
    text = text.Trim().ToLowerInvariant(); if (!Regex.IsMatch(text, "^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$")) throw new ArgumentException("Use #RGB, #RGBA, #RRGGBB or #RRGGBBAA colours.");
    return text.Length is 4 or 5 ? "#" + string.Concat(text[1..].Select(c => new string(c, 2))) : text;
  }
  private static TerminalPalette Clone(TerminalPalette palette) => palette with { Colors = new(palette.Colors) };
  private static TerminalPalette[] LoadBuiltIns()
  {
    using var stream = typeof(TerminalAppearanceService).Assembly.GetManifestResourceStream("Settings.terminal-palettes.json") ?? throw new IOException("The terminal palette resource is missing.");
    return JsonSerializer.Deserialize<TerminalPalette[]>(stream, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!.Select(Validate).ToArray();
  }
}
