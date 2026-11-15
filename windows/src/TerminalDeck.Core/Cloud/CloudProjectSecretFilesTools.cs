using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Cloud;

/// Project secret files' tool (every feature ships with its tool; the Mac's BackendProjectSecretFilesTools). READ ONLY:
/// per project, the secret files' names, sizes, dates, the device they came from and their state. There is deliberately
/// no tool that reads a secret's content, and none that sends or places one: they travel by themselves.
public static class CloudProjectSecretFilesTools
{
  public const string StatusId = "cloud.project_secrets";
  public const string NotOpen = "Project secret files travel inside saved passwords, which are not open on this PC right now (signed out, or still starting).";
  public static IReadOnlyList<McpToolSpec> Specs => [
    new(StatusId, "cloud_project_secrets", McpTier.Read, JsonSerializer.SerializeToElement(new { type = "object", properties = new { }, additionalProperties = false }))
  ];

  public static void Register(CloudProjectSecretFilesHolder holder, McpDoor door) => door.Register(StatusId, (_, _, _) =>
    ValueTask.FromResult(holder.Store?.Status() is { } status ? Answer(status) : throw new McpRefusal(NotOpen)));

  /// Names, sizes, dates and words only.
  public static JsonElement Answer(CloudProjectSecretFilesStatus status) => JsonSerializer.SerializeToElement(new
  {
    projects = status.Projects.Select(p => new
    {
      project = p.Name,
      files = p.Files.Select(f => new { name = f.Path, bytes = f.Bytes, date = f.At is { } at ? CloudProjectSecretFilesWords.Date(at) : null, from = f.From, state = f.State, travels = f.Travels })
    }),
    keepOnThisPcOnly = status.KeepOnThisPc,
    waitingForYourOtherDevices = status.WaitingForDevices,
    why = status.WaitingWhy,
    refusedFromOtherDevices = status.RefusedArrivals,
    lastLooked = status.LookedAt is { } looked ? CloudProjectSecretFilesWords.Date(looked) : null
  });
}
