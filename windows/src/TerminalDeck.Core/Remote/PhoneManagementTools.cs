using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Remote;

public static class PhoneManagementTools
{
  public static IReadOnlyList<McpToolSpec> Specs => JsonSerializer.Deserialize<Bundle>(Source, new JsonSerializerOptions { PropertyNameCaseInsensitive = true,
    Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter(JsonNamingPolicy.CamelCase) } })!.Tools;
  private sealed record Bundle(McpToolSpec[] Tools);
  private const string Source = """
{"tools":[
{"id":"remote.phone.read","wire":"remote_phone_read","tier":"read","inputSchema":{"type":"object","additionalProperties":false,"properties":{"type":{"type":"string","enum":["controls.read","settings.read","logins.read","github.read","host.status","dev.status","routines","routine.text"]},"id":{"type":"string","maxLength":128},"folder":{"type":"string","maxLength":4096}},"required":["type"]}},
{"id":"remote.phone.manage","wire":"remote_phone_manage","tier":"alter","inputSchema":{"type":"object","additionalProperties":false,"properties":{"type":{"type":"string","enum":["controls.apply","settings.apply","logins.signin","logins.signout","github.connect","github.cancel","github.disconnect","host.restart","host.stop","dev.start"]},"id":{"type":"string","maxLength":128},"accountId":{"type":"string","maxLength":200},"folder":{"type":"string","maxLength":4096},"url":{"type":"string","maxLength":4096},"key":{"type":"string","maxLength":64},"control":{"type":"string","enum":["model","effort","permission","fast"]},"value":{"type":"string","maxLength":160}},"required":["type"]}},
{"id":"hoot.routines.manage","wire":"hoot_routines_manage","tier":"alter","inputSchema":{"type":"object","additionalProperties":false,"properties":{"action":{"type":"string","enum":["save","remove","run","stop","keep-unconfirmed"]},"id":{"type":"string","maxLength":128},"name":{"type":"string","maxLength":120},"purpose":{"type":"string","maxLength":500},"folder":{"type":"string","maxLength":4096},"text":{"type":"string","maxLength":24000},"everyMinutes":{"type":"integer","minimum":1,"maximum":525600},"enabled":{"type":"boolean"}},"required":["action","id"]}}
]}
""";
}
