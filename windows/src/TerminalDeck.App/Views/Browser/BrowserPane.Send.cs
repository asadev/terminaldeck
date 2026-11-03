using Microsoft.UI.Xaml;

namespace TerminalDeck.App.Views;

public sealed record BrowserSendRequest(string Message, string? ImagePath, string? SessionId, XamlRoot Root);
public enum BrowserSendOutcome { KeptDraft, Sent }

public sealed partial class BrowserPane
{
  public Func<BrowserSendRequest, Task<BrowserSendOutcome>>? SendRequest { get; set; }
  private async Task<BrowserSendOutcome> ReviewSendAsync(BrowserTab tab, string message, string? image = null)
  {
    if (SendRequest is not null) return await SendRequest(new(message, image, Core.Get(tab.Id).SessionId, RootFor(tab)));
    if (image is not null) throw new InvalidOperationException("This window’s image sender is not connected yet. The saved picture and instruction are kept.");
    await send(message); return BrowserSendOutcome.KeptDraft;
  }
}
