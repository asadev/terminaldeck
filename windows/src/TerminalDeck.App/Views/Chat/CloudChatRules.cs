using System.Text.Json;

namespace TerminalDeck.App.Views.Chat;

// The Cloud chat page's rules (DESIGN-WINDOWS-CLOUD.md 5), plain .NET so Core.Tests run them without a window.
// - The bar: the session's name; ONE secondary line "Runs on Mac mini" or "Runs on Mac mini, which is off".
// - Its machine is off, or this PC has no live way to it: read only (no message box, no send button, no line saying so).
// - Its machine is on and a live link is open: the app's own composer, no model / effort / permission chips; a permission
//   question shows WHAT it asks with "Deny" and "Allow" only.
// - No "Switch to this PC" (left out by decision).

public sealed record CloudChatLook(string Name, string RunsOn, bool ReadOnly);

public sealed record CloudChatLine(bool Person, string Text, double At, long Sequence);

public static class CloudChatRules
{
  public static string RunsOn(string machine, bool on) => "Runs on " + machine + (on ? "" : ", which is off");

  /// `liveLink`: this PC holds an open live link to that machine (reach by sign-in). Without one the page is the Cloud copy.
  public static CloudChatLook For(string name, string machine, bool machineOn, bool liveLink) =>
    new(string.IsNullOrWhiteSpace(name) ? "Untitled session" : name.Trim(), RunsOn(machine, machineOn), !(machineOn && liveLink));

  /// The readable copy's event lines (version 1, as the phones draw them) as chat lines: the person's messages and the
  /// AI's answers only, in order, each sequence once.
  public static IReadOnlyList<CloudChatLine> Lines(IEnumerable<JsonElement> events)
  {
    var lines = new SortedDictionary<long, CloudChatLine>();
    foreach (var e in events)
    {
      if (e.ValueKind != JsonValueKind.Object) continue;
      var kind = Text(e, "kind");
      if (kind is not ("user" or "message")) continue;
      if (!e.TryGetProperty("value", out var value) || value.ValueKind != JsonValueKind.Object || Text(value, "text") is not { Length: > 0 } text) continue;
      var sequence = e.TryGetProperty("sequence", out var s) && s.ValueKind == JsonValueKind.Number ? (long)s.GetDouble() : lines.Count + 1;
      var at = e.TryGetProperty("at", out var a) && a.ValueKind == JsonValueKind.Number ? a.GetDouble() : 0;
      lines[sequence] = new(kind == "user", text, at, sequence);
    }
    return lines.Values.ToArray();
  }

  /// The permission card's two answers; nothing else is sent to the other machine.
  public static readonly IReadOnlyList<string> PermissionAnswers = ["Deny", "Allow"];

  private static string? Text(JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
}
