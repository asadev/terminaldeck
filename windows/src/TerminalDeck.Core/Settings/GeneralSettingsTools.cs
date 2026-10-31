using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Settings;

public static class GeneralSettingsTools
{
  public static void Register(GeneralSettings settings, McpDoor door, Func<bool> readConfirmation, Action<bool> saveConfirmation,
    Func<string> version, Func<Task<string>> checkUpdates) => door.Compose("ui.workspace", previous => async (context, args, ct) =>
  {
    context.Require("settings", "workspace");
    var fields = args.EnumerateObject().Where(p => p.Name is not ("generalSettings" or "checkForUpdates")).ToDictionary(p => p.Name, p => p.Value.Clone());
    if (args.TryGetProperty("generalSettings", out var patch))
    {
      await context.EnsureCurrentAsync(ct);
      var confirmation = patch.TryGetProperty("confirmCloseWorking", out var confirm) ? confirm.GetBoolean() : (bool?)null;
      var preferences = JsonSerializer.SerializeToElement(patch.EnumerateObject().Where(p => p.Name != "confirmCloseWorking").ToDictionary(p => p.Name, p => p.Value.Clone()));
      settings.Patch(preferences);
      if (confirmation.HasValue) saveConfirmation(confirmation.Value);
    }
    string? updateStatus = null;
    if (args.TryGetProperty("checkForUpdates", out var check) && check.GetBoolean())
    { await context.EnsureCurrentAsync(ct); updateStatus = await checkUpdates(); }
    var old = previous is null ? JsonSerializer.SerializeToElement(new { }) : await previous(context, JsonSerializer.SerializeToElement(fields), ct);
    var result = old.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.Clone());
    var current = settings.Read();
    result["generalSettings"] = JsonSerializer.SerializeToElement(new { restoreSessions = true, restoreSessionsSwitchable = false, autoNameSessions = current.AutoNameSessions, copyOnSelect = current.CopyOnSelect, keepAwake = current.KeepAwake, defaultPermission = (current.DefaultPermission ?? TerminalDeck.Core.Chats.ChatPermissionModes.DefaultFor("claude")).ToString(), confirmCloseWorking = readConfirmation(), version = version(), updateStatus });
    return JsonSerializer.SerializeToElement(result);
  });
}
