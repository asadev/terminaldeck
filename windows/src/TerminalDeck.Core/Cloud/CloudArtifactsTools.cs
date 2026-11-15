using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Cloud;

/// Lane F, the Mac's BackendCloudArtifactsTools.swift: the artifacts that travel. An AI lists them (made here or on
/// another device) and opens one by reading its file. Deleting one is `cloud_delete`; the Bin is the person's: this tool
/// never lists it.
public static class CloudArtifactsTools
{
  public const string ListId = "cloud.artifacts";
  public const string SignedOut = "Artifacts do not travel on this PC yet (signed out, or still starting).";
  public static IReadOnlyList<McpToolSpec> Specs => [
    new(ListId, "cloud_artifacts", McpTier.Read, JsonSerializer.SerializeToElement(new { type = "object", properties = new { }, additionalProperties = false }))
  ];
  public const string ListDescription = "The person's artifacts that travel between their devices (pages, reports, pictures), made on this PC or another: each with id, name, project, who made it, which device, when, size and path (read the file at path to open it), and anything waiting. To delete one from every device, use cloud_delete with kind Artifacts and the artifact's name (or its id as place): it goes to the Bin for 30 days and only the person can put it back. Nothing in the Bin is listed: the Bin is the person's.";

  public static void Register(McpDoor door, Func<CloudArtifacts?> artifacts, Func<string, string?> deviceName) =>
    door.Register(ListId, (_, _, _) => ValueTask.FromResult(List(artifacts() ?? throw new McpRefusal(SignedOut), deviceName)));

  public static JsonElement List(CloudArtifacts artifacts, Func<string, string?> deviceName)
  {
    static string Day(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(ms).ToString("yyyy-MM-ddTHH:mm:ssZ", System.Globalization.CultureInfo.InvariantCulture);
    var items = artifacts.Items().Where(i => !CloudArtifactsFormat.IsAbout(i.Path) && !CloudArtifactsFormat.IsAbout(i.RelPath)).Select(i => new
    {
      id = i.Path, name = i.Name, project = i.Project, madeBy = i.MadeBy,
      device = i.Device is { } d ? deviceName(d.ToLowerInvariant()) ?? CloudDeleteWords.AnotherDevice : null,
      madeAt = Day(i.CreatedAt), changedAt = Day(i.ChangedAt), type = i.Type, bytes = i.Bytes, path = i.File
    });
    return JsonSerializer.SerializeToElement(new { artifacts = items, waiting = artifacts.PageLines() });
  }
}
