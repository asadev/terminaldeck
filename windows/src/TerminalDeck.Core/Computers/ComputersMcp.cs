using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Computers;

public static class ComputersMcp
{
  private static JsonElement Schema(string json) => JsonSerializer.Deserialize<JsonElement>(json);
  public static IReadOnlyList<McpToolSpec> Specs { get; } =
  [
    new("computers.services", "computers_services", McpTier.Act, Schema("""{"type":"object","properties":{"computerId":{"type":"string"},"action":{"type":"string","enum":["clipboard-read","clipboard-write","look","create","attach","detach","input","keys","resize","close","rename","controls-read","controls-set","usage","account-read","account-switch","logins","sign-in","sign-out","send","host-read","host-restart","host-stop","github-read","github-connect","github-cancel","github-disconnect","hoot-read","hoot-start","hoot-say","hoot-detach","ports","open-here","close-here","open-there","upload","cancel-upload"]},"fields":{"type":"object"}},"required":["computerId","action"],"additionalProperties":false}""")),
    new("activity.read", "activity_read", McpTier.Read, Schema("""{"type":"object","properties":{},"additionalProperties":false}""")),
    new("computers.look", "computers_look", McpTier.Read, Schema("""{"type":"object","properties":{},"additionalProperties":false}""")),
    new("computers.manage", "computers_manage", McpTier.Alter, Schema("""{"type":"object","properties":{"action":{"type":"string","enum":["pair","connect","disconnect","forget","allow-browser"]},"code":{"type":"string"},"computerId":{"type":"string"},"allowed":{"type":"boolean"}},"required":["action"],"additionalProperties":false}""")),
    new("computers.screen", "computers_screen", McpTier.Act, Schema("""{"type":"object","properties":{"computerId":{"type":"string"},"displayId":{"type":"string"},"action":{"type":"string","enum":["watch","stop","tap","type","mouse","key","scroll","picture"]},"x":{"type":"number","minimum":0,"maximum":1},"y":{"type":"number","minimum":0,"maximum":1},"text":{"type":"string","minLength":1,"maxLength":2000},"phase":{"type":"string","enum":["move","drag","down","up"]},"button":{"type":"string","enum":["left","right","middle"]},"key":{"type":"string","minLength":1,"maxLength":32},"mods":{"type":"array","items":{"type":"string","enum":["command","option","control","shift"]},"maxItems":4},"dx":{"type":"number","minimum":-1,"maximum":1},"dy":{"type":"number","minimum":-1,"maximum":1}},"required":["computerId","displayId","action"],"additionalProperties":false}"""))
  ];
}
