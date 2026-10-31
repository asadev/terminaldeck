using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Receiver;

public enum ReceiverConditionOperation { Is, IsNot, Contains, DoesNotContain, StartsWith, MatchesPattern, IsPresent, IsMissing, IsOneOf, IsAbove, IsBelow, IsAtLeast }
public sealed record ReceiverCondition(string Path, ReceiverConditionOperation Operation, string Value = "");

public static class ReceiverConditions
{
  public static string Label(ReceiverConditionOperation operation) => operation switch
  {
    ReceiverConditionOperation.Is => "is", ReceiverConditionOperation.IsNot => "is not",
    ReceiverConditionOperation.Contains => "contains", ReceiverConditionOperation.DoesNotContain => "does not contain",
    ReceiverConditionOperation.StartsWith => "starts with", ReceiverConditionOperation.MatchesPattern => "matches pattern",
    ReceiverConditionOperation.IsPresent => "is present", ReceiverConditionOperation.IsMissing => "is missing",
    ReceiverConditionOperation.IsOneOf => "is one of", ReceiverConditionOperation.IsAbove => "is above",
    ReceiverConditionOperation.IsBelow => "is below", ReceiverConditionOperation.IsAtLeast => "is at least",
    _ => throw new ArgumentException("Choose a condition operation.")
  };
  public static void Validate(ReceiverCondition condition)
  {
    ReceiverStore.Check(condition.Path, 240); ReceiverStore.Check(condition.Value, 1000, true);
    if (!Enum.IsDefined(condition.Operation) || Parts(condition.Path).Length == 0) throw new ArgumentException("Choose a payload path and operation.");
    if (condition.Operation is ReceiverConditionOperation.IsAbove or ReceiverConditionOperation.IsBelow or ReceiverConditionOperation.IsAtLeast && !Number(condition.Value, out _))
      throw new ArgumentException("Enter a number for this condition.");
    if (condition.Operation == ReceiverConditionOperation.MatchesPattern)
      try { _ = new Regex(condition.Value, RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50)); }
      catch (ArgumentException) { throw new ArgumentException("Enter a valid condition pattern."); }
  }
  public static bool Matches(ReceiverDraft draft, IReadOnlyList<ReceiverCondition> conditions)
  {
    if (conditions.Count == 0) return true;
    try
    {
      using var parsed = draft.Payload is null ? JsonDocument.Parse(draft.Text, new JsonDocumentOptions { MaxDepth = 32 }) : null;
      var payload = draft.Payload ?? parsed!.RootElement;
      return conditions.All(c => Match(payload, c));
    }
    catch (JsonException) { return conditions.All(c => c.Operation == ReceiverConditionOperation.IsMissing); }
  }
  public static string[] Paths(ReceiverDraft draft)
  {
    try
    {
      using var parsed = draft.Payload is null ? JsonDocument.Parse(draft.Text, new JsonDocumentOptions { MaxDepth = 32 }) : null;
      var result = new List<string>(); Visit(draft.Payload ?? parsed!.RootElement, "", result, 0); return result.ToArray();
    }
    catch (JsonException) { return []; }
  }
  private static void Visit(JsonElement value, string path, List<string> result, int depth)
  {
    if (depth >= 12 || result.Count >= 200) return;
    if (path.Length > 0) result.Add(path);
    if (value.ValueKind == JsonValueKind.Object)
      foreach (var property in value.EnumerateObject().Take(200))
        if (!property.Name.Contains('.') && !property.Name.Contains('[') && !property.Name.Contains(']'))
          Visit(property.Value, path.Length == 0 ? property.Name : path + "." + property.Name, result, depth + 1);
    if (value.ValueKind == JsonValueKind.Array)
      for (var i = 0; i < Math.Min(20, value.GetArrayLength()); i++) Visit(value[i], path + $"[{i}]", result, depth + 1);
  }
  private static string[] Parts(string path) => path.Trim().TrimStart('$').TrimStart('.').Replace("[", ".", StringComparison.Ordinal).Replace("]", "", StringComparison.Ordinal).Split('.', StringSplitOptions.RemoveEmptyEntries);
  private static bool Match(JsonElement payload, ReceiverCondition condition)
  {
    var value = payload; var exists = true;
    foreach (var part in Parts(condition.Path))
    {
      if (value.ValueKind == JsonValueKind.Object && value.TryGetProperty(part, out var property)) value = property;
      else if (value.ValueKind == JsonValueKind.Array && int.TryParse(part, out var index) && index >= 0 && index < value.GetArrayLength()) value = value[index];
      else { exists = false; break; }
    }
    // Null is present, and a missing field never satisfies a negative text test.
    if (condition.Operation == ReceiverConditionOperation.IsPresent) return exists;
    if (condition.Operation == ReceiverConditionOperation.IsMissing) return !exists;
    if (!exists) return false;
    var actual = value.ValueKind == JsonValueKind.String ? value.GetString()! : value.GetRawText();
    var wanted = condition.Value;
    return condition.Operation switch
    {
      ReceiverConditionOperation.Is => actual.Equals(wanted, StringComparison.OrdinalIgnoreCase),
      ReceiverConditionOperation.IsNot => !actual.Equals(wanted, StringComparison.OrdinalIgnoreCase),
      ReceiverConditionOperation.Contains => actual.Contains(wanted, StringComparison.OrdinalIgnoreCase),
      ReceiverConditionOperation.DoesNotContain => !actual.Contains(wanted, StringComparison.OrdinalIgnoreCase),
      ReceiverConditionOperation.StartsWith => actual.StartsWith(wanted, StringComparison.OrdinalIgnoreCase),
      ReceiverConditionOperation.MatchesPattern => Pattern(actual, wanted),
      ReceiverConditionOperation.IsOneOf => wanted.Split(',', StringSplitOptions.TrimEntries).Any(v => actual.Equals(v, StringComparison.OrdinalIgnoreCase)),
      ReceiverConditionOperation.IsAbove => Number(actual, out var n) && Number(wanted, out var limit) && n > limit,
      ReceiverConditionOperation.IsBelow => Number(actual, out var n) && Number(wanted, out var limit) && n < limit,
      ReceiverConditionOperation.IsAtLeast => Number(actual, out var n) && Number(wanted, out var limit) && n >= limit,
      _ => false
    };
  }
  private static bool Number(string value, out decimal number) => decimal.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out number);
  private static bool Pattern(string value, string pattern)
  {
    try { return Regex.IsMatch(value, pattern, RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50)); }
    catch (Exception ex) when (ex is ArgumentException or RegexMatchTimeoutException) { return false; }
  }
}
