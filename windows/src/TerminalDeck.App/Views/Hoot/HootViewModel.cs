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
    if (Pending || string.IsNullOrWhiteSpace(Draft)) return;
    if (sendId is not null && sentText != Draft)
    { Error = "Check the previous send before changing this message. Its delivery has not been confirmed."; Notify(nameof(Error)); return; }
    sendId ??= Guid.NewGuid().ToString(); sentText = Draft; var text = Draft;
    await RunAsync(async () =>
    {
      await hoot.SayAsync(sendId, text);
      sendId = null; sentText = null;
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
