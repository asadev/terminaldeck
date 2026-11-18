using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views.Notices;

namespace TerminalDeck.App.Views;

public sealed partial class SessionPane
{
  private readonly CompactNotice sessionNotice = new();
  private readonly Grid endedOverlay = new() { Visibility = Visibility.Collapsed };
  private readonly TextBlock endedTitle = new() { FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap };
  private readonly TextBlock endedDetail = new() { FontSize = 12, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap };
  private readonly TextBlock endedGlyph = new() { FontSize = 17, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
  private readonly Border endedTile = new() { Width = 40, Height = 40, CornerRadius = new(20), HorizontalAlignment = HorizontalAlignment.Center };
  private Button? startAgain;
  internal Func<Task>? RestartRequested { get; set; }
  internal Action? CloseEndedRequested { get; set; }
  private void InitializeSessionNotices(Grid area)
  {
    sessionNotice.Scope = area; area.Children.Add(sessionNotice);
    if (draft.Presentation != SessionPresentation.Terminal) return;
    var veil = new Border { Opacity = .62 }; veil.SetResourceReference(Border.BackgroundProperty, WorkspacePaper.Terminal); endedOverlay.Children.Add(veil);
    var content = new StackPanel { Spacing = 8 }; endedTile.Child = endedGlyph; content.Children.Add(endedTile); content.Children.Add(endedTitle); content.Children.Add(endedDetail);
    endedDetail.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    startAgain = new Button { Content = "Start again here", Style = (Style)Application.Current.Resources["AccentButtonStyle"], Height = 28, MinHeight = 28, Padding = new(20, 0, 20, 0), CornerRadius = new(7), FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center, Margin = new(0, 6, 0, 0) };
    startAgain.Click += async (_, _) =>
    {
      if (RestartRequested is null) return;
      startAgain.IsEnabled = false; startAgain.Content = "Starting…";
      try { await RestartRequested(); }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException) { endedDetail.Text = ex.Message; }
      finally { startAgain.IsEnabled = true; startAgain.Content = "Start again here"; }
    };
    content.Children.Add(startAgain);
    var close = new Button { Content = "Close session", Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"], Width = double.NaN, MinWidth = 0, Height = 28, MinHeight = 28, FontSize = 12, Padding = new(8, 0, 8, 0), HorizontalAlignment = HorizontalAlignment.Center };
    close.SetResourceReference(Control.ForegroundProperty, "DeckSecondaryInkBrush"); close.Click += (_, _) => CloseEndedRequested?.Invoke(); content.Children.Add(close);
    var card = new Border { Child = content, MaxWidth = 340, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, CornerRadius = new(14), Padding = new(22), Margin = new(20), BorderThickness = new(.5), Shadow = new ThemeShadow(), Translation = new System.Numerics.Vector3(0, 0, 32) };
    card.SetResourceReference(Border.BackgroundProperty, "DeckCardBrush"); card.SetResourceReference(Border.BorderBrushProperty, "DeckTabRimBrush");
    endedOverlay.Children.Add(card); SetRowSpan(endedOverlay, 2); Canvas.SetZIndex(endedOverlay, 20); area.Children.Add(endedOverlay);
    AutomationProperties.SetLiveSetting(endedTitle, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
  }
  private void ShowSessionNotice(string message)
  {
    sessionNotice.AutoDismiss = true; sessionNotice.Message = message; sessionNotice.IsOpen = !string.IsNullOrWhiteSpace(message);
  }
  private bool ended;
  private bool IsEnded => draft.State is "exited" or "ended";
  private void ShowEnded(bool value)
  {
    ended = value; endedOverlay.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
    if (!value) return;
    var exit = runtime?.Sessions.FirstOrDefault(row => row.Definition.Id == draft.Id)?.ExitCode;
    var failed = exit is not null and not 0;
    endedTitle.Text = failed ? "This session stopped with an error" : "This session ended";
    endedDetail.Text = failed ? "The program exited with status " + exit + ". Its last screen is still here." : "The program finished. Its last screen is still here.";
    endedGlyph.Text = failed ? "!" : "✓";
    endedGlyph.SetResourceReference(TextBlock.ForegroundProperty, failed ? "DeckProjectOrangeBrush" : "DeckSecondaryInkBrush");
    endedTile.SetResourceReference(Border.BackgroundProperty, "DeckControlBrush");
    if (startAgain is not null) startAgain.Visibility = runtime is not null ? Visibility.Visible : Visibility.Collapsed;
  }
  private void DraftStateChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
  {
    if (args.PropertyName != nameof(SessionDraft.State)) return;
    DispatcherQueue.TryEnqueue(() => { if (!disposed) ShowEnded(IsEnded); });
  }
  internal void TerminalActionFailed(Exception error)
  {
    UiRecovery.Log("Terminal action", error); ShowSessionNotice("The terminal action could not finish. Try again.");
  }
}
