using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private readonly Dictionary<string, string> phoneDevSessions = [];
  private static readonly JsonSerializerOptions PhoneJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
  private ValueTask<JsonObject> PhoneManagementMessageAsync(ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct) =>
    PhoneManagementWithAuthorityAsync(device, type, message, rid, ct, token => RequirePhoneCurrentAsync(device, token));
  private async ValueTask<JsonObject> PhoneManagementWithAuthorityAsync(ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct,
    Func<CancellationToken, ValueTask> recheck)
  {
    var reply = new JsonObject { ["rid"] = rid ?? PhoneText(message, "rid", false) };
    if (type is "controls.read" or "controls.apply")
    {
      var id = PhoneText(message, "id")!; var host = new PhoneSessionsHost(this);
      var chat = Chats.List().FirstOrDefault(c => c.Definition.Id == id && host.Visible(device, c));
      var terminal = Sessions.FirstOrDefault(s => s.Definition.Id == id && host.Visible(device, s));
      if (chat is null && terminal is null) throw new PhoneRefusal("unknown-session", "That session is no longer shared.");
      var control = PhoneText(message, "control", false); var value = PhoneText(message, "value", false);
      if (type == "controls.apply")
      {
        if (device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Changing session controls needs Full control.");
        if (chat is not null)
        {
          if (control == "permission")
          { if (PhonePermissionMode(value) is not { } mode) throw new PhoneRefusal("bad-message", "Choose an offered permission mode."); await Chats.SetPermissionAsync(id, mode, ct); }
          else if (control is "model" or "effort") await Chats.SetOptionsAsync(id, control == "model" ? chat.Definition.Options with { Model = value! } : chat.Definition.Options with { Effort = value! }, ct);
          else throw new PhoneRefusal("unavailable", "This coding AI has no fast-mode control.");
          chat = Chats.Get(id);
        }
        else
        {
          // Terminal control writes must go through the real CLI, while idle.
          // A model reading from its launch definition is not live CLI state.
          if (terminal!.State != SessionState.Running || terminal.Definition.Provider == "shell") throw new PhoneRefusal("unavailable", "There is no running coding AI in this terminal.");
          if (value is null || value.Length > 64 || !value.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-' or '(' or ')' or ' ')) throw new PhoneRefusal("bad-message", "Choose a valid control value.");
          var command = control switch { "model" => "/model " + value, "effort" when terminal.Definition.Provider == "claude" => "/effort " + value,
            "fast" when terminal.Definition.Provider == "claude" => "/fast " + value, _ => throw new PhoneRefusal("unavailable", "Change this control in the session's own menu.") };
          if (!System.Text.RegularExpressions.Regex.IsMatch(terminal.Replay, @"(?:❯|›)\s*$")) throw new PhoneRefusal("unavailable", "Wait for this coding AI to finish before changing its controls.");
          await Keeper.WriteAsync(id, Encoding.UTF8.GetBytes(command + "\r"), ct);
        }
      }
      JsonObject Reading(string? v, string? reason = null) => new() { ["value"] = v, ["label"] = v, ["unavailableReason"] = reason };
      var read = new JsonObject { ["model"] = Reading(chat?.Definition.Options.Model, chat is null ? "Read from the coding AI's own menu." : null),
        ["effort"] = Reading(chat?.Definition.Options.Effort), ["permission"] = chat is null ? Reading(null) : new JsonObject { ["value"] = PhonePermissionId(chat.Definition.PermissionMode), ["label"] = PhonePermissionLabel(chat.Definition.PermissionMode), ["unavailableReason"] = null }, ["fast"] = Reading(null, "This coding AI reports fast mode in its own menu."),
        ["live"] = chat is not null ? !chat.Ended : terminal!.State == SessionState.Running, ["agent"] = new JsonObject { ["running"] = chat is not null ? !chat.Ended : terminal!.Definition.Provider != "shell" && terminal.State == SessionState.Running },
        ["gate"] = new JsonObject { ["canType"] = device.Access == PhoneAccess.Full && (chat is null || !chat.Busy), ["reason"] = chat?.Busy == true ? "Wait for the current turn." : null } };
      reply["t"] = type == "controls.read" ? "controls.reading" : "controls.applied"; reply["id"] = id; reply["ok"] = true;
      reply["message"] = type == "controls.apply" ? "Control sent to the coding AI." : null;
      reply["reading"] = type == "controls.apply" && control is not null ? read[control]?.DeepClone() : read; return reply;
    }
    if (type.StartsWith("logins.", StringComparison.Ordinal))
    {
      if (device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Managing logins needs Full control.");
      if (type != "logins.read")
      {
        var id = PhoneText(message, "accountId")!;
        if (type == "logins.signin") await Accounts.SignInAsync(id, Hoot.Read().Settings?.Folder ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ct);
        else await Accounts.SignOutAsync(id, ct);
      }
      reply["t"] = type == "logins.signout" ? "logins.signedout" : "logins.state"; reply["ok"] = true;
      reply["accounts"] = new JsonArray(Accounts.List().Select(a => (JsonNode)PhoneAccount(a)).ToArray()); return reply;
    }
    if (type.StartsWith("settings.", StringComparison.Ordinal))
    {
      JsonObject Setting(string key) => key == "general.restoreSessions" ? new() { ["key"] = key, ["value"] = General.Read().RestoreSessions ? "true" : "false" } :
        new() { ["key"] = key, ["value"] = General.Read().DefaultProvider, ["options"] = new JsonArray("claude", "codex", "gemini", "shell") };
      if (type == "settings.apply")
      {
        if (device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Changing computer settings needs Full control.");
        var key = PhoneText(message, "key")!; var value = PhoneText(message, "value")!;
        if (key == "agents.defaultProvider" && value is "claude" or "codex" or "gemini" or "shell") General.Save(General.Read() with { DefaultProvider = value });
        else if (key == "general.restoreSessions" && bool.TryParse(value, out var restore)) General.Save(General.Read() with { RestoreSessions = restore });
        else throw new PhoneRefusal("bad-message", "Choose a supported computer setting.");
        reply["t"] = "settings.applied"; reply["ok"] = true; reply["message"] = "Setting saved."; reply["setting"] = Setting(key);
      }
      else { reply["t"] = "settings.state"; reply["settings"] = new JsonArray(Setting("agents.defaultProvider"), Setting("general.restoreSessions")); }
      return reply;
    }
    if (type.StartsWith("host.", StringComparison.Ordinal))
    {
      if (type != "host.status" && device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Managing this host needs Full control.");
      reply["t"] = "host.state"; reply["host"] = JsonSerializer.SerializeToNode(Remote.HostFacts(), PhoneJson);
      if (type != "host.status")
      {
        reply["host"]!["note"] = type == "host.restart" ? "Restart scheduled. Reconnect this phone." : "Stop scheduled. Sessions keep running.";
        // Flush the response before closing the relay which carries it.
        SchedulePhoneHostControl(type == "host.restart", recheck);
      }
      return reply;
    }
    if (type.StartsWith("github.", StringComparison.Ordinal))
    {
      if (type != "github.read" && device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Managing GitHub needs Full control.");
      await PhoneGithubChangeAsync(type, ct); var state = await CopyGitHub.AuthAsync(ct);
      reply["t"] = "github.state"; reply["github"] = new JsonObject { ["connected"] = state.Connected, ["login"] = state.Login, ["name"] = state.Name,
        ["source"] = state.Source, ["failure"] = phoneGithubFailure ?? state.Failure?.Message, ["pending"] = PhoneGithubPending(), ["disconnect"] = state.Source == "gh-cli" };
      return reply;
    }
    if (type is "dev.status" or "dev.start") return await PhoneDevAsync(device, type, message, ct);
    if (type is "routines" or "routine.text") return await PhoneRoutinesAsync(device, type, message, ct);
    // link.open is host → phone only ("open on my phone"); a phone never opens addresses on this PC.
    throw new PhoneRefusal("bad-message", "Unknown management message.");
  }
  private static string? PhoneText(JsonElement value, string key, bool required = true)
  {
    if (!value.TryGetProperty(key, out var field) && !required) return null;
    if (field.ValueKind != JsonValueKind.String || field.GetString() is not { Length: > 0 and <= 4096 } text || text.Any(char.IsControl)) throw new PhoneRefusal("bad-message", "Invalid " + key + ".");
    return text;
  }
  // The phones' permission ids (ControlCatalog): plan | manual | acceptEdits | auto | bypass.
  internal static AiPermissionMode? PhonePermissionMode(string? id) => id switch
  {
    "plan" => AiPermissionMode.Plan, "manual" or "default" => AiPermissionMode.Ask, "acceptEdits" => AiPermissionMode.AcceptEdits,
    "auto" => AiPermissionMode.Auto, "bypass" or "bypassPermissions" => AiPermissionMode.Bypass, _ => null
  };
  internal static string PhonePermissionId(AiPermissionMode mode) => mode switch
  { AiPermissionMode.Plan => "plan", AiPermissionMode.Ask => "manual", AiPermissionMode.AcceptEdits => "acceptEdits", AiPermissionMode.Auto => "auto", _ => "bypass" };
  internal static string PhonePermissionLabel(AiPermissionMode mode) => mode switch
  { AiPermissionMode.Plan => "Plan", AiPermissionMode.Ask => "Manual", AiPermissionMode.AcceptEdits => "Accept edits", AiPermissionMode.Auto => "Auto", _ => "Bypass" };
}
