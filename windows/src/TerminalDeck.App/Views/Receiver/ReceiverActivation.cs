using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Platform.Windows.Receiver;
using Windows.ApplicationModel.Activation;
using Windows.ApplicationModel.DataTransfer;

namespace TerminalDeck.App.Views.Receiver;

// Shell/App owns the calls, this lane owns all intake behavior. BindDrop works
// on the window root too; it must not be installed over the terminal's own drop.
public sealed class ReceiverActivation(WindowsReceiverData data, string shareSource, string dropSource)
{
  public event Action<string>? Outcome;
  public async Task<bool> ActivateAsync(AppActivationArguments activation)
  {
    if (activation.Kind != ExtendedActivationKind.ShareTarget || activation.Data is not ShareTargetActivatedEventArgs args) return false;
    var item = await data.ShareAsync(args.ShareOperation, shareSource);
    Outcome?.Invoke(item is null ? "The shared item could not be saved." : "Saved to Receiver for review."); return true;
  }
  public IDisposable BindDrop(UIElement surface)
  {
    var old = surface.AllowDrop; surface.AllowDrop = true;
    void Enter(object sender, DragEventArgs args)
    {
      if (Supported(args.DataView)) { args.AcceptedOperation = DataPackageOperation.Copy; args.Handled = true; }
    }
    async void Drop(object sender, DragEventArgs args)
    {
      if (!Supported(args.DataView)) return;
      args.Handled = true; var deferral = args.GetDeferral();
      try { await data.ReadAsync(args.DataView, dropSource, "Dropped onto the window"); Outcome?.Invoke("Saved to Receiver for review."); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { Outcome?.Invoke("The dropped item could not be saved. Check the source and inbox limits."); }
      finally { deferral.Complete(); }
    }
    surface.DragOver += Enter; surface.Drop += Drop;
    return new DropBinding(() => { surface.DragOver -= Enter; surface.Drop -= Drop; surface.AllowDrop = old; });
  }
  private static bool Supported(DataPackageView data) => new[] { StandardDataFormats.Text, StandardDataFormats.WebLink, StandardDataFormats.Bitmap, StandardDataFormats.StorageItems }.Any(data.Contains);
  private sealed class DropBinding(Action dispose) : IDisposable { public void Dispose() => dispose(); }
}
