using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views;

/// The `terminaldeck://` links of Cloud (protocol registered in the package manifest; App.xaml.cs keeps one running copy
/// per data folder and redirects every later activation to it).
/// - `terminaldeck://cloud/return/<token>?code&state`: the website's "Open Terminal Deck" after sign-in. Finished by
///   itself, with no dialog, only when it answers the sign-in this copy started; anything else does nothing and leaves
///   one plain line in the log (CloudAccountClient.FinishAppReturnAsync).
/// - `terminaldeck://cloud/signin`: as on the Mac, a link never starts a sign-in by itself: it opens Settings → Cloud
///   and asks once; Cancel keeps further links quiet for ten minutes.
public sealed partial class ShellWindow
{
  private bool cloudLinkAsking;
  private DateTimeOffset cloudLinkQuietUntil;

  internal static bool IsCloudSignInLink(Uri? uri) => uri is { Scheme: "terminaldeck", Host: "cloud", AbsolutePath: "/signin" };

  private async void QueueCloudLink(Microsoft.Windows.AppLifecycle.AppActivationArguments activation)
  {
    if (activation.Data is not global::Windows.ApplicationModel.Activation.IProtocolActivatedEventArgs link) return;
    if (CloudAppReturn.IsReturnLink(link.Uri)) { FinishCloudReturn(link.Uri); return; }
    if (!IsCloudSignInLink(link.Uri)) return;
    try
    {
      await Ready;
      await OnUiAsync(async () =>
      {
        await OpenSettingsAsync("cloud");
        var phase = Runtime.Cloud.Snapshot.Phase;
        if (phase is CloudPhase.SignedIn or CloudPhase.Paused)
        {
          Model.Notice = "A sign-in link was opened. This PC is already signed in to Cloud; to use another account, sign out first.";
          return;
        }
        if (phase == CloudPhase.SigningIn || cloudLinkAsking || DateTimeOffset.UtcNow < cloudLinkQuietUntil) return;
        cloudLinkAsking = true;
        try
        {
          var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, RequestedTheme = Root.ActualTheme, Title = "Sign in to Cloud on this PC?",
            Content = new TextBlock { Text = "A link asked " + TerminalDeck.Core.Brand.Name + " to sign in. Continue only if you opened it yourself.", TextWrapping = Microsoft.UI.Xaml.TextWrapping.Wrap },
            PrimaryButtonText = "Continue", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
          if (await dialog.ShowAsync() != ContentDialogResult.Primary) { cloudLinkQuietUntil = DateTimeOffset.UtcNow.AddMinutes(10); return; }
        }
        finally { cloudLinkAsking = false; }
        await Runtime.Cloud.BeginSignInAsync();
      });
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      DispatcherQueue.TryEnqueueHandled(() => Model.Notice = "Cloud sign-in could not start. Open Settings → Cloud and press Sign in.");
    }
  }

  /// The return link. No dialog: the account decides whether it answers this copy's own sign-in. When it did, Settings →
  /// Cloud opens on the result (signed in, or the plain problem the page shows).
  private async void FinishCloudReturn(Uri link)
  {
    bool answered;
    try
    {
      await Ready;
      answered = await Runtime.Cloud.FinishAppReturnAsync(link);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { answered = true; }
    if (!answered) return;
    try { await OnUiAsync(() => OpenSettingsAsync("cloud")); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
  }
}
