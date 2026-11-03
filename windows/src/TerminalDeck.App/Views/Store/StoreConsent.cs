using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Store;

namespace TerminalDeck.App.Views.Store;

public sealed class StoreConsent(Func<XamlRoot> root, Func<Func<Task>, Task> dispatch) : IStoreAuthorizer
{
  public async ValueTask<bool> ApproveAsync(StoreEntry entry, string action, CancellationToken ct)
  {
    var approved = false;
    await dispatch(async () =>
    {
      ct.ThrowIfCancellationRequested();
      var body = new StackPanel { Spacing = 8, Children = { new TextBlock { Text = entry.Summary, TextWrapping = TextWrapping.Wrap, MaxWidth = 440 }, new TextBlock { Text = entry.Department + " · " + entry.Version, TextWrapping = TextWrapping.Wrap }, new TextBlock { Text = entry.Source, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true } } };
      var dialog = new ContentDialog { XamlRoot = root(), Title = (action == "remove" ? "Remove " : action == "update" ? "Update " : "Install ") + entry.Name + "?", Content = body, PrimaryButtonText = action == "remove" ? "Remove" : action == "update" ? "Update" : "Install", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
      using var cancellation = ct.Register(() => dialog.DispatcherQueue.TryEnqueue(dialog.Hide));
      approved = await dialog.ShowAsync() == ContentDialogResult.Primary;
    });
    return approved;
  }
}
