using TerminalDeck.Core.Receiver;

namespace TerminalDeck.App.ViewModels.Receiver;

public sealed class ReceiverViewModel(IReceiver receiver, IReceiverIntakeSettings settings)
{
  public IReceiver Receiver { get; } = receiver;
  public IReceiverIntakeSettings Settings { get; } = settings;
  public string? ProjectFilter { get; set; }
  public string? SourceFilter { get; set; }
  public InboxStatus? StatusFilter { get; set; }
  public string Query { get; set; } = "";
  public string? SelectedId { get; set; }
  public bool Busy { get; private set; }
  public string Message { get; private set; } = "";
  public bool IsError { get; private set; }
  public event Action? Changed;
  public void ShowMessage(string text) { Message = text; IsError = false; Changed?.Invoke(); }
  public IReadOnlyList<ReceiverItem> Items => Receiver.Items(SourceFilter, StatusFilter, Query, 1000).Where(i => ProjectFilter is null || i.ProjectId == ProjectFilter).Take(200).ToArray();
  public ReceiverItem? Selected => SelectedId is { } id ? Receiver.Items(limit: 1000).FirstOrDefault(i => i.Id == id) : null;
  public async Task RunAsync(Func<Task> action, string success)
  {
    if (Busy) return;
    Busy = true; Message = "Working…"; IsError = false; Changed?.Invoke();
    try { await action(); Message = success; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Message = ex is ArgumentException or IOException ? ex.Message : "That did not work. Please try again."; IsError = true; }
    finally { Busy = false; Changed?.Invoke(); }
  }
  public Task RouteAsync(ReceiverTarget target) => RunAsync(async () =>
  {
    var item = Selected ?? throw new ArgumentException("Choose an inbox item.");
    var result = await Receiver.RouteAsync(item.Id, target);
    if (result.Status != InboxStatus.Delivered) throw new IOException(result.Outcome);
  }, "Sent to the destination.");
}
