using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;

// Talks to an already running keeper of one scratch data root. It never starts
// a keeper, so the proof counts only the keepers the app itself started.
// create ROOT FOLDER MARKER | list ROOT | stop ROOT
if (args.Length < 2 || !Path.IsPathFullyQualified(args[1]) || !args[1].StartsWith(@"C:\TD\scratch\", StringComparison.OrdinalIgnoreCase)) return 64;
var root = AppDataRoot.Explicit(args[1]);
using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(60));
var client = new KeeperClient(new NamedPipeConnector(root), KeeperCredentials.GetOrCreate(root));
await client.HelloAsync(deadline.Token);
switch (args[0])
{
  case "create" when args.Length == 4:
    var row = (await client.CreateAsync(new(Guid.NewGuid().ToString(), "shell", args[2], "Handover " + args[3]), deadline.Token)).Session!;
    await Task.Delay(1500, deadline.Token);
    await client.WriteAsync(row.Definition.Id, Encoding.UTF8.GetBytes("echo " + args[3] + "\r"), deadline.Token);
    await Task.Delay(1500, deadline.Token);
    Console.WriteLine(JsonSerializer.Serialize(new { id = row.Definition.Id, cwd = row.Definition.Cwd, key = row.CreationKey }));
    return 0;
  case "list":
    var rows = (await client.ListAsync(deadline.Token)).Sessions!;
    Console.WriteLine(JsonSerializer.Serialize(rows.Select(r => new
    {
      id = r.Definition.Id, title = r.Definition.Title, cwd = r.Definition.Cwd, state = r.State.ToString(), key = r.CreationKey, lease = r.LeaseIdentity,
      note = r.Replay.Contains("[Terminal Deck was updated.", StringComparison.Ordinal), tail = r.Replay.Length > 400 ? r.Replay[^400..] : r.Replay
    })));
    return 0;
  case "stop":
    foreach (var r in (await client.ListAsync(deadline.Token)).Sessions!.Where(r => r.State != SessionState.Exited)) await client.StopAsync(r.Definition.Id, deadline.Token);
    return 0;
}
return 64;
