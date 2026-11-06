using System.ComponentModel;
using System.Runtime.CompilerServices;
using TerminalDeck.Core.Hoot;

namespace TerminalDeck.App.Views.Hoot;

public sealed class HootViewModel : INotifyPropertyChanged, IDisposable
{
  private readonly IHoot hoot;
  private readonly Action<Action> dispatch;
  public HootState State { get; private set; }
  public string Draft { get; set; } = "";
  public string? Error { get; private set; }
  public bool Pending { get; private set; }
  private string? sendId;
  private string? sentText;
  private TerminalDeck.Core.Chats.ChatAttachmentData[]? sentAttachments;
  public List<TerminalDeck.Core.Chats.ChatAttachmentData> Attachments { get; } = [];
  public void AddAttachment(TerminalDeck.Core.Chats.ChatAttachmentData image)
  {
    if (Attachments.Count >= 8 || Attachments.Sum(a => a.Data.Length) + image.Data.Length > 4 * 1024 * 1024) throw new ArgumentException("Send up to eight images totalling at most 4 MB to Hoot.");
    Attachments.Add(image); Notify(nameof(Attachments));
  }
  public void RemoveAttachment(TerminalDeck.Core.Chats.ChatAttachmentData image) { Attachments.Remove(image); Notify(nameof(Attachments)); }
  public Task BranchAsync(string id, bool rewind) => RunAsync(() => hoot.BranchAsync(id, rewind));
  public event PropertyChangedEventHandler? PropertyChanged;
  public HootViewModel(IHoot hoot, Action<Action>? dispatch = null)
  { this.hoot = hoot; this.dispatch = dispatch ?? (a => a()); State = hoot.Read(); hoot.Changed += Changed; }
  private void Changed(HootState state) => dispatch(() => { State = state; Notify(nameof(State)); });
  private void Notify([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new(name));
  public async Task RunAsync(Func<ValueTask> action)
  {
    if (Pending) return;
    Pending = true; Error = null; Notify(nameof(Pending)); Notify(nameof(Error));
    try { await action(); State = hoot.Read(); Notify(nameof(State)); }
    catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or IOException or TimeoutException)
    { Error = ex is IOException or TimeoutException ? "The reply was lost. Your message is kept. Reopen Hoot to check it before sending again." : ex.Message; Notify(nameof(Error)); }
    finally { Pending = false; Notify(nameof(Pending)); }
  }
  public async Task SendAsync()
  {
    if (Pending || string.IsNullOrWhiteSpace(Draft) && Attachments.Count == 0) return;
    if (sendId is not null && sentText != Draft)
    { Error = "Check the previous send before changing this message. Its delivery has not been confirmed."; Notify(nameof(Error)); return; }
    sendId ??= Guid.NewGuid().ToString(); sentText = Draft; sentAttachments ??= Attachments.ToArray(); var text = Draft; var images = sentAttachments;
    await RunAsync(async () =>
    {
      if (images.Length > 0) await hoot.SayWithAttachmentsAsync(sendId, text, images);
      else await hoot.SayAsync(sendId, text);
      foreach (var image in images) Attachments.Remove(image); Notify(nameof(Attachments));
      sendId = null; sentText = null; sentAttachments = null;
      if (Draft == text) { Draft = ""; Notify(nameof(Draft)); }
    });
  }
  public Task StopAsync() => RunAsync(() => hoot.StopAsync());
  public Task ReadyAsync() => RunAsync(() => hoot.EnsureReadyAsync());
  public Task KeepUnconfirmedAsync() => RunAsync(() => hoot.KeepUnconfirmedAsync());
  public Task ContinueAsync() => RunAsync(() => hoot.ContinueAsync());
  public Task RefreshAsync() => RunAsync(() => hoot.RefreshAsync());
  public Task AnswerAsync(string id, bool allow) => RunAsync(() => hoot.AnswerAsync(id, allow));
  public Task CancelAsync(string id) => RunAsync(() => hoot.CancelBackgroundAsync(id));
  public ValueTask<IReadOnlyList<TerminalDeck.Core.Accounts.ProviderModel>> ModelsAsync(string accountId) => hoot.ModelsAsync(accountId);
  public Task ConfigureAsync(HootSettings settings) => RunAsync(() => hoot.ConfigureAsync(settings));
  public Task MemoryAsync(string card, string playbook) => RunAsync(() => hoot.SaveMemoryAsync(card, playbook));
  public Task BoardAsync(HootBoardRow row) => RunAsync(() => hoot.SaveBoardAsync(row));
  public Task HandoffAsync(string id, string sessionId, string text) => RunAsync(async () =>
  {
    var result = await hoot.HandoffAsync(id, sessionId, text);
    if (!result.Sent) throw new InvalidOperationException("This handoff may already have arrived. Check the session before sending another.");
  });
  public void Dispose() => hoot.Changed -= Changed;
}
