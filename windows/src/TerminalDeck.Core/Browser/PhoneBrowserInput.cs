using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Browser;

public sealed record BrowserInputCommand(string Method, JsonObject Arguments);
public static class PhoneBrowserInput
{
  public static JsonElement ForFrame(JsonElement message, double scale)
  {
    if (!double.IsFinite(scale) || scale <= 0) throw new PhoneRefusal("unavailable", "That browser frame has no usable input scale.");
    _ = Command(message);
    var result = JsonNode.Parse(message.GetRawText())!.AsObject();
    if (result["mouse"] is JsonObject mouse)
      foreach (var field in new[] { "x", "y", "dx", "dy" }) if (mouse[field] is { } value) mouse[field] = JsonSerializer.Deserialize<double>(value.ToJsonString()) / scale;
    if (result["touch"] is JsonObject touch && touch["points"] is JsonArray points)
      foreach (var point in points.OfType<JsonObject>()) foreach (var field in new[] { "x", "y" }) point[field] = JsonSerializer.Deserialize<double>(point[field]!.ToJsonString()) / scale;
    return JsonSerializer.SerializeToElement(result);
  }
  public static BrowserInputCommand Command(JsonElement message)
  {
    var present = new[] { "mouse", "key", "touch", "paste" }.Where(k => message.TryGetProperty(k, out _)).ToArray();
    if (present.Length != 1) throw new PhoneRefusal("bad-message", "Send exactly one mouse, key, touch or paste event.");
    var kind = present[0]; var item = message.GetProperty(kind);
    if (kind == "paste")
    {
      if (item.ValueKind != JsonValueKind.String || item.GetString() is not { } raw || Encoding.UTF8.GetByteCount(raw) > 16384) throw new PhoneRefusal("bad-message", "Paste up to 16 KB of text.");
      var text = new string(raw.Where(c => c is '\t' or '\n' or '\r' || !char.IsControl(c)).ToArray());
      return new("Input.insertText", new() { ["text"] = text });
    }
    if (item.ValueKind != JsonValueKind.Object) throw new PhoneRefusal("bad-message", "The input event must be an object.");
    string Text(string key, string fallback = "")
    {
      if (!item.TryGetProperty(key, out var value)) return fallback;
      if (value.ValueKind != JsonValueKind.String || value.GetString() is not { Length: <= 64 } text) throw new PhoneRefusal("bad-message", "A key field must be a short string.");
      return text;
    }
    double Number(string key, double fallback = 0, bool required = false)
    {
      if (!item.TryGetProperty(key, out var value)) return required ? throw new PhoneRefusal("bad-message", "Missing input position.") : fallback;
      if (value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out var n) || !double.IsFinite(n)) throw new PhoneRefusal("bad-message", "Input positions must be finite numbers.");
      return Math.Clamp(n, -100000, 100000);
    }
    var type = Text("type");
    if (kind == "mouse")
    {
      var button = Text("button", type is "down" or "up" ? "left" : "none"); if (button is not ("left" or "right" or "middle" or "none")) throw new PhoneRefusal("bad-message", "Choose a standard mouse button.");
      var eventType = type switch { "down" => "mousePressed", "up" => "mouseReleased", "move" => "mouseMoved", "wheel" => "mouseWheel", _ => throw new PhoneRefusal("bad-message", "Unknown mouse phase.") };
      return new("Input.dispatchMouseEvent", new() { ["type"] = eventType, ["x"] = Math.Clamp(Number("x", required: true), 0, 16384), ["y"] = Math.Clamp(Number("y", required: true), 0, 16384), ["button"] = button, ["clickCount"] = Math.Clamp((int)Number("clicks", type is "down" or "up" ? 1 : 0), 0, 3), ["deltaX"] = Number("dx"), ["deltaY"] = Number("dy") });
    }
    if (kind == "key")
    {
      var eventType = type switch { "down" => "keyDown", "up" => "keyUp", "char" => "char", _ => throw new PhoneRefusal("bad-message", "Unknown key phase.") };
      var key = Text("key"); var text = Text("text"); var code = Text("code");
      var virtualKey = key switch { "Enter" => 13, "Tab" => 9, "Escape" => 27, "Backspace" => 8, "Delete" => 46, "ArrowLeft" => 37, "ArrowUp" => 38, "ArrowRight" => 39, "ArrowDown" => 40, "Home" => 36, "End" => 35, "PageUp" => 33, "PageDown" => 34, _ when key.Length == 1 && char.IsAscii(key[0]) => char.ToUpperInvariant(key[0]), _ => 0 };
      return new("Input.dispatchKeyEvent", new() { ["type"] = eventType, ["key"] = key, ["code"] = code, ["text"] = type == "up" ? "" : text, ["windowsVirtualKeyCode"] = virtualKey, ["modifiers"] = Math.Clamp((int)Number("mods"), 0, 15) });
    }
    var touchType = type switch { "start" => "touchStart", "move" => "touchMove", "end" => "touchEnd", "cancel" => "touchCancel", _ => throw new PhoneRefusal("bad-message", "Unknown touch phase.") };
    if (!item.TryGetProperty("points", out var points) || points.ValueKind != JsonValueKind.Array || points.GetArrayLength() > 10) throw new PhoneRefusal("bad-message", "Send at most ten touch points.");
    var result = new JsonArray(); var index = 0;
    foreach (var point in points.EnumerateArray())
    {
      if (point.ValueKind != JsonValueKind.Object || !point.TryGetProperty("x", out var x) || !point.TryGetProperty("y", out var y) || x.ValueKind != JsonValueKind.Number || y.ValueKind != JsonValueKind.Number || !x.TryGetDouble(out var px) || !y.TryGetDouble(out var py) || !double.IsFinite(px) || !double.IsFinite(py)) throw new PhoneRefusal("bad-message", "Touch positions must be finite numbers.");
      result.Add(new JsonObject { ["x"] = Math.Clamp(px, 0, 16384), ["y"] = Math.Clamp(py, 0, 16384), ["id"] = index++ });
    }
    if (type is "end" or "cancel") result.Clear();
    return new("Input.dispatchTouchEvent", new() { ["type"] = touchType, ["touchPoints"] = result });
  }
}
