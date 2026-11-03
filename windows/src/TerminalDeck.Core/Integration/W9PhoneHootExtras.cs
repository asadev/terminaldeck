using System.Collections.Immutable;
using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Integration;

public sealed partial class W9PhoneApplication
{
  // Account identity stays in the existing account owner; no credential is sent.
  public AccountService? Accounts { get; set; }
  private async ValueTask<PhoneApplicationReply> ExtraAsync(ApprovedDevice device, string type, JsonElement message, HootState state, CancellationToken ct)
  {
    var setting = state.Settings ?? throw new ProtocolException("Configure Hoot on this computer first.");
    var rid = type is "hoot.options.read" or "hoot.options.set" or "hoot.account.read" or "hoot.account.switch" ? Text(message, "rid", 128) : null;
    if (type is "hoot.options.set" or "hoot.account.switch" or "hoot.file.write" or "hoot.file.reset" or "hoot.memory.delete")
      if (device.Access != PhoneAccess.Full) throw new ProtocolException("Only Full control can change Hoot's settings or files.");
    if (type is "hoot.options.read" or "hoot.options.set")
    {
      if (type == "hoot.options.set")
      {
        var mode = setting.PermissionMode;
        if (message.TryGetProperty("permissionMode", out _))
        {
          var raw = Text(message, "permissionMode", 32);
          mode = raw switch { "default" => AiPermissionMode.Ask, "plan" => AiPermissionMode.Plan, "auto" => AiPermissionMode.Auto,
            "acceptEdits" => AiPermissionMode.AcceptEdits, "bypassPermissions" or "bypass" => AiPermissionMode.Bypass,
            _ => throw new ProtocolException("Choose an offered permission mode.") };
        }
        var model = message.TryGetProperty("model", out _) ? Text(message, "model", 160) : setting.Options.Model;
        var effort = message.TryGetProperty("effort", out _) ? Text(message, "effort", 32) : setting.Options.Effort;
        IReadOnlyList<ProviderModel> models;
        try { models = await hoot.ModelsAsync(setting.AccountId, ct); }
        catch (InvalidOperationException) { throw new ProtocolException("Hoot’s model catalogue is not available. Read its current choices and retry on this computer."); }
        if (model.Length > 0 && !models.Any(m => m.Id == model)) throw new ProtocolException("Choose an offered model.");
        var efforts = models.FirstOrDefault(m => m.Id == model)?.Efforts ?? [];
        if (effort.Length > 0 && efforts.Length > 0 && !efforts.Contains(effort)) throw new ProtocolException("Choose an offered effort.");
        await hoot.ConfigureAsync(setting with { PermissionMode = mode, Options = new(model, effort) }, ct);
        setting = hoot.Read().Settings!;
      }
      IReadOnlyList<ProviderModel> catalogue;
      try { catalogue = await hoot.ModelsAsync(setting.AccountId, ct); }
      catch (InvalidOperationException) { catalogue = []; }
      return Reply(new { t = "chats.options", rid, id = "hoot", options = new { permissionMode = WireMode(setting.PermissionMode), model = setting.Options.Model,
        effort = setting.Options.Effort, models = catalogue.Take(64).Select(m => new { id = m.Id, name = m.Name, provider = setting.Provider }),
        efforts = catalogue.FirstOrDefault(m => m.Id == setting.Options.Model)?.Efforts ?? [] } });
    }
    if (type is "hoot.account.read" or "hoot.account.switch")
    {
      var accounts = Accounts ?? throw new ProtocolException("This host has no account owner.");
      if (type == "hoot.account.switch")
      {
        var id = Text(message, "accountId", 200);
        var account = accounts.List().FirstOrDefault(a => a.Id == id && a.SignedIn && a.Provider == setting.Provider)
          ?? throw new ProtocolException("Choose a signed-in account for Hoot's coding AI.");
        await hoot.ConfigureAsync(setting with { AccountId = account.Id }, ct);
        return Reply(new { t = "account.switched", rid, id = "hoot", ok = true, session = "hoot", message = "Hoot's account changed." });
      }
      static object Row(AccountProfile a) => new { id = a.Id, name = a.Name, provider = a.Provider, color = a.Color, system = false,
        signIn = new { state = a.SignedIn ? "signed-in" : "signed-out", account = a.Email, plan = a.Plan } };
      return Reply(new { t = "account.state", rid, id = "hoot", current = accounts.List().FirstOrDefault(a => a.Id == setting.AccountId) is { } a ? Row(a) : null,
        accounts = accounts.List().Where(a => a.SignedIn && a.Provider == setting.Provider).Select(Row) });
    }
    // These are the real owner memory documents, never a path received from a phone.
    var files = new[] { (Id: "yours", Name: "Your instructions", Text: state.Memory.Card), (Id: "memory:playbook.md", Name: "Playbook", Text: state.Memory.Playbook), (Id: "contract", Name: "App instructions", Text: HootDesk.Instructions), (Id: "composed", Name: "Working context", Text: HootDesk.Snapshot(state, DateTimeOffset.UtcNow).Text) };
    if (type == "hoot.files") return Reply(new { t = "copilot.files.rows", files = files.Select(f => new { id = f.Id, name = f.Name, purpose = f.Name, owner = f.Id == "yours" ? "yours" : "app", exists = true, size = System.Text.Encoding.UTF8.GetByteCount(f.Text), writable = device.Access == PhoneAccess.Full && (f.Id is "yours" or "memory:playbook.md") }) });
    if (type == "hoot.memory.delete")
    {
      if (Text(message, "name", 128) != "playbook.md") throw new ProtocolException("Choose a memory document from Hoot’s list.");
      await hoot.SaveMemoryAsync(state.Memory.Card, "", ct);
      return await ExtraAsync(device, "hoot.files", message, await readHoot(ct), ct);
    }
    var fileId = Text(message, "id", 128);
    var file = files.FirstOrDefault(f => f.Id == fileId);
    if (file.Id is null) throw new ProtocolException("Choose a file from Hoot's list.");
    if (type is "hoot.file.write" or "hoot.file.reset")
    {
      if (fileId is not ("yours" or "memory:playbook.md")) throw new ProtocolException("This document is owned by the app and is read only.");
      var text = type == "hoot.file.reset" ? "" : Text(message, "text", 24000, controls: true);
      await hoot.SaveMemoryAsync(fileId == "yours" ? text : state.Memory.Card, fileId == "memory:playbook.md" ? text : state.Memory.Playbook, ct);
      return Reply(new { t = "copilot.file.text", id = fileId, text, error = (string?)null });
    }
    return Reply(new { t = "copilot.file.text", id = fileId, text = Clip(file.Text, 6000), error = (string?)null });
  }
  private static string WireMode(AiPermissionMode mode) => mode switch { AiPermissionMode.Ask => "default", AiPermissionMode.AcceptEdits => "acceptEdits", AiPermissionMode.Bypass => "bypassPermissions", _ => mode.ToString().ToLowerInvariant() };
}
