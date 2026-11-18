using Microsoft.UI.Xaml.Controls;

namespace TerminalDeck.App.Views.Hoot;

public sealed partial class HootPage
{
  private HootHandoffDocument? handoffDocument;
  public void FailHandoffDocument(string message) => handoffDocument?.Fail(message);
  public void OpenHandoffDocument(string turnId)
  {
    void Close()
    {
      if (handoffDocument is not { } old) return;
      Children.Remove(old); old.Dispose(); handoffDocument = null;
    }
    Close(); handoffDocument = new(Model, turnId, Close, DataDirectory);
    SetRowSpan(handoffDocument, 4); Canvas.SetZIndex(handoffDocument, 20); Children.Add(handoffDocument);
  }
}
