using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.App.Views;

// Suspend the visible Cloud surface without destroying its draft or preferences.
// With paywall off this is a transparent layout wrapper around the original view.
internal sealed class CloudAccessSurface : Grid
{
  internal CloudAccessSurface(FrameworkElement content, Func<bool> allowed, Action<Action> subscribe, Action<Action> unsubscribe)
  {
    RequestedTheme = content.RequestedTheme; Children.Add(content);
    var message = new TextBlock { Text = CloudRelayLifecycle.SubscriptionRequired, FontSize = 14, TextWrapping = TextWrapping.Wrap, MaxWidth = 520, Margin = new(24), VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
    message.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush"); Children.Add(message);
    void Apply() { var open = allowed(); content.Visibility = open ? Visibility.Visible : Visibility.Collapsed; message.Visibility = open ? Visibility.Collapsed : Visibility.Visible; }
    void Changed() => DispatcherQueue.TryEnqueue(Apply);
    Loaded += (_, _) => { subscribe(Changed); Apply(); }; Unloaded += (_, _) => unsubscribe(Changed); Apply();
  }
}
