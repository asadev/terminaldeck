using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private readonly HashSet<string> reopeningSessions = [];
  private void RenderNotReopenedRows(SessionDraft[] rows)
  {
    NotReopenedRows.Children.Clear();
    NotReopenedRows.Visibility = rows.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    if (rows.Length == 0) return;
    var heading = new TextBlock { Text = "Not reopened", FontSize = 11, Margin = new(8, 12, 0, 4) };
    heading.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush"); NotReopenedRows.Children.Add(heading);
    foreach (var session in rows)
    {
      var content = new Grid { ColumnSpacing = 8 };
      content.ColumnDefinitions.Add(new() { Width = new(18) }); content.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); content.ColumnDefinitions.Add(new() { Width = new(52) });
      content.Children.Add(new SessionTypeIcon { Glyph = session.TypeGlyph, Opacity = .55 });
      var title = new TextBlock { Text = session.Title, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
      title.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush"); Grid.SetColumn(title, 1); content.Children.Add(title);
      var action = new TextBlock { Text = reopeningSessions.Contains(session.Id) ? "Opening…" : "Reopen", FontSize = 11, Opacity = reopeningSessions.Contains(session.Id) ? 1 : 0, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
      action.SetResourceReference(TextBlock.ForegroundProperty, "AccentFillColorDefaultBrush"); Grid.SetColumn(action, 2); content.Children.Add(action);
      var open = new Button { Content = content, Height = 32, Padding = new(8, 0, 8, 0), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Style = (Style)Application.Current.Resources["DeckSidebarActionStyle"], IsEnabled = !reopeningSessions.Contains(session.Id), ContextFlyout = SessionMenu(session) };
      AutomationProperties.SetName(open, "Reopen " + session.Title); ToolTipService.SetToolTip(open, "This session could not reopen. Press to try its saved conversation again.");
      open.PointerEntered += (_, _) => action.Opacity = 1; open.PointerExited += (_, _) => action.Opacity = reopeningSessions.Contains(session.Id) ? 1 : 0;
      open.GotFocus += (_, _) => action.Opacity = 1; open.LostFocus += (_, _) => action.Opacity = 0;
      open.Click += async (_, _) => await ReopenSidebarSessionAsync(session); NotReopenedRows.Children.Add(open);
    }
  }
  private async Task ReopenSidebarSessionAsync(SessionDraft draft)
  {
    if (!reopeningSessions.Add(draft.Id)) return;
    UpdateSidebarSessions();
    try
    {
      var result = await Runtime.ReopenHeldSessionAsync(draft.Id);
      if (result.State == SessionState.Held) { Model.Notice = "This session's process is not answering yet. Its saved conversation is kept; try Reopen again."; return; }
      SyncSessions(); SelectSessionWindow(Model.Sessions.Single(s => s.Id == draft.Id)); Model.Notice = "Session reopened.";
    }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException) { Model.Notice = ex.Message; }
    finally { reopeningSessions.Remove(draft.Id); UpdateSidebarSessions(); }
  }
  private string? sidebarFooterIdentity;
  private void RefreshSidebarFooter()
  {
    var snapshot = Runtime.Cloud?.Snapshot;
    var signedIn = snapshot?.Phase is CloudPhase.SignedIn or CloudPhase.Paused or CloudPhase.NotAllowed;
    DevicesButton.Visibility = signedIn ? Visibility.Visible : Visibility.Collapsed;
    var name = signedIn ? DeckMenu.AccountName(CloudProfile.FromSnapshot(snapshot!).Name) : "";
    if (sidebarFooterIdentity == name) return; sidebarFooterIdentity = name;
    var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
    if (signedIn) content.Children.Add(new PersonPicture { DisplayName = name, Initials = CloudProfile.Initials(name), Width = 28, Height = 28 });
    else content.Children.Add(new DeckIcon { Glyph = "settings", FontSize = 16, VerticalAlignment = VerticalAlignment.Center });
    content.Children.Add(new TextBlock { Text = signedIn ? name : "Settings", FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 170 });
    SettingsRoute.Content = content; AutomationProperties.SetName(SettingsRoute, signedIn ? "Your profile: " + name : "Settings");
  }
}
