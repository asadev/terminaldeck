using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Views.Chat;
namespace TerminalDeck.App.Views.Chat;
public sealed partial class ChatPage
{
  public ContentDialog? ProofDialog => currentDialog;
  public void ProofSearch(string text) { OpenSearch(); searchBox.Text = text; }
  public object ProofSearchState => new { count = matches.Count, selectedMatch, findNavigationPending, scroll.VerticalOffset, scroll.ScrollableHeight, scroll.ViewportHeight, targetY = messageElements.TryGetValue("user:old", out var target) ? target.TransformToVisual(scroll).TransformPoint(new Windows.Foundation.Point(0, 0)).Y : double.NaN };
  public int ProofMatchCount => matches.Count;
  public bool ProofOldMessageVisible
  {
    get
    {
      if (!messageElements.TryGetValue("user:old", out var target)) return false;
      var box = target.TransformToVisual(scroll).TransformBounds(new(0, 0, target.ActualWidth, target.ActualHeight));
      return box.Bottom > 0 && box.Top < scroll.ViewportHeight;
    }
  }
  public Task ProofSideQuestion() => ShowSideQuestionAsync();
  public Task ProofInspector() => ShowInspectorAsync();
  public Task ProofHistory() => ShowHistoryAsync();
  public Task ProofChanges() => ShowChangesAsync();
  public Task ProofUsage() => ShowUsageAsync();
  public Task ProofEvents() => ShowEventsAsync();
  public Task ProofPrompts() => ShowPromptSearchAsync();
  public Task ProofRename() => ShowRenameAsync();
  public Task ProofEdit() => EditFullPromptAsync();
  public void ProofPermissions() => ShowPermissions();
  public void ProofCloseSearch() => CloseSearch();
  public bool ProofLateMessageVisible => messageElements.TryGetValue("assistant:late", out var target) && target.TransformToVisual(scroll).TransformPoint(new Windows.Foundation.Point(0, 0)).Y < scroll.ViewportHeight;
  public ScrollViewer ProofScroll => scroll;
  public Button ProofUnread => unread;
}
