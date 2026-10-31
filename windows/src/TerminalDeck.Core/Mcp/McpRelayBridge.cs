using System.Text;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Mcp;

// Relay transport does not grant local-owner tokens internet access. The caller
// must have a separately issued relay grant and still pass the ordinary door.
public sealed class McpRelayBridge(McpDoor door) : IRelayMcpApplication
{
  private readonly Uri local = new("http://127.0.0.1:1/mcp");
  private readonly McpHttpEndpoint endpoint = new(door, new("http://127.0.0.1:1/mcp"), "0.1.0-windows");
  public async ValueTask<IReadOnlyList<byte[]>> ReceiveAsync(ReadOnlyMemory<byte> payload, CancellationToken ct)
  {
    McpHttpReply reply;
    try
    {
      var (head, body) = McpRelayCodec.DecodeRequest(payload.Span);
      var authorization = head.PathKey is { Length: > 0 } key ? "Bearer " + key : head.Authorization ?? "";
      var token = authorization.StartsWith("Bearer ", StringComparison.Ordinal) ? authorization[7..] : "";
      if (!door.AllowsRelay(token)) reply = new(401, []);
      else reply = await endpoint.HandleAsync(new() { Method = "POST", Path = "/mcp", Host = local.Authority, Authorization = authorization, Body = body }, ct);
    }
    catch (McpRefusal) { reply = new(400, Encoding.UTF8.GetBytes("{\"error\":\"The relay request is unusable.\"}")); }
    return McpRelayCodec.EncodeReply(reply);
  }
}
