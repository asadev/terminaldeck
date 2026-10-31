using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Dispatching;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

public sealed class AppToolServer : IAsyncDisposable
{
  private readonly TcpListener listener = new(IPAddress.Loopback, 0);
  private readonly CancellationTokenSource stop = new();
  private readonly McpHttpEndpoint endpoint;
  private readonly Task running;
  private readonly McpDoor door;
  private readonly string connectionFile;
  public Uri Address { get; }
  public AppToolServer(McpDoor door, AppDataRoot root)
  {
    this.door = door;
    listener.Start(8);
    Address = new($"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/mcp");
    endpoint = new(door, Address, "0.1.0-windows");
    var directory = Path.Combine(root.DirectoryPath, "mcp"); WindowsPrivateDirectory.Ensure(directory);
    connectionFile = Path.Combine(directory, "connection.json");
    File.WriteAllText(connectionFile, JsonSerializer.Serialize(new { url = Address.AbsoluteUri, requiresCallerConnection = true }));
    running = RunAsync();
  }
  private async Task RunAsync()
  {
    while (!stop.IsCancellationRequested)
    {
      try { var client = await listener.AcceptTcpClientAsync(stop.Token); _ = ServeAsync(client); }
      catch (Exception ex) when (stop.IsCancellationRequested && ex is OperationCanceledException or SocketException) { break; }
    }
  }
  private async Task ServeAsync(TcpClient client)
  {
    using (client)
    using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop.Token))
    {
      deadline.CancelAfter(TimeSpan.FromSeconds(150));
      try
      {
        var stream = client.GetStream();
        var headerBytes = new List<byte>();
        var one = new byte[1];
        while (headerBytes.Count < 32768)
        {
          if (await stream.ReadAsync(one, deadline.Token) != 1) throw new IOException();
          headerBytes.Add(one[0]);
          var n = headerBytes.Count;
          if (n >= 4 && headerBytes[n - 4] == 13 && headerBytes[n - 3] == 10 && headerBytes[n - 2] == 13 && headerBytes[n - 1] == 10) break;
        }
        var lines = Encoding.ASCII.GetString(headerBytes.ToArray()).Split("\r\n");
        var first = lines[0].Split(' ');
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1).Where(l => l.Length > 0))
        {
          var colon = line.IndexOf(':'); if (colon <= 0 || headers.Count >= 40 || !headers.TryAdd(line[..colon], line[(colon + 1)..].Trim())) throw new IOException();
        }
        if (first.Length != 3 || headers.ContainsKey("Transfer-Encoding") || !int.TryParse(headers.GetValueOrDefault("Content-Length"), out var length) || length is < 0 or > 65536) throw new IOException();
        var body = new byte[length]; await stream.ReadExactlyAsync(body, deadline.Token);
        var reply = await endpoint.HandleAsync(new() { Method = first[0], Path = first[1], Host = headers.GetValueOrDefault("Host", ""), Origin = headers.GetValueOrDefault("Origin"), Authorization = headers.GetValueOrDefault("Authorization", ""), Body = body }, deadline.Token);
        var header = Encoding.ASCII.GetBytes($"HTTP/1.1 {reply.Status} Reply\r\nContent-Type: {reply.ContentType}\r\nContent-Length: {reply.Body.Length}\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(header, deadline.Token); await stream.WriteAsync(reply.Body, deadline.Token);
      }
      catch (Exception ex) when (ex is IOException or OperationCanceledException or SocketException) { }
    }
  }
  public async ValueTask DisposeAsync() { stop.Cancel(); listener.Stop(); await running; if (File.Exists(connectionFile)) File.Delete(connectionFile); stop.Dispose(); }
}
