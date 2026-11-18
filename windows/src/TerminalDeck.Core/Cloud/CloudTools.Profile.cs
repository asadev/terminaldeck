using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Cloud;

public static partial class CloudTools
{
  private static JsonElement Schema(object value) => JsonSerializer.SerializeToElement(value);
  private static readonly string[] ProfileActions = ["read", "name", "username", "picture", "remove-picture", "disconnect", "connect", "sign-out"];
  private static readonly string[] DeviceActions = ["list", "rename", "sign-out", "sign-out-others"];
  public static IReadOnlyList<McpToolSpec> ProfileSpecs => [
    new("cloud.profile", "cloud_profile", McpTier.Alter, Schema(new { type = "object", properties = new { action = new { type = "string", @enum = ProfileActions }, value = new { type = "string", maxLength = 670000 } }, required = new[] { "action" }, additionalProperties = false })),
    new("cloud.devices", "cloud_devices", McpTier.Alter, Schema(new { type = "object", properties = new { action = new { type = "string", @enum = DeviceActions }, deviceId = new { type = "string" }, name = new { type = "string", maxLength = 128 } }, required = new[] { "action" }, additionalProperties = false }))
  ];

  private static void RegisterProfile(CloudAccountClient account, McpDoor door)
  {
    door.Register("cloud.profile", async (context, args, ct) =>
    {
      context.Require("settings", "workspace");
      var action = args.GetProperty("action").GetString();
      if (action == "read") return JsonSerializer.SerializeToElement(await account.ProfileAsync(ct));
      await context.EnsureCurrentAsync(ct);
      var value = args.TryGetProperty("value", out var v) ? v.GetString() ?? "" : "";
      CloudProfile? profile;
      try
      {
        switch (action)
        {
          case "name": profile = await account.SaveProfileNameAsync(value, ct); break;
          case "username": profile = await account.SaveProfileUsernameAsync(value, ct); break;
          case "disconnect": profile = await account.DisconnectSignInWayAsync(value, ct); break;
          case "remove-picture": profile = await account.RemoveProfilePictureAsync(ct); break;
          case "picture":
            byte[] picture;
            try { picture = Convert.FromBase64String(value); } catch (FormatException) { throw new McpRefusal("Give the picture as a base64 JPEG, at most 500 KB."); }
            profile = await account.SaveProfilePictureAsync(picture, ct); break;
          case "connect": await account.ConnectSignInWayAsync(ct); return Schema(new { opened = true });
          case "sign-out": await account.SignOutAsync(ct); return Schema(new { signedOut = true });
          default: throw new McpRefusal("Choose a profile action.");
        }
      }
      catch (CloudProfileRefusal refusal) { throw new McpRefusal(refusal.Words); }
      return JsonSerializer.SerializeToElement(profile);
    });
    door.Register("cloud.devices", async (context, args, ct) =>
    {
      context.Require("settings", "workspace");
      var action = args.GetProperty("action").GetString();
      if (action == "list") return Schema(account.Snapshot.DeviceRows.Select(d => new { d.DeviceId, d.Name, d.ThisDevice, d.Platform, d.ReportedModel, d.Added, d.LastSeen }));
      var ids = action == "sign-out-others" ? account.Snapshot.DeviceRows.Where(d => !d.ThisDevice).Select(d => d.DeviceId).ToArray()
        : new[] { args.TryGetProperty("deviceId", out var target) ? target.GetString() ?? "" : "" };
      try
      {
        foreach (var id in ids)
        {
          context.Require("devices", id);
          await context.EnsureCurrentAsync(ct);
          if (action == "rename") await account.RenameDeviceAsync(id, args.GetProperty("name").GetString() ?? "", ct);
          else if (action is "sign-out" or "sign-out-others") await account.SignOutDeviceAsync(id, ct);
          else throw new McpRefusal("Choose a device action.");
        }
      }
      catch (CloudProfileRefusal refusal) { throw new McpRefusal(refusal.Words); }
      return Schema(new { changed = ids.Length });
    });
  }
}
