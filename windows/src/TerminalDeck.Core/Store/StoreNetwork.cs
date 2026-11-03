namespace TerminalDeck.Core.Store;

public static class StoreNetwork
{
  public static HttpRequestMessage Get(string address, string accept = "application/octet-stream")
  {
    var request = new HttpRequestMessage(HttpMethod.Get, address);
    request.Headers.UserAgent.ParseAdd("TerminalDeck/" + (typeof(StoreNetwork).Assembly.GetName().Version?.ToString() ?? "1"));
    request.Headers.Accept.ParseAdd(accept); return request;
  }
}
