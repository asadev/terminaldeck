using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  private sealed class BrowserQuestion(string message)
  {
    public string Id { get; } = Guid.NewGuid().ToString("N");
    public string Message { get; } = message;
    public TaskCompletionSource<bool> Review { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public ContentDialog? Dialog { get; set; }
    public Action? CancelNative { get; set; }
  }
  private readonly Dictionary<string, List<BrowserQuestion>> pageQuestions = [];
  private BrowserQuestion QueuePageQuestion(BrowserTab tab, string message)
  {
    var question = new BrowserQuestion("Waiting for you: " + message + " Open this tab and choose Review. Do not repeat the page action.");
    if (!pageQuestions.TryGetValue(tab.Id, out var queue)) pageQuestions[tab.Id] = queue = [];
    if (queue.Count >= 8)
    {
      RequestUnavailable(tab, "This page has too many unanswered questions. Answer or cancel its current questions first."); question.Review.TrySetResult(false); return question;
    }
    queue.Add(question); tab.PageRequestNote = queue[0].Message; tab.RequestAttention.TrySetResult(); RefreshShellViews(); ShellChanged?.Invoke();
    if (queue.Count == 1 && PersonCanAnswer(tab)) question.Review.TrySetResult(true);
    return question;
  }
  private void FinishPageQuestion(BrowserTab tab, BrowserQuestion question)
  {
    if (!pageQuestions.TryGetValue(tab.Id, out var queue)) return;
    queue.Remove(question);
    if (queue.Count == 0)
    {
      pageQuestions.Remove(tab.Id);
      if (tab.PageRequestNote?.StartsWith("Waiting for you:", StringComparison.Ordinal) == true) tab.PageRequestNote = null;
      tab.RequestAttention = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
    else
    {
      tab.PageRequestNote = queue[0].Message;
      if (PersonCanAnswer(tab)) queue[0].Review.TrySetResult(true);
    }
    RefreshShellViews(); ShellChanged?.Invoke();
  }
  private void ReviewPageQuestion(BrowserTab tab)
  {
    if (!PersonCanAnswer(tab) || !pageQuestions.TryGetValue(tab.Id, out var queue) || queue.Count == 0) return;
    tab.View.Focus(FocusState.Programmatic); queue[0].Review.TrySetResult(true);
  }
  private void CancelPageQuestion(BrowserTab tab)
  {
    if (!pageQuestions.TryGetValue(tab.Id, out var queue) || queue.Count == 0)
    { tab.PageRequestNote = null; tab.RequestAttention = new(TaskCreationOptions.RunContinuationsAsynchronously); RefreshShellViews(); ShellChanged?.Invoke(); return; }
    queue[0].Dialog?.Hide(); queue[0].CancelNative?.Invoke(); queue[0].Review.TrySetResult(false);
  }
  private void CancelPageQuestions(BrowserTab tab)
  {
    var changed = tab.PageRequestNote is not null || tab.RequestAttention.Task.IsCompleted;
    if (pageQuestions.Remove(tab.Id, out var queue))
    {
      changed = true;
      foreach (var question in queue) { question.Dialog?.Hide(); question.CancelNative?.Invoke(); question.Review.TrySetResult(false); }
    }
    tab.PageRequestNote = null;
    if (changed) tab.RequestAttention = new(TaskCreationOptions.RunContinuationsAsynchronously);
  }
  private async Task<T> WithPageQuestionsAsync<T>(BrowserTab tab, Task<T> operation, CancellationToken ct)
  {
    var attention = tab.RequestAttention.Task;
    // Leave the original Chromium request alive for the person. The caller gets
    // a bounded waiting answer, never an invented dialog answer or duplicate click.
    _ = operation.ContinueWith(failed => { _ = failed.Exception; }, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    var completed = await Task.WhenAny(operation, attention).WaitAsync(TimeSpan.FromSeconds(30), ct);
    if (completed == attention && tab.PageRequestNote is { } note) throw new InvalidOperationException(note);
    return await operation.WaitAsync(TimeSpan.FromSeconds(30), ct);
  }
}
