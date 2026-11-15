using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Cloud;

/// Lane F, the Mac's BackendCloudFolderTools.swift: the Cloud folder's tools. AIs read and write the folder itself at
/// local speed (its path is in their context); these two only say where it is and copy something into it. Deleting is
/// `cloud_delete` (the delete rule's lane): everywhere, into the Bin for 30 days, no question. One family, supplied whole.
public static class CloudFolderTools
{
  public const string FolderId = "cloud.folder", AddId = "cloud.folder_add";
  public const string SignedOut = "Your Cloud folder is not set up on this PC yet (signed out, or still starting).";
  private static JsonElement Schema(object value) => JsonSerializer.SerializeToElement(value);
  public static IReadOnlyList<McpToolSpec> Specs => [
    new(FolderId, "cloud_folder", McpTier.Read, Schema(new { type = "object", properties = new { }, additionalProperties = false })),
    new(AddId, "cloud_folder_add", McpTier.Alter, Schema(new { type = "object", properties = new { path = new { type = "string" } }, required = new[] { "path" }, additionalProperties = false }))
  ];
  public const string FolderDescription = "The person's Cloud folder on this PC (a normal folder; whatever is in it is on all their devices): its path, how many files travel and their size, and anything waiting. Read and write files in it directly; files up to 25 MB travel; hidden files, links, package folders and key or sign-in files stay on this PC. To delete a file from it on every device, use cloud_delete with kind Cloud folder and the file's path inside the folder as name: it goes to the Bin for 30 days and only the person can put it back.";
  public const string AddDescription = "Copies a file or folder (path) into the top of the person's Cloud folder, under a free name, so it reaches all their devices. Returns the new path. The person is asked first.";

  /// `owner`: the signed-in account's Cloud folder owner, null while signed out or starting.
  public static void Register(McpDoor door, Func<CloudFolderOwner?> owner)
  {
    door.Register(FolderId, (_, _, _) => ValueTask.FromResult(Status(owner() ?? throw new McpRefusal(SignedOut))));
    door.Register(AddId, (_, args, _) =>
    {
      var current = owner() ?? throw new McpRefusal(SignedOut);
      return ValueTask.FromResult(Add(current, args));
    });
  }
  public static JsonElement Status(CloudFolderOwner owner)
  {
    var counts = owner.Counts();
    return JsonSerializer.SerializeToElement(new { path = owner.Folder, files = counts.Files, bytes = counts.Bytes, waiting = owner.PageLines() });
  }
  public static JsonElement Add(CloudFolderOwner owner, JsonElement args)
  {
    var raw = args.ValueKind == JsonValueKind.Object && args.TryGetProperty("path", out var p) && p.ValueKind == JsonValueKind.String ? p.GetString()!.Trim() : "";
    if (raw.Length == 0 || raw.Contains('\0')) throw new McpRefusal("Give path: the file or folder to copy into the Cloud folder.");
    var path = raw.StartsWith('~') ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + raw[1..] : raw;
    if (!Path.IsPathFullyQualified(path)) throw new McpRefusal("Give the full path (for example C:\\Users\\you\\file.txt or ~\\file.txt).");
    try { return JsonSerializer.SerializeToElement(new { path = owner.Add(path) }); }
    catch (CloudFailure) { throw new McpRefusal("That cannot be copied into your Cloud folder (it is the folder itself, inside it, or not there)."); }
  }
}
