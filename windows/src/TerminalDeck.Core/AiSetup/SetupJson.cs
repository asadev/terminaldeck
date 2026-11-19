using System.Globalization;
using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.AiSetup;

/// The AI setup files' JSON, read and written the way the Mac's Foundation does it (JSONSerialization with
/// `.prettyPrinted, .sortedKeys, .withoutEscapingSlashes`), so a Mac and a PC make the same bytes from the same settings:
/// two-space indent, `"key" : value`, an empty object or list as `{` / `[`, a blank line and the closing mark, keys in
/// Foundation's order (letter case and width ignored, digits by value, then lower case first), a whole number as itself
/// and any other number with 17 significant digits, `/` left as it is.
public static class SetupJson
{
  /// A JSON object (keys as written, letter case counts).
  public sealed class Obj : Dictionary<string, object?>
  {
    public Obj() : base(StringComparer.Ordinal) { }
    public Obj(IDictionary<string, object?> copy) : base(copy, StringComparer.Ordinal) { }
  }
  /// A JSON number: a whole number read or made as one, or any other value.
  public readonly record struct Num(double Value, long? Whole = null)
  {
    public Num(long whole) : this(whole, whole) { }
  }
  /// JSON `null` (a value that is there), apart from a missing value.
  public sealed class Null { public static readonly Null Value = new(); private Null() { } }

  // ---- Reading ----

  /// The value of a JSON text (a leading UTF-8 byte-order mark is allowed), or null when it is not plain JSON.
  public static object? Parse(byte[] data)
  {
    var span = data.AsSpan();
    if (span.StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF])) span = span[3..];
    try
    {
      using var document = JsonDocument.Parse(span.ToArray(), new JsonDocumentOptions { MaxDepth = 256 });
      return From(document.RootElement);
    }
    catch (Exception e) when (e is JsonException or InvalidOperationException or ArgumentException or FormatException) { return null; }
  }
  private static object? From(JsonElement element)
  {
    switch (element.ValueKind)
    {
      case JsonValueKind.Object:
        var obj = new Obj();
        foreach (var property in element.EnumerateObject()) obj[property.Name] = From(property.Value);
        return obj;
      case JsonValueKind.Array: return element.EnumerateArray().Select(From).ToList();
      case JsonValueKind.String: return element.GetString();
      case JsonValueKind.Number:
        return element.TryGetInt64(out var whole) ? new Num(whole) : new Num(element.GetDouble());
      case JsonValueKind.True: return true;
      case JsonValueKind.False: return false;
      default: return Null.Value;
    }
  }

  /// A list whose every item is an object (Swift `as? [[String: Any]]`), else null.
  public static List<Obj>? ObjectList(object? value) => value is List<object?> list && list.All(i => i is Obj) ? list.Cast<Obj>().ToList() : null;
  /// A number's value (Foundation reads `true` and `false` as numbers too), else null.
  public static double? NumberValue(object? value) => value switch { Num n => n.Value, bool b => b ? 1 : 0, _ => null };
  /// Swift `Int(x.rounded())`: halves away from zero. Null when it is no whole number of 64 bits.
  public static Num? Rounded(double value)
  {
    var r = Math.Round(value, MidpointRounding.AwayFromZero);
    return double.IsFinite(r) && r >= long.MinValue && r < 9.2233720368547758E+18 ? new Num((long)r) : null;
  }

  /// Foundation's `isEqual`: the same keys and items, numbers by value (`true` is 1), text letter for letter.
  public static bool SameMeaning(object? a, object? b) => (a, b) switch
  {
    (Obj x, Obj y) => x.Count == y.Count && x.All(p => y.TryGetValue(p.Key, out var other) && SameMeaning(p.Value, other)),
    (List<object?> x, List<object?> y) => x.Count == y.Count && x.Zip(y).All(p => SameMeaning(p.First, p.Second)),
    (string x, string y) => string.Equals(x, y, StringComparison.Ordinal),
    (Null, Null) => true,
    _ => NumberValue(a) is { } m && NumberValue(b) is { } n && m == n
  };

  // ---- Writing ----

  private static readonly CompareInfo Collation = CultureInfo.InvariantCulture.CompareInfo;
  /// Foundation's key order: case, width and digits-as-numbers first; then lower case before upper; then code units.
  public static int CompareKeys(string a, string b)
  {
    var order = Collation.Compare(a, b, CompareOptions.IgnoreCase | CompareOptions.IgnoreWidth | CompareOptions.NumericOrdering);
    if (order == 0) order = Collation.Compare(a, b, CompareOptions.None);
    return order != 0 ? order : string.CompareOrdinal(a, b);
  }

  public static string Pretty(object? value)
  {
    var output = new StringBuilder();
    Write(output, value, 0);
    return output.ToString();
  }
  private static void Write(StringBuilder output, object? value, int level)
  {
    switch (value)
    {
      case Obj obj:
        output.Append("{\n");
        var keys = obj.Keys.ToList();
        keys.Sort(CompareKeys);
        for (var i = 0; i < keys.Count; i++)
        {
          if (i > 0) output.Append(",\n");
          output.Append(' ', (level + 1) * 2);
          Text(output, keys[i]);
          output.Append(" : ");
          Write(output, obj[keys[i]], level + 1);
        }
        output.Append('\n').Append(' ', level * 2).Append('}');
        break;
      case List<object?> list:
        output.Append("[\n");
        for (var i = 0; i < list.Count; i++)
        {
          if (i > 0) output.Append(",\n");
          output.Append(' ', (level + 1) * 2);
          Write(output, list[i], level + 1);
        }
        output.Append('\n').Append(' ', level * 2).Append(']');
        break;
      case string text: Text(output, text); break;
      case bool flag: output.Append(flag ? "true" : "false"); break;
      case Num number: output.Append(Number(number)); break;
      case long whole: output.Append(whole.ToString(CultureInfo.InvariantCulture)); break;
      default: output.Append("null"); break;
    }
  }
  /// `%.17g`, as Foundation writes a number that is not whole.
  private static string Number(Num number) => number.Whole is { } whole
    ? whole.ToString(CultureInfo.InvariantCulture)
    : number.Value.ToString("G17", CultureInfo.InvariantCulture).Replace('E', 'e');
  private static void Text(StringBuilder output, string text)
  {
    output.Append('"');
    foreach (var c in text)
      switch (c)
      {
        case '"': output.Append("\\\""); break;
        case '\\': output.Append("\\\\"); break;
        case '\b': output.Append("\\b"); break;
        case '\f': output.Append("\\f"); break;
        case '\n': output.Append("\\n"); break;
        case '\r': output.Append("\\r"); break;
        case '\t': output.Append("\\t"); break;
        case < ' ': output.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture)); break;
        default: output.Append(c); break;
      }
    output.Append('"');
  }
}
