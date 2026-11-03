using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private PhoneArtifactServer? phoneArtifactServer;
  private PhonePushFeatures? phonePush;
  private HootState? lastPhonePushHoot;
  private readonly Dictionary<string, (bool Busy, bool Waiting)> phonePushChats = [];
  private readonly HttpClient phonePushHttp = new() { Timeout = TimeSpan.FromSeconds(20) };
  private IPhoneHostWorkspace CreateExtendedPhoneWorkspace(PhoneSessionsHost host)
  {
    phoneArtifactServer ??= new(Artifacts, (id, folder) => Remote.Trust.List().FirstOrDefault(d => d.Id == id) is { } d &&
      d.Access != PhoneAccess.Hoot && (d.Access == PhoneAccess.Full || host.Folders(d).Any(f => TerminalDeck.Core.Mcp.McpCallerScopes.Within(f, folder))));
    if (phonePush is null)
    {
      phonePush = new(new ProtectedPhonePushStore(Root), PhonePushMayHear, Remote.PushRelay, PhonePushPostAsync, Environment.MachineName);
      Hoot.Changed += PhonePushHootChanged;
      Changed += PhonePushChatsChanged;
      Remote.Trust.Changed += PhoneAccessRetired;
    }
    return new PhoneWorkspaceComposite(
      new PhoneOwnerFeatures(PhoneManagementMessageAsync),
      new PhonePanelRegistry((device, folder) => device.Access == PhoneAccess.Full || host.Folders(device).Any(f => TerminalDeck.Core.Mcp.McpCallerScopes.Within(f, folder)),
        [PhoneReceiverPanel.Create(Receiver, PhoneProjectAllowed, PhoneReceiverTargetAllowed, ReceiverSources), .. PhoneDomainPanels()]),
      phonePush);
  }
  private bool PhoneReceiverTargetAllowed(ApprovedDevice device, ReceiverTarget target) => device.Access == PhoneAccess.Full || target.Kind switch
  {
    RouteKind.Hoot => PhoneHootGrants.Allows(device, Hoot.Read()),
    RouteKind.Session or RouteKind.Chat => target.Id is not null && PhoneHootHas(device, "sessions", target.Id),
    RouteKind.Agent => target.Id is not null && Agents.List().Any(a => a.Id == target.Id && PhoneProjectAllowed(device, a.ProjectId)),
    _ => false
  };
  private bool PhonePushMayHear(string deviceId, PhonePushNotice notice)
  {
    var device = Remote.Trust.List().FirstOrDefault(d => d.Id == deviceId); if (device is null) return false;
    if (notice.Kind == "hoot") return PhoneHootGrants.Allows(device, Hoot.Read());
    if (device.Access == PhoneAccess.Hoot) return false;
    var host = new PhoneSessionsHost(this);
    return Sessions.Any(s => s.Definition.Id == notice.Session && host.Visible(device, s)) || Chats.List().Any(c => c.Definition.Id == notice.Session && host.Visible(device, c));
  }
  private async ValueTask<(int Status, byte[] Body)> PhonePushPostAsync(Uri address, IReadOnlyDictionary<string, string> headers, byte[]? body, CancellationToken ct)
  {
    using var request = new HttpRequestMessage(body is null ? HttpMethod.Get : HttpMethod.Post, address);
    if (body is not null) { request.Content = new ByteArrayContent(body); request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json"); }
    foreach (var (name, value) in headers.Where(h => h.Key != "content-type")) request.Headers.TryAddWithoutValidation(name, value);
    using var response = await phonePushHttp.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
    if (response.Content.Headers.ContentLength > 65536) throw new IOException("The alert relay returned an oversized answer.");
    await using var stream = await response.Content.ReadAsStreamAsync(ct); using var output = new MemoryStream(); var buffer = new byte[4096];
    while (true) { var read = await stream.ReadAsync(buffer, ct); if (read == 0) break; if (output.Length + read > 65536) throw new IOException("The alert relay returned an oversized answer."); output.Write(buffer, 0, read); }
    return ((int)response.StatusCode, output.ToArray());
  }
  private void PhonePushHootChanged(HootState state)
  {
    var previous = lastPhonePushHoot; lastPhonePushHoot = state;
    if (previous is null || previous.ConversationId != state.ConversationId) return;
    if (previous.Busy && !state.Busy && state.Turns.LastOrDefault()?.State == HootTurnState.Finished)
      _ = SendPhoneNoticeAsync(new("hoot", "hoot", "Hoot", "Hoot", "", state.Lines.LastOrDefault(l => l.Kind == "assistant")?.Text));
  }
  private void PhonePushChatsChanged()
  {
    foreach (var chat in Chats.List().Where(c => c.Definition.Id != Hoot.Read().ChatId))
    {
      var waiting = chat.Problem is not null || ChatProjection.Rows(chat).Any(r => r.Kind == "approval" && r.Waiting);
      (bool Busy, bool Waiting)? previous; lock (phonePushChats) { previous = phonePushChats.TryGetValue(chat.Definition.Id, out var known) ? known : null; phonePushChats[chat.Definition.Id] = (chat.Busy, waiting); }
      if (previous is null || chat.Ended) continue;
      if (!previous.Value.Waiting && waiting) _ = SendPhoneNoticeAsync(new("needs-you", chat.Definition.Id, chat.Definition.Provider, chat.Definition.Title, chat.Definition.Cwd, chat.Problem));
      else if (previous.Value.Busy && !chat.Busy && !waiting) _ = SendPhoneNoticeAsync(new("finished", chat.Definition.Id, chat.Definition.Provider, chat.Definition.Title, chat.Definition.Cwd));
    }
  }
  private async Task SendPhoneNoticeAsync(PhonePushNotice notice)
  { try { if (phonePush is not null) await phonePush.NotifyAsync(notice); } catch (Exception e) when (e is IOException or HttpRequestException or OperationCanceledException or JsonException or ObjectDisposedException) { } }
  private void PhoneAccessRetired()
  {
    foreach (var id0 in phonePush?.DeviceIds() ?? [])
      if (!Remote.Trust.List().Any(d => d.Id == id0)) { phonePush?.Forget(id0); phoneArtifactServer?.Forget(id0); }
    var active = Hoot.Read().Active;
    if (active?.Source.DeviceId is { } id && (Remote.Trust.List().FirstOrDefault(d => d.Id == id) is not { } device ||
      device.Access == PhoneAccess.Look || !active.Source.Restricted && device.Access != PhoneAccess.Full || !PhoneHootGrants.Allows(device, Hoot.Read()))) _ = StopRetiredPhoneHootAsync();
  }
  private async Task StopRetiredPhoneHootAsync() { try { await Hoot.StopAsync(); } catch (Exception e) when (e is IOException or InvalidOperationException) { } }
  private void DisposePhoneExtendedWorkspace()
  {
    Hoot.Changed -= PhonePushHootChanged; Changed -= PhonePushChatsChanged; Remote.Trust.Changed -= PhoneAccessRetired;
    phoneManagementLifetime.Cancel(); DisposeRoutineEvents(); DisposePhoneTrace(); phoneArtifactServer?.Dispose(); phoneRoutines?.Dispose(); phoneGithubStop?.Cancel(); phonePushHttp.Dispose();
  }
  private sealed class ProtectedPhonePushStore(AppDataRoot root) : IStateStore<PhonePushState>
  {
    private readonly JsonStateStore<byte[]> store = new(root, "phone-push-protected");
    private readonly TerminalDeck.Platform.Windows.CurrentUserDpapi protector = new(root);
    public PhonePushState? Load()
    {
      var protectedValue = store.Load(); if (protectedValue is null) return null;
      var bytes = protector.Unprotect(protectedValue); try { return JsonSerializer.Deserialize<PhonePushState>(bytes); } finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(bytes); }
    }
    public void Save(PhonePushState value)
    {
      var bytes = JsonSerializer.SerializeToUtf8Bytes(value); try { store.Save(protector.Protect(bytes)); } finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(bytes); }
    }
  }
}
