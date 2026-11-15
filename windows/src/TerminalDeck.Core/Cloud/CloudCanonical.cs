using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace TerminalDeck.Core.Cloud;

// The byte-exact core shared with the Mac (TerminalDeckNativeCore CloudSyncCanonical.swift, CloudSecretsCanonical.swift,
// NativeRPCValue.parseJSON, CloudSyncSupport.swift CloudSyncBytes). Proven by the golden vectors
// (tests/TerminalDeck.Core.Tests/Fixtures/cloud-golden-vectors.json). Follows CloudSyncCanonical, never the older
// CloudWire.Canonical (which prints numbers differently).

/// A JSON value as the canonical form sees it. Numbers are IEEE doubles (as on the Mac: integers above 2^53 lose
/// precision, -0 prints 0). Object members keep their order and duplicates until the canonical form refuses them.
public abstract class CloudJson
{
  private CloudJson() { }
  public sealed class Null : CloudJson { public static readonly Null Value = new(); private Null() { } }
  public sealed class Bool(bool value) : CloudJson { public bool Value { get; } = value; }
  public sealed class Number(double value) : CloudJson { public double Value { get; } = value; }
  public sealed class String(string value) : CloudJson { public string Value { get; } = value; }
  public sealed class Array(IReadOnlyList<CloudJson> items) : CloudJson { public IReadOnlyList<CloudJson> Items { get; } = items; }
  public sealed class Object(IReadOnlyList<KeyValuePair<string, CloudJson>> members) : CloudJson
  {
    public IReadOnlyList<KeyValuePair<string, CloudJson>> Members { get; } = members;
    /// The member's value, or null when absent (the first one; the canonical form refuses duplicates anyway).
    public CloudJson? this[string key] => Members.FirstOrDefault(m => m.Key == key).Value;
    public Object Without(params string[] keys) => new(Members.Where(m => !keys.Contains(m.Key)).ToArray());
  }

  public static CloudJson From(string value) => new String(value);
  public static CloudJson From(double value) => new Number(value);
  public static CloudJson From(bool value) => new Bool(value);
  public static Object Obj(params (string Key, CloudJson? Value)[] members) =>
    // An absent optional member (null) is left out, never written as null, as Swift's JSONEncoder does.
    new(members.Where(m => m.Value is not null).Select(m => KeyValuePair.Create(m.Key, m.Value!)).ToArray());
  public static Array Arr(IEnumerable<CloudJson> items) => new(items.ToArray());

  public string? AsString => (this as String)?.Value;
  public double? AsNumber => (this as Number)?.Value;
  /// A whole number that fits a long exactly, or null.
  public long? AsInteger => this is Number { Value: var d } && d == Math.Floor(d) && Math.Abs(d) <= 9007199254740992d ? (long)d : null;

  /// Strict JSON text (RFC 8259) to a value. Refuses what the Mac's parser refuses: invalid syntax, a lone surrogate,
  /// a non-finite number, nesting deeper than 64 levels (NativeRPCValue.convert), more than 64 MiB.
  public static CloudJson Parse(ReadOnlySpan<byte> utf8)
  {
    if (utf8.Length > 67_108_864) throw new CloudFailure("invalid_request");
    string text;
    try { text = new UTF8Encoding(false, true).GetString(utf8); }
    catch (DecoderFallbackException) { throw new CloudFailure("invalid_request"); }
    var reader = new Reader(text);
    reader.Space();
    var value = reader.Value(0);
    reader.Space();
    if (!reader.End) throw new CloudFailure("invalid_request");
    return value;
  }
  public static CloudJson Parse(string text) => Parse(Encoding.UTF8.GetBytes(text));

  private sealed class Reader(string text)
  {
    private int at;
    public bool End => at == text.Length;
    private static CloudFailure Bad() => new("invalid_request");
    public void Space() { while (at < text.Length && text[at] is ' ' or '\t' or '\n' or '\r') at++; }
    private char Peek() => at < text.Length ? text[at] : throw Bad();
    private void Expect(string word) { if (string.CompareOrdinal(text, at, word, 0, word.Length) != 0) throw Bad(); at += word.Length; }
    public CloudJson Value(int depth)
    {
      if (depth > 64) throw Bad();
      switch (Peek())
      {
        case 'n': Expect("null"); return Null.Value;
        case 't': Expect("true"); return new Bool(true);
        case 'f': Expect("false"); return new Bool(false);
        case '"': return new String(Text());
        case '[':
          {
            at++; Space(); var items = new List<CloudJson>();
            if (Peek() == ']') { at++; return new Array(items); }
            while (true)
            {
              Space(); items.Add(Value(depth + 1)); Space();
              var c = Peek(); at++;
              if (c == ']') return new Array(items);
              if (c != ',') throw Bad();
            }
          }
        case '{':
          {
            at++; Space(); var members = new List<KeyValuePair<string, CloudJson>>();
            if (Peek() == '}') { at++; return new Object(members); }
            while (true)
            {
              Space(); if (Peek() != '"') throw Bad();
              var key = Text(); Space(); if (Peek() != ':') throw Bad(); at++; Space();
              members.Add(KeyValuePair.Create(key, Value(depth + 1))); Space();
              var c = Peek(); at++;
              if (c == '}') return new Object(members);
              if (c != ',') throw Bad();
            }
          }
        default: return new Number(NumberText());
      }
    }
    private double NumberText()
    {
      var start = at;
      if (at < text.Length && text[at] == '-') at++;
      if (at >= text.Length || !char.IsAsciiDigit(text[at])) throw Bad();
      if (text[at] == '0') at++; else while (at < text.Length && char.IsAsciiDigit(text[at])) at++;
      if (at < text.Length && text[at] == '.')
      {
        at++; if (at >= text.Length || !char.IsAsciiDigit(text[at])) throw Bad();
        while (at < text.Length && char.IsAsciiDigit(text[at])) at++;
      }
      if (at < text.Length && text[at] is 'e' or 'E')
      {
        at++; if (at < text.Length && text[at] is '+' or '-') at++;
        if (at >= text.Length || !char.IsAsciiDigit(text[at])) throw Bad();
        while (at < text.Length && char.IsAsciiDigit(text[at])) at++;
      }
      // Correctly rounded, like Swift's Double(String): 9007199254740993 becomes 9007199254740992.
      var value = double.Parse(text.AsSpan(start, at - start), NumberStyles.Float, CultureInfo.InvariantCulture);
      if (!double.IsFinite(value)) throw Bad();
      return value;
    }
    private string Text()
    {
      at++; var built = new StringBuilder();
      while (true)
      {
        var c = Peek(); at++;
        if (c == '"') break;
        if (c < 0x20) throw Bad();
        if (c != '\\') { built.Append(c); continue; }
        var e = Peek(); at++;
        switch (e)
        {
          case '"': built.Append('"'); break;
          case '\\': built.Append('\\'); break;
          case '/': built.Append('/'); break;
          case 'b': built.Append('\b'); break;
          case 'f': built.Append('\f'); break;
          case 'n': built.Append('\n'); break;
          case 'r': built.Append('\r'); break;
          case 't': built.Append('\t'); break;
          case 'u':
            if (at + 4 > text.Length || !ushort.TryParse(text.AsSpan(at, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var unit)) throw Bad();
            at += 4; built.Append((char)unit); break;
          default: throw Bad();
        }
      }
      var result = built.ToString();
      // A lone surrogate cannot be a Swift String: refused.
      for (var i = 0; i < result.Length; i++)
      {
        if (char.IsHighSurrogate(result[i])) { if (i + 1 >= result.Length || !char.IsLowSurrogate(result[i + 1])) throw Bad(); i++; }
        else if (char.IsLowSurrogate(result[i])) throw Bad();
      }
      return result;
    }
  }
}

/// RFC 8785 as the Mac writes it: members sorted by UTF-16 code units, strings escaped like JSON.stringify and written
/// as raw UTF-8 (no Unicode normalization), numbers printed like ECMAScript Number::toString.
public static class CloudCanonical
{
  public static byte[] Encode(CloudJson value)
  {
    var output = new List<byte>(256);
    Write(value, output);
    return output.ToArray();
  }
  /// Parses JSON text and writes its canonical form.
  public static byte[] EncodeJson(ReadOnlySpan<byte> utf8) => Encode(CloudJson.Parse(utf8));
  public static byte[] EncodeJson(string text) => Encode(CloudJson.Parse(text));

  private static void Write(CloudJson value, List<byte> output)
  {
    switch (value)
    {
      case CloudJson.Null: Ascii("null", output); break;
      case CloudJson.Bool b: Ascii(b.Value ? "true" : "false", output); break;
      case CloudJson.Number n: Ascii(Number(n.Value), output); break;
      case CloudJson.String s: Text(s.Value, output); break;
      case CloudJson.Array a:
        output.Add((byte)'[');
        for (var i = 0; i < a.Items.Count; i++) { if (i > 0) output.Add((byte)','); Write(a.Items[i], output); }
        output.Add((byte)']');
        break;
      case CloudJson.Object o:
        // Two keys that are the same text, or the same text with accents written another way (U+00E9 beside
        // e + U+0301), are refused: Swift compares keys by canonical equivalence (CloudSyncCanonical.swift:30).
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var member in o.Members) if (!seen.Add(Valid(member.Key).Normalize(NormalizationForm.FormD))) throw new CloudFailure("invalid_request");
        output.Add((byte)'{');
        var sorted = o.Members.OrderBy(m => m.Key, StringComparer.Ordinal).ToArray();
        for (var i = 0; i < sorted.Length; i++)
        {
          if (i > 0) output.Add((byte)',');
          Text(sorted[i].Key, output); output.Add((byte)':'); Write(sorted[i].Value, output);
        }
        output.Add((byte)'}');
        break;
      default: throw new CloudFailure("invalid_request");
    }
  }
  private static string Valid(string text)
  {
    for (var i = 0; i < text.Length; i++)
    {
      if (char.IsHighSurrogate(text[i])) { if (i + 1 >= text.Length || !char.IsLowSurrogate(text[i + 1])) throw new CloudFailure("invalid_request"); i++; }
      else if (char.IsLowSurrogate(text[i])) throw new CloudFailure("invalid_request");
    }
    return text;
  }
  private static void Ascii(string text, List<byte> output) { foreach (var c in text) output.Add((byte)c); }
  /// JSON.stringify's string form, byte by byte over UTF-8 (CloudSecretsCanonical.string): only `"`, `\`, \b \f \n \r \t
  /// and the other controls below 0x20 (as \u00xx, lower case) are escaped; '/', DEL and all non-ASCII stay raw.
  private static void Text(string text, List<byte> output)
  {
    output.Add((byte)'"');
    foreach (var b in Encoding.UTF8.GetBytes(Valid(text)))
    {
      switch (b)
      {
        case 0x22: output.Add(0x5C); output.Add(0x22); break;
        case 0x5C: output.Add(0x5C); output.Add(0x5C); break;
        case 0x08: output.Add(0x5C); output.Add((byte)'b'); break;
        case 0x0C: output.Add(0x5C); output.Add((byte)'f'); break;
        case 0x0A: output.Add(0x5C); output.Add((byte)'n'); break;
        case 0x0D: output.Add(0x5C); output.Add((byte)'r'); break;
        case 0x09: output.Add(0x5C); output.Add((byte)'t'); break;
        case < 0x20: Ascii("\\u00" + "0123456789abcdef"[b >> 4] + "0123456789abcdef"[b & 0x0F], output); break;
        default: output.Add(b); break;
      }
    }
    output.Add((byte)'"');
  }

  /// ECMAScript Number::toString (ES2023 6.1.6.1.20) from .NET's shortest round-trip digits, the same algorithm as
  /// CloudSecretsCanonical.ecmaScript over Swift's. NaN and the infinities are refused.
  public static string Number(double number)
  {
    if (!double.IsFinite(number)) throw new CloudFailure("invalid_request");
    if (number == 0) return "0"; // also -0
    var text = Math.Abs(number).ToString("R", CultureInfo.InvariantCulture); // e.g. "1.5", "1E-07", "1.2345678901234567E+19"
    var parts = text.Split('E');
    var exponent = parts.Length == 2 ? int.Parse(parts[1], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture) : 0;
    var mantissa = parts[0].Split('.');
    var whole = mantissa[0]; var fraction = mantissa.Length == 2 ? mantissa[1] : "";
    var digits = (whole + fraction).ToList();
    var point = whole.Length + exponent; // value = 0.digits x 10^point
    while (digits.Count > 0 && digits[0] == '0') { digits.RemoveAt(0); point--; }
    while (digits.Count > 0 && digits[^1] == '0') digits.RemoveAt(digits.Count - 1);
    if (digits.Count == 0) throw new CloudFailure("invalid_request");
    int k = digits.Count, n = point; var d = new string(digits.ToArray());
    string body;
    if (k <= n && n <= 21) body = d + new string('0', n - k);
    else if (0 < n && n <= 21) body = d[..n] + "." + d[n..];
    else if (-6 < n && n <= 0) body = "0." + new string('0', -n) + d;
    else
    {
      var e = n - 1;
      body = (k == 1 ? d : d[0] + "." + d[1..]) + "e" + (e < 0 ? "-" : "+") + Math.Abs(e).ToString(CultureInfo.InvariantCulture);
    }
    return (number < 0 ? "-" : "") + body;
  }
}

/// Byte helpers exactly as CloudSyncBytes / CloudSecretsCrypto use them.
public static class CloudBytes
{
  public static string Sha256Hex(ReadOnlySpan<byte> bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
  public static string Base64Url(ReadOnlySpan<byte> bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
  /// Strict base64url without padding (CloudSyncBytes.unbase64): only the 64 letters, never a length of 4n+1, and the
  /// text must be the one way of writing those bytes. The empty text is zero bytes.
  public static byte[] Unbase64(string text, int? count = null)
  {
    if (!text.All(c => c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_') || text.Length % 4 == 1) throw new CloudFailure("invalid_request");
    byte[] bytes;
    try { bytes = Convert.FromBase64String(text.Replace('-', '+').Replace('_', '/') + new string('=', (4 - text.Length % 4) % 4)); }
    catch (FormatException) { throw new CloudFailure("invalid_request"); }
    if (Base64Url(bytes) != text || (count is { } wanted && bytes.Length != wanted)) throw new CloudFailure("invalid_request");
    return bytes;
  }
  /// The 16 bytes of a UUID in RFC order (CloudSyncBytes.uuid, CloudSecretsCrypto.uuidBytes): the 36-character form,
  /// either case, as Foundation's UUID(uuidString:) reads it.
  public static byte[] Uuid(string text)
  {
    if (text.Length != 36 || !Guid.TryParseExact(text, "D", out var id)) throw new CloudFailure("invalid_request");
    return id.ToByteArray(bigEndian: true);
  }
  /// A transport id: a version-4, RFC-variant UUID (CloudSyncBytes.transportID).
  public static void TransportId(string text)
  {
    var bytes = Uuid(text);
    if (bytes[6] >> 4 != 4 || bytes[8] >> 6 != 2) throw new CloudFailure("invalid_request");
  }
  public static bool IsTransportId(string? text)
  {
    if (text is null) return false;
    try { TransportId(text); return true; } catch (CloudFailure) { return false; }
  }
  /// opId, segmentId, requestId, blobId: fresh random v4 UUIDs in lower case, never derived from content.
  public static string NewTransportId() => Guid.NewGuid().ToString("D");
}
