using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Receiver;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private void RegisterReceiverSourceTools()
  {
    Door.Register("receiver.source.read", (context, args, ct) =>
    {
      if (!args.TryGetProperty("id", out var id)) return ValueTask.FromResult(JsonSerializer.SerializeToElement(new { presets = ReceiverSources.Presets(), sources = Receiver.Sources().Where(s => context.Has("projects", s.ProjectId)) }));
      var source = ReceiverSources.Source(id.GetString()!); context.Require("projects", source.ProjectId);
      return ValueTask.FromResult(JsonSerializer.SerializeToElement(new { source, configuration = ReceiverSources.Read(source.Id), address = ReceiverSources.Address(source.Id), active = ReceiverRelay.Active.Contains(source.Id), relayConnected = ReceiverRelay.Connected, refused = ReceiverRelay.Refused.GetValueOrDefault(source.Id), problem = ReceiverRelay.Problem }));
    });
    Door.Register("receiver.source.create", async (context, args, ct) =>
    {
      var project = args.GetProperty("projectId").GetString()!; context.Require("projects", project); _ = Projects.Get(project); await context.EnsureCurrentAsync(ct);
      return JsonSerializer.SerializeToElement(await ReceiverSources.CreateAsync(args.GetProperty("name").GetString()!, project, args.GetProperty("preset").GetString()!, ct));
    });
    Door.Register("receiver.source.save", async (context, args, ct) =>
    {
      var configuration = JsonSerializer.Deserialize<ReceiverSourceConfiguration>(args.GetProperty("configuration"), ReceiverJson.Options) ?? throw new ArgumentException("Give complete source settings.");
      context.Require("projects", ReceiverSources.Source(configuration.SourceId).ProjectId); await context.EnsureCurrentAsync(ct); ReceiverSources.Save(configuration); return JsonSerializer.SerializeToElement(ReceiverSources.Read(configuration.SourceId));
    });
    Door.Register("receiver.source.credential", async (context, args, ct) =>
    {
      var id = args.GetProperty("id").GetString()!; context.Require("projects", ReceiverSources.Source(id).ProjectId); await context.EnsureCurrentAsync(ct);
      if (args.TryGetProperty("copySaved", out var copy) && copy.GetBoolean())
      { var value = await ReceiverSources.ReadCredentialForClipboardAsync(id, ct); var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(value); Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); }
      else if (args.TryGetProperty("generateAndCopy", out var generate) && generate.GetBoolean())
      { var value = await ReceiverSources.GenerateCredentialAsync(id, ct); var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(value); Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); }
      else { if (!args.TryGetProperty("value", out var value)) throw new ArgumentException("Provide a value, or choose copySaved / generateAndCopy explicitly."); await ReceiverSources.SetCredentialAsync(id, value.GetString()!, args.TryGetProperty("reply", out var reply) && reply.GetBoolean(), ct); }
      return JsonSerializer.SerializeToElement(new { saved = true, credentialValuesReturned = false });
    });
    Door.Register("receiver.source.preview", (context, args, ct) =>
    {
      var id = args.GetProperty("id").GetString()!; context.Require("projects", ReceiverSources.Source(id).ProjectId);
      return ValueTask.FromResult(JsonSerializer.SerializeToElement(ReceiverSources.Preview(new(id, args.TryGetProperty("headers", out var headers) ? JsonSerializer.Deserialize<Dictionary<string, string>>(headers)! : new(), Encoding.UTF8.GetBytes(args.GetProperty("payload").GetString()!)))));
    });
    Door.Register("receiver.source.learn", (context, args, ct) => { var id = args.GetProperty("id").GetString()!; context.Require("projects", ReceiverSources.Source(id).ProjectId); return ValueTask.FromResult(JsonSerializer.SerializeToElement(ReceiverSources.Learn(id))); });
    Door.Register("receiver.source.preset", async (context, args, ct) => { var id = args.GetProperty("id").GetString()!; context.Require("projects", ReceiverSources.Source(id).ProjectId); await context.EnsureCurrentAsync(ct); ReceiverSources.SavePreset(id, args.GetProperty("name").GetString()!); return JsonSerializer.SerializeToElement(new { saved = true, credentialsCopied = false }); });
  }
}
