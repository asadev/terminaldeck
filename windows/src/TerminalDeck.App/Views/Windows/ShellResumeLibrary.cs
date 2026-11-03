using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private Expander ProviderResumeLibrary(string? initialFolder, McpCallContext? caller, Func<Func<Task<string>>, Task> select)
  {
    var body = new StackPanel { Spacing = 10 }; var accounts = new ComboBox { Header = "Coding AI account", HorizontalAlignment = HorizontalAlignment.Stretch };
    foreach (var account in Runtime.Accounts.List().Where(a => a.SignedIn && (caller is null || caller.Has("accounts", a.Id)))) accounts.Items.Add(new ComboBoxItem { Content = account.Provider + " · " + (account.Email ?? account.Name), Tag = account.Id });
    if (accounts.Items.Count > 0) accounts.SelectedIndex = 0;
    var folder = new TextBox { Header = "Conversation folder", Text = initialFolder ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) };
    var locator = new TextBox { Header = "Conversation ID or transcript path" }; var notice = new TextBlock { Text = "Reads the selected account's real provider history. Preview is read only. Continue opens that exact saved conversation and sends no message.", TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = .7 };
    var preview = new TextBox { Header = "Transcript preview", IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 80, MaxHeight = 260 };
    var rows = new StackPanel { Spacing = 8 }; var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; var busy = false;
    var files = new ConversationFiles(dataRoot);
    SessionDefinition Scope()
    {
      if (accounts.SelectedItem is not ComboBoxItem { Tag: string accountId }) throw new InvalidOperationException("Sign in to a coding AI account first.");
      var account = Runtime.Accounts.Get(accountId); var cwd = Path.GetFullPath(folder.Text);
      if (!Directory.Exists(cwd)) throw new InvalidOperationException("Choose the folder this conversation belongs to.");
      if (caller is not null) { caller.Require("accounts", account.Id); caller.Require("folders", cwd); }
      return new(Guid.NewGuid().ToString(), account.Provider, cwd, "Saved conversation", account.Id, account.HomeId);
    }
    async Task ActAsync(Func<Task> action)
    {
      if (busy) return; busy = true; actions.IsHitTestVisible = false; notice.Text = "Reading provider history…";
      try { if (caller is not null) await caller.EnsureCurrentAsync(CancellationToken.None); await action(); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { notice.Text = ex.Message; }
      finally { busy = false; actions.IsHitTestVisible = true; }
    }
    async Task LoadPreviewAsync()
    {
      var scope = Scope(); var query = locator.Text; var text = await Task.Run(() => files.PreviewLibrary(scope, files.ResolveLibraryIdentity(scope, query)));
      if (caller is not null) await caller.EnsureCurrentAsync(CancellationToken.None); preview.Text = text; notice.Text = "Read-only preview. The original file has not changed.";
    }
    var list = new Button { Content = "Find provider conversations", IsEnabled = accounts.Items.Count > 0 };
    list.Click += async (_, _) => await ActAsync(async () =>
    {
      var scope = Scope(); var conversations = await Task.Run(() => files.ListLibrary(scope)); if (caller is not null) await caller.EnsureCurrentAsync(CancellationToken.None);
      rows.Children.Clear();
      foreach (var conversation in conversations)
      {
        var pick = new Button { Content = conversation.Id + " · " + conversation.ModifiedAt.ToLocalTime().ToString("g"), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
        ToolTipService.SetToolTip(pick, conversation.Path); pick.Click += async (_, _) => { locator.Text = conversation.Id; await ActAsync(LoadPreviewAsync); }; rows.Children.Add(pick);
      }
      notice.Text = conversations.Count == 0 ? "No provider transcript with this exact folder identity was found. You can load an exact conversation ID or account-history transcript path." : "Found " + conversations.Count + " provider conversations. Choose one to preview it.";
    });
    var load = new Button { Content = "Load preview", IsEnabled = accounts.Items.Count > 0 }; load.Click += async (_, _) => await ActAsync(LoadPreviewAsync);
    var resume = new Button { Content = "Continue saved conversation", IsEnabled = accounts.Items.Count > 0 };
    resume.Click += async (_, _) => await ActAsync(() => select(async () =>
    {
      var scope = Scope(); var requested = locator.Text; var id = await Task.Run(() => files.ResolveLibraryIdentity(scope, requested));
      if (caller is not null) await caller.EnsureCurrentAsync(CancellationToken.None);
      var definition = new ChatDefinition(scope.Id, scope.Provider, scope.Cwd, "Saved " + scope.Provider + " conversation", scope.AccountId!, scope.AccountHome!, new(), PermissionMode: Runtime.General.NewChatPermission(scope.Provider));
      var chat = await Runtime.Chats.CreateAsync(definition, id); caller?.NoteSessionStarted(chat.Definition.Id); return chat.Definition.Id;
    }));
    actions.Children.Add(list); actions.Children.Add(load); actions.Children.Add(resume);
    foreach (var child in new UIElement[] { accounts, folder, locator, notice, new ScrollViewer { Content = actions, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled }, rows, preview }) body.Children.Add(child);
    accounts.SelectionChanged += (_, _) => { rows.Children.Clear(); preview.Text = ""; locator.Text = ""; };
    return new Expander { Header = "Provider transcript history", Content = body, HorizontalAlignment = HorizontalAlignment.Stretch };
  }
}
