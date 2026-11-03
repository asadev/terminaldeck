using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  // Parent calls this once after constructing `browser`, with the same deferred
  // workspace already present in AppRuntime's phone composite.
  private void BindPhoneBrowserWorkspace(PhoneDeferredWorkspace deferred)
  {
    bool Visible(ApprovedDevice device, string id)
    {
      if (Runtime.Sessions.FirstOrDefault(s => s.Definition.Id == id) is { } terminal)
        return device.Access == PhoneAccess.Full || Runtime.Remote.Grants.Allows(device, terminal);
      if (Runtime.Chats.List().FirstOrDefault(c => c.Definition.Id == id) is { } chat)
        return device.Access == PhoneAccess.Full || Runtime.Remote.Grants.Allows(device, TerminalDeck.Core.Chats.ChatSessions.Session(chat));
      return false;
    }
    bool Allowed(ApprovedDevice device, string id)
    {
      var tab = browser.Core.Read().Tabs.FirstOrDefault(t => t.Id == id);
      return device.Access == PhoneAccess.Full && tab is not null && (tab.SessionId is null || Visible(device, tab.SessionId));
    }
    IReadOnlyList<(string Id, string Title)> Sessions(ApprovedDevice device) => Runtime.Sessions.Where(s => Visible(device, s.Definition.Id)).Select(s => (s.Definition.Id, s.Definition.Title))
      .Concat(Runtime.Chats.List().Where(c => Visible(device, c.Definition.Id)).Select(c => (c.Definition.Id, c.Definition.Title))).Take(32).ToArray();
    async ValueTask<JsonObject> Ui(Func<ValueTask<JsonObject>> action, CancellationToken ct)
    {
      ct.ThrowIfCancellationRequested();
      if (DispatcherQueue.HasThreadAccess) return await action();
      var completion = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
      if (!DispatcherQueue.TryEnqueue(async () =>
      {
        try { ct.ThrowIfCancellationRequested(); completion.TrySetResult(await action()); }
        catch (OperationCanceledException) { completion.TrySetCanceled(ct); }
        catch (Exception error) { completion.TrySetException(error); }
      })) throw new InvalidOperationException("The browser window is closing.");
      return await completion.Task.WaitAsync(ct);
    }
    browser.PhoneScreenshotDelivery = Runtime.DeliverPhoneBrowserScreenshotAsync;
    ValueTask<JsonObject> Control(ApprovedDevice device, string id, string type, JsonElement message, CancellationToken ct) => Ui(() => browser.PhoneBrowserControlAsync(device, id, type, message, ct), ct);
    deferred.Attach(new PhoneWorkspaceComposite(
      new PhoneBrowserFeatures(browser.Core, Ui, Visible, Sessions, browser.PhoneBrowserStatus, Control),
      new PhoneBrowserWatchFeatures(Allowed,
        (id, width, quality, ct) => Ui(() => browser.CapturePhoneFrameAsync(id, width, quality, ct), ct),
        device => browser.Core.Read().Tabs.Where(t => Allowed(device, t.Id)).Select(t => (t.Id, t.Url, t.Title)).ToArray(), Control)));
  }
}
