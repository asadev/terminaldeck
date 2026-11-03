using System.Collections.Immutable;
using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Integration;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  public W9PhoneHootGrants PhoneHootGrants { get; private set; } = null!;
  private void InitializePhoneWorkspace()
  {
    PhoneHootGrants = new(new JsonStateStore<W9PhoneHootGrantState>(Root, "phone-hoot-grants"));
    var recovery = new Services.PhoneRecoveryHost(Root, async ct =>
    {
      var current = await Keeper.ListAsync(ct);
      Volatile.Write(ref sessions, current.Sessions?.ToArray() ?? []);
      await Chats.RefreshAsync(ct);
    });
    Remote.WebEnrolled = EnrollWebWorkspace;
    Remote.AppVersion = PhoneAppVersion;
    // stream step 2: the direct link (libwebrtc), started on the first phone that asks for one.
    Remote.LinkEngine = TerminalDeck.Platform.Windows.Link.WebRtcLinkEngine.Lazy();
    // "Other computers" answers the same direct link (contract §11): its screens are H.264 on it.
    OtherComputers.LinkEngine = Remote.LinkEngine as ILinkAnswerEngine;
    Remote.WrapApplication = (application, view) => WrapPhoneFeatures(new W9PhoneApplication(
      new TaskPhoneApplication(application, Remote.Trust, new TaskPhoneReads(Tasks, Projects, ResolveTaskRecipient), TaskGrants.Allows),
      Remote.Trust, Hoot, view, PhoneHootGrants.Allows,
      CreateReceiverPhoneIntake((device, id) => Sessions.Any(s => s.Definition.Id == id && s.State == SessionState.Running &&
        s.Definition.Provider != "shell" && Remote.Grants.Allows(device, s)) || Chats.List().Any(c => c.Definition.Id == id && !c.Ended && Remote.Grants.Allows(device, ChatSessions.Session(c)))), readHoot: recovery.ReadAsync) { Accounts = Accounts, Attachments = ReadPhoneHootAttachmentsAsync });
  }
  public void SetPhoneWorkspace(string deviceId, string[] projects, bool hoot, PhoneAccess access)
  {
    if (!Remote.Trust.List().Concat(Remote.Trust.Pending()).Any(d => d.Id == deviceId)) throw new ArgumentException("Choose a paired phone first.");
    var selected = projects.Select(Projects.Get).Where(p => p.IsOpen).ToArray();
    if (selected.Length != projects.Length) throw new ArgumentException("Choose open projects for the phone.");
    var settings = Hoot.Read().Settings;
    if (access == PhoneAccess.Hoot) hoot = true;
    if (hoot && settings is null) throw new InvalidOperationException("Choose Hoot's account and folder on its page first.");
    TaskGrants.Set(new(deviceId, projects.ToImmutableArray()));
    if (settings is not null) PhoneHootGrants.Set(new(deviceId, settings.Folder, settings.AccountId, hoot));
    // The level chosen here also decides the sessions this phone sees (no separate hidden step):
    // Full control every session and chat, like the Mac; Work and Look only the ticked projects' sessions.
    WritePhoneSessionGrant(deviceId, selected, access);
    Remote.Trust.Approve(deviceId, access); Changed?.Invoke();
  }
  private void RegisterPhoneWorkspaceTools()
  {
    Door.Register("remote.workspace", async (context, args, ct) =>
    {
      context.Require("settings", "remote"); var id = args.GetProperty("deviceId").GetString()!; context.Require("devices", id);
      if (context.Grant.DeviceId is not null) throw new McpRefusal("A phone cannot change its own access.");
      if (args.TryGetProperty("projects", out var projects))
      {
        var ids = projects.EnumerateArray().Select(p => p.GetString()!).ToArray();
        foreach (var project in ids) context.Require("projects", project);
        var hoot = args.TryGetProperty("hoot", out var h) && h.GetBoolean();
        if (hoot) context.Require("hoot", "main");
        await context.EnsureCurrentAsync(ct);
        SetPhoneWorkspace(id, ids, hoot, Enum.Parse<PhoneAccess>(args.GetProperty("access").GetString()!, true));
      }
      return JsonSerializer.SerializeToElement(new { deviceId = id, hoot = PhoneHootGrants.List().FirstOrDefault(g => g.DeviceId == id),
        projects = Projects.List().Where(p => TaskGrants.HasProject(Remote.Trust.List().Single(d => d.Id == id), p.Id)).Select(p => p.Id) });
    });
  }
}
