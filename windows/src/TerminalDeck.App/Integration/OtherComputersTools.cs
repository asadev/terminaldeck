using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Integration;

public static class OtherComputersTools
{
  public static void Register(McpDoor door, OtherComputersService computers, AppRuntime runtime)
  {
    computers.BindBrowserDoor(door);
    OtherComputersServiceTools.Register(door, computers);
    door.Register("activity.read", (context, _, ct) =>
    {
      context.Require("settings", "devices");
      return ValueTask.FromResult(JsonSerializer.SerializeToElement(TerminalDeck.App.Views.Usage.DesktopResourceMeter.Read(runtime)));
    });
    door.Register("computers.look", (context, _, ct) =>
    {
      context.Require("settings", "devices");
      return ValueTask.FromResult(JsonSerializer.SerializeToElement(computers.List().Where(c => context.Has("computers", c.Id))));
    });
    door.Register("computers.manage", async (context, args, ct) =>
    {
      context.Require("settings", "devices"); await context.EnsureCurrentAsync(ct);
      var action = args.GetProperty("action").GetString();
      if (action == "pair")
      {
        // Pairing creates a new resource and cannot be authorized by a grant to
        // a different, already paired computer.
        context.Require("computers", "*");
        return JsonSerializer.SerializeToElement(new { computerId = await computers.PairAsync(args.GetProperty("code").GetString()!, ct) });
      }
      var id = args.GetProperty("computerId").GetString()!; context.Require("computers", id);
      switch (action)
      {
        case "allow-browser": await computers.SetBrowserConsentAsync(id, args.GetProperty("allowed").GetBoolean()); break;
        case "connect": await computers.ConnectAsync(id, ct); break;
        case "disconnect": await computers.DisconnectAsync(id); break;
        case "forget": await computers.ForgetAsync(id); break;
        default: throw new McpRefusal("Choose a listed computer action.");
      }
      return JsonSerializer.SerializeToElement(new { ok = true });
    });
    door.Register("computers.screen", async (context, args, ct) =>
    {
      context.Require("settings", "devices");
      var id = args.GetProperty("computerId").GetString()!; context.Require("computers", id);
      var display = args.GetProperty("displayId").GetString()!;
      var row = computers.List().FirstOrDefault(c => c.Id == id) ?? throw new McpRefusal("Choose a paired computer.");
      if (!row.Capabilities.Contains("sims") || !row.Displays.Any(d => OtherComputersService.Text(d, "id", "") == display)) throw new McpRefusal("Choose a display that computer currently shares.");
      await context.EnsureCurrentAsync(ct);
      if (args.GetProperty("action").GetString() == "picture")
      {
        // One still of the screen as it is now (`sims.shot`, the same still Annotate uses): the screen itself streams as
        // H.264 only (contract §11.7), so a picture is asked for, not taken from the stream.
        var shot = await computers.RequestAsync(id, "sims", "sims.shot", new System.Text.Json.Nodes.JsonObject { ["id"] = display }, ["sims.shot"], ct);
        var jpeg = Convert.FromBase64String(OtherComputersService.Text(shot, "data", ""));
        if (jpeg.Length == 0) throw new McpRefusal("That computer sent no picture of this display.");
        var folder = Path.Combine(runtime.Root.DirectoryPath, "computer-pictures");
        TerminalDeck.Platform.Windows.WindowsPrivateDirectory.Ensure(folder);
        var path = Path.Combine(folder, Guid.NewGuid().ToString("N") + ".jpg");
        await File.WriteAllBytesAsync(path, jpeg, ct);
        var width = shot.TryGetProperty("w", out var w) && w.TryGetInt32(out var wn) ? wn : 0;
        var height = shot.TryGetProperty("h", out var h) && h.TryGetInt32(out var hn) ? hn : 0;
        return JsonSerializer.SerializeToElement(new { path, Width = width, Height = height });
      }
      object message = args.GetProperty("action").GetString() switch
      {
        "watch" => TerminalDeck.Core.Computers.ComputerVideoPipeline.Watch(display, "computers-tool-watch", cursor: false),
        "stop" => new { t = "sims.unwatch", id = display },
        "tap" => new { t = "sims.input", id = display, @do = "tap", x = args.GetProperty("x").GetDouble(), y = args.GetProperty("y").GetDouble() },
        "type" => new { t = "sims.input", id = display, @do = "type", text = args.GetProperty("text").GetString()! },
        "mouse" => new { t = "sims.input", id = display, @do = "mouse", phase = args.GetProperty("phase").GetString(), button = args.GetProperty("button").GetString(), x = args.GetProperty("x").GetDouble(), y = args.GetProperty("y").GetDouble(), clicks = 1 },
        "key" => new { t = "sims.input", id = display, @do = "key", key = args.GetProperty("key").GetString(), mods = args.TryGetProperty("mods", out var mods) ? mods.EnumerateArray().Select(m => m.GetString()).ToArray() : [] },
        "scroll" => new { t = "sims.input", id = display, @do = "scroll", x = args.GetProperty("x").GetDouble(), y = args.GetProperty("y").GetDouble(), dx = args.GetProperty("dx").GetDouble(), dy = args.GetProperty("dy").GetDouble() },
        _ => throw new McpRefusal("Choose a listed screen action.")
      };
      await computers.SendAsync(id, message, ct);
      return JsonSerializer.SerializeToElement(new { sent = true, note = "The remote computer decides whether this is allowed. No local window was raised." });
    });
  }
}
