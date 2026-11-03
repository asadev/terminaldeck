using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private readonly HashSet<string> deletingSessions = [];
  private MenuFlyout SessionMenu(SessionDraft row)
  {
    var menu = new MenuFlyout();
    void Add(string label, Func<Task> action, bool enabled = true)
    {
      var item = new MenuFlyoutItem { Text = label, IsEnabled = enabled };
      item.Click += async (_, _) => { try { await action(); } catch (Exception ex) when (ex is not OutOfMemoryException) { Model.Notice = ex is ArgumentException or InvalidOperationException ? ex.Message : "The session action could not finish. Try again."; } }; menu.Items.Add(item);
    }
    Add(sidebar.Read.SessionPins.Contains(row.Id) ? "Unpin" : "Pin", () => { sidebar.PinSession(row.Id, !sidebar.Read.SessionPins.Contains(row.Id)); return Task.CompletedTask; });
    Add("Open in new window", () => { PopSession(row.Id); return Task.CompletedTask; });
    if (windowState.Tabs.Any(t => t.Owner == row.Id && t.Host != "main")) Add("Move back to main window", () => { DockOwner(row.Id); return Task.CompletedTask; });
    if (!string.Equals(row.Provider, "shell", StringComparison.OrdinalIgnoreCase))
      Add("Account…", async () => { var tab = windowState.Tabs.FirstOrDefault(t => t.Subject == row.Id); await ShowAccountAsync(row, tab?.Host is { } host && host != "main" ? detached[host].Root : Root); });
    var splits = new MenuFlyoutSubItem { Text = "Split view" };
    var currentTab = windowState.Tabs.FirstOrDefault(t => t.Id == row.Id);
    if (currentTab is not null)
    {
      var owner = currentTab.Host == "main" ? Scope : detached[currentTab.Host].Owner;
      foreach (var other in windowState.Tabs.Where(t => t.Id != row.Id && t.Host == currentTab.Host && t.Kind != "page"))
      {
        var item = new MenuFlyoutItem { Text = "Beside " + other.Title };
        item.Click += (_, _) => { var layoutOwner = ManualLayoutOwner(currentTab); windowState.Split(row.Id, other.Id, owner: layoutOwner, host: currentTab.Host); FocusWindow(layoutOwner, other.Id); (currentTab.Host == "main" ? mainSurface : detached[currentTab.Host].Surface).FocusInput(other.Id); }; splits.Items.Add(item);
      }
      foreach (var vertical in new[] { false, true })
      {
        var item = new MenuFlyoutItem { Text = vertical ? "Empty pane below" : "Empty pane beside" };
        item.Click += (_, _) => { var layoutOwner = ManualLayoutOwner(currentTab); windowState.EmptySplit(row.Id, vertical, layoutOwner, currentTab.Host); FocusWindow(layoutOwner, row.Id); }; splits.Items.Add(item);
      }
      var one = new MenuFlyoutItem { Text = "One pane" }; one.Click += (_, _) => windowState.One(row.Id, ManualLayoutOwner(currentTab), currentTab.Host); splits.Items.Add(one);
      var restore = new MenuFlyoutItem { Text = "Restore split" }; restore.Click += (_, _) => windowState.RestoreSplit(ManualLayoutOwner(currentTab), currentTab.Host); splits.Items.Add(restore);
      menu.Items.Add(splits);
    }
    if (row.Presentation == SessionPresentation.Chat)
      Add(sidebar.IsArchived(row.Id) ? "Restore to sidebar" : "Archive in sidebar", () => { ArchiveSidebarChat(row.Id, !sidebar.IsArchived(row.Id)); return Task.CompletedTask; }, row.State is not ("working" or "sending"));
    Add("Rename…", async () => { EnsureSessionTab(row); await RenameWindowAsync(row.Id); });
    var binding = new MenuFlyoutSubItem { Text = "Attach browser" };
    foreach (var page in browser.Core.Read().Tabs)
    {
      var attached = page.SessionId == row.Id;
      var item = new MenuFlyoutItem { Text = (attached ? "✓ " : "") + (page.SessionSlot ?? page.Window) + " · " + page.Title };
      item.Click += async (_, _) =>
      {
        try { await browser.Core.AttachAsync(page.Id, attached ? null : row.Id); browser.ObserveShellPages(); SyncWindows(); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { Model.Notice = "This browser could not be attached. Try again."; }
      };
      binding.Items.Add(item);
    }
    var create = new MenuFlyoutItem { Text = "New attached window" };
    create.Click += async (_, _) => { try { await CreateWindowAsync(row.Id, "browser"); } catch (Exception ex) when (ex is not OutOfMemoryException) { Model.Notice = "The attached browser could not open."; } };
    binding.Items.Add(create); menu.Items.Add(binding);
    if (row.IsLive && row.State is not ("ended" or "exited" or "held")) Add("Stop", () => StopSessionAsync(row));
    menu.Items.Add(new MenuFlyoutSeparator()); Add("Delete", () => DeleteSessionAsync(row));
    return menu;
  }
  private void ArchiveSidebarChat(string id, bool archived)
  {
    var row = Model.Sessions.FirstOrDefault(s => s.Id == id);
    if (row?.Presentation != SessionPresentation.Chat) throw new ArgumentException("Choose a Chat session.");
    if (archived && (Runtime.Chats.Get(id).Busy || row.State is "working" or "sending")) throw new InvalidOperationException("Wait for this answer before archiving its chat.");
    sidebar.ArchiveChat(id, archived);
  }
  private void EnsureSessionTab(SessionDraft row)
  {
    windowState.Reveal(row.Id);
    windowState.Ensure(row.Id, windowState.OwnerOf(row.Id), row.Id, row.Presentation == SessionPresentation.Chat ? "chat" : "terminal", row.Title);
  }
  private async Task SaveWindowTitleAsync(WorkspaceTab tab, string title)
  {
    if (tab.Kind == "page") throw new ArgumentException("This page keeps its name.");
    title = title.Trim();
    if (title.Length is < 1 or > 40 || title.Any(char.IsControl)) throw new ArgumentException("Use a name of 1–40 characters on one line.");
    if (Runtime.Sessions.Any(s => s.Definition.Id == tab.Subject))
    {
      var result = await Runtime.Keeper.RenameAsync(tab.Subject, title);
      if (result.Error is not null) throw new InvalidOperationException(result.Error);
    }
    else if (Runtime.Chats.List().Any(chat => chat.Definition.Id == tab.Subject)) await Runtime.Chats.RenameAsync(tab.Subject, title);
    if (tab.Kind != "browser") await Runtime.RefreshSessionsAsync();
    windowState.Rename(tab.Id, title);
    Model.Sessions.FirstOrDefault(s => s.Id == tab.Subject)?.Rename(title);
  }
  private async Task DeleteSessionAsync(SessionDraft row)
  {
    if (!deletingSessions.Add(row.Id)) return;
    try
    {
      var attached = browser.Core.Read().Tabs.Where(page => page.SessionId == row.Id).ToArray();
      var live = row.IsLive && row.State is not ("ended" or "exited");
      if (live && sidebar.Read.ConfirmDelete)
      {
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock { Text = "This session is still open. Deleting it stops its process and removes it from the sidebar. Saved conversation history and project files stay on disk.", TextWrapping = TextWrapping.Wrap, MaxWidth = 440 });
        if (attached.Length > 0)
        {
          var names = attached.Select(page => page.SessionSlot ?? page.Window).ToArray();
          var named = names.Length == 1 ? names[0] : string.Join(", ", names[..^1]) + " and " + names[^1];
          content.Children.Add(new TextBlock { Text = named + (names.Length == 1 ? " stays open, detached." : " stay open, detached."), TextWrapping = TextWrapping.Wrap, Opacity = 0.7 });
        }
        var remember = new CheckBox { Content = "Don’t ask again" }; content.Children.Add(remember);
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, RequestedTheme = Root.ActualTheme, Title = "Delete this session?", Content = content, PrimaryButtonText = "Delete", CloseButtonText = "Keep it open", DefaultButton = ContentDialogButton.Close };
        if (await ShowShellDialogAsync(dialog) != ContentDialogResult.Primary) return;
        if (remember.IsChecked == true) sidebar.AskBeforeDelete(false);
      }
      Model.Notice = "Deleting session…";
      if (row.IsLive)
      {
        if (row.Presentation == SessionPresentation.Chat) await Runtime.Chats.EndAsync(row.Id);
        else if (live) await Runtime.StopAsync(row.Id);
      }
      foreach (var page in attached) await browser.Core.AttachAsync(page.Id, null);
      browser.ObserveShellPages();
      sidebar.HideSession(row.Id, true); hiddenTabs.Add(row.Id);
      if (windowState.Tabs.Any(t => t.Id == row.Id)) windowState.Close(row.Id);
      Model.CloseDraft(row); SyncSessions(); Model.Notice = "";
    }
    finally { deletingSessions.Remove(row.Id); }
  }
  private void SessionActions_Click(object sender, RoutedEventArgs args)
  {
    if (sender is Button { DataContext: SessionDraft row } button) SessionMenu(row).ShowAt(button);
  }
}
