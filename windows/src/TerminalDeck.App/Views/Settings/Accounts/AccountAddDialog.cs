using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using TerminalDeck.Core.Accounts;

namespace TerminalDeck.App.Views;

// Add account (Mac: NativeCodingAIAddAccount): which AI, Connection = Sign in
// (subscription) or API key, a name; a subscription then opens its sign-in at once.
public sealed partial class SettingsPane
{
  internal ContentDialog? AddAccountDialogForProof { get; private set; }
  internal async Task ShowAddAccountAsync() => await ShowAddAccountAsync("claude");
  internal async Task ShowAddAccountAsync(string initialProvider)
  {
    var providers = CodingAis;
    var provider = new ComboBox { Header = "Which AI is this account for?", ItemsSource = providers.Select(AccountMcp.AgentName).ToArray(), SelectedIndex = Math.Max(0, Array.IndexOf(providers, initialProvider)), HorizontalAlignment = HorizontalAlignment.Stretch };
    var connection = new ComboBox { Header = "Connection", ItemsSource = new[] { "Sign in (subscription)", "API key" }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    var name = new TextBox { Header = "Account name", MaxLength = 80, PlaceholderText = "Work, Personal, Team…" };
    var note = Description("");
    var error = new Notices.CompactNotice { Severity = InfoBarSeverity.Error, AutoDismiss = false };
    var stack = new StackPanel { Spacing = 16 };
    foreach (var control in new UIElement[] { provider, connection, name, note, error }) stack.Children.Add(control);
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Add account", Content = stack, PrimaryButtonText = "Sign in", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary, IsPrimaryButtonEnabled = false };
    AutomationProperties.SetAutomationId(dialog, "accounts.add.dialog");
    AutomationProperties.SetAutomationId(provider, "accounts.add.provider");
    AutomationProperties.SetAutomationId(connection, "accounts.add.connection");
    AutomationProperties.SetAutomationId(name, "accounts.add.name");
    AutomationProperties.SetAutomationId(error, "accounts.add.outcome");
    void Update()
    {
      var ai = providers[Math.Max(0, provider.SelectedIndex)]; var api = connection.SelectedIndex == 1;
      dialog.PrimaryButtonText = api ? "Next" : "Sign in";
      note.Text = api ? "Next asks for the key. It is kept in Windows Credential Manager, never in a file."
        : "Sign in opens " + AccountMcp.AgentName(ai) + "’s own sign-in in your browser. This account keeps its own login folder, so several accounts for the same AI work side by side.";
      if (string.IsNullOrWhiteSpace(name.Text) || name.Text == AutoName) name.Text = AutoName = NextName(ai, api);
      dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(name.Text);
    }
    provider.SelectionChanged += (_, _) => Update(); connection.SelectionChanged += (_, _) => Update();
    name.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(name.Text) && !name.Text.Any(char.IsControl);
    AccountProfile? created = null; var wantsApi = false; var adding = false;
    dialog.PrimaryButtonClick += async (_, args) =>
    {
      if (adding) { args.Cancel = true; return; }
      adding = true; dialog.IsPrimaryButtonEnabled = false;
      var deferral = args.GetDeferral();
      try
      {
        wantsApi = connection.SelectedIndex == 1;
        if (!wantsApi) created = await runtime.Accounts.CreateAsync(providers[provider.SelectedIndex], name.Text);
      }
      catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException) { args.Cancel = true; error.Text = "The account could not be added. Choose a short account name and try again."; }
      finally { adding = false; dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(name.Text); deferral.Complete(); }
    };
    AutoName = ""; Update();
    AddAccountDialogForProof = dialog;
    ContentDialogResult result;
    try { result = await dialog.ShowAsync(); }
    finally { AddAccountDialogForProof = null; }
    if (result != ContentDialogResult.Primary) return;
    if (wantsApi) { await ShowApiAccountAsync(providers[provider.SelectedIndex], null, name.Text.Trim()); return; }
    await RenderAsync();
    if (created is not null) await SignInAccountAsync(created.Id);
  }
  private string AutoName = "";
  private string NextName(string provider, bool api)
  {
    var stem = AccountMcp.AgentName(provider) + (api ? " API" : "");
    var taken = runtime.Accounts.List(provider).Select(a => a.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
    if (!taken.Contains(stem)) return stem;
    for (var n = 2; ; n++) if (!taken.Contains(stem + " " + n)) return stem + " " + n;
  }

  // Add or edit an API-key account: connection type, masked key, Base URL,
  // Workspace ID (Claude) and an optional model. An empty key keeps the saved one.
  internal async Task ShowApiAccountAsync(string providerId, string? accountId, string? newName = null)
  {
    var existing = accountId is null ? null : runtime.ApiAccounts.Read(accountId);
    var kinds = ApiKinds.For(providerId);
    var kind = new ComboBox { Header = "Connection type", ItemsSource = kinds.Select(k => k.Name).ToArray(), SelectedIndex = Math.Max(0, kinds.ToList().FindIndex(k => k.Kind == existing?.Kind)), HorizontalAlignment = HorizontalAlignment.Stretch };
    var key = new PasswordBox { Header = existing?.CredentialReference is not null ? "Key · leave empty to keep the saved key" : "Key", PlaceholderText = existing?.CredentialReference is not null ? "Saved" : "Paste the key" };
    var baseUrl = new TextBox { Header = "Base URL · optional", Text = existing?.BaseUrl ?? "", PlaceholderText = providerId == "codex" ? "https://… or http://localhost:…/v1" : "https://…" };
    var workspace = new TextBox { Header = "Workspace ID · optional", Text = existing?.WorkspaceId ?? "", Visibility = providerId == "claude" ? Visibility.Visible : Visibility.Collapsed };
    var modelBox = new TextBox { Header = "Model · optional", Text = existing?.Model ?? "", PlaceholderText = ModelCatalog.Top(providerId)?.Id ?? "" };
    var error = new Notices.CompactNotice { Severity = InfoBarSeverity.Error, AutoDismiss = false };
    var form = new StackPanel { Spacing = 14 };
    foreach (var control in new UIElement[] { Description("For " + AccountMcp.AgentName(providerId) + ". The key is stored in Windows Credential Manager and only given to this account’s own sessions."), kind, key, baseUrl, workspace, modelBox, error }) form.Children.Add(control);
    void Update()
    {
      var chosen = kinds[Math.Max(0, kind.SelectedIndex)].Kind;
      key.Visibility = chosen == ApiKinds.CompatibleLocal ? Visibility.Collapsed : Visibility.Visible;
      baseUrl.Header = chosen is ApiKinds.Compatible or ApiKinds.CompatibleLocal ? "Base URL" : "Base URL · optional";
    }
    kind.SelectionChanged += (_, _) => Update(); Update();
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = accountId is null ? "Add API account" : "Edit API connection and key", Content = new ScrollViewer { Content = form, MaxHeight = 480 },
      PrimaryButtonText = accountId is null ? "Add account" : "Save", SecondaryButtonText = "Save and check key", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
    AutomationProperties.SetAutomationId(dialog, "accounts.api.dialog");
    AutomationProperties.SetAutomationId(kind, "accounts.api.kind");
    AutomationProperties.SetAutomationId(key, "accounts.api.key");
    AutomationProperties.SetAutomationId(baseUrl, "accounts.api.baseUrl");
    AutomationProperties.SetAutomationId(workspace, "accounts.api.workspace");
    AutomationProperties.SetAutomationId(modelBox, "accounts.api.model");
    AutomationProperties.SetAutomationId(error, "accounts.api.outcome");
    var check = false;
    var savedAny = false;
    var submitting = false;
    async Task SaveAsync()
    {
      var draft = new ApiAccountDraft(kinds[Math.Max(0, kind.SelectedIndex)].Kind, baseUrl.Text, workspace.Text, modelBox.Text);
      var secret = key.Visibility == Visibility.Visible ? key.Password : null;
      var saved = accountId is null ? await runtime.ApiAccounts.AddAsync(providerId, newName ?? NextName(providerId, true), draft, secret)
        : await runtime.ApiAccounts.UpdateAsync(accountId, draft, secret);
      accountId = saved.Id; key.Password = ""; savedAny = true;
      dialog.Title = "Edit API connection and key"; dialog.PrimaryButtonText = "Save";
      if (check)
      {
        var checkedConnection = await runtime.ApiAccounts.CheckAsync(saved.Id);
        error.Severity = checkedConnection.CheckState == "valid" ? InfoBarSeverity.Success : checkedConnection.CheckState == "unavailable" ? InfoBarSeverity.Warning : InfoBarSeverity.Error;
        error.Text = ApiAccountOutcome(checkedConnection.CheckState);
      }
    }
    async void Submit(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
      if (submitting) { args.Cancel = true; return; }
      var deferral = args.GetDeferral();
      args.Cancel = check;
      submitting = true; dialog.IsPrimaryButtonEnabled = false; dialog.IsSecondaryButtonEnabled = false;
      error.Severity = InfoBarSeverity.Informational; error.Text = check ? "Saving and checking…" : "Saving…";
      try { await SaveAsync(); }
      catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException)
      {
        args.Cancel = true; error.Severity = InfoBarSeverity.Error;
        // Provider errors can echo the submitted key or endpoint. Use only our own words.
        error.Text = savedAny ? "Saved. The key check could not finish. Try checking again." : "Couldn’t save this connection. Check the fields and try again.";
      }
      finally { submitting = false; dialog.IsPrimaryButtonEnabled = true; dialog.IsSecondaryButtonEnabled = true; if (savedAny) dialog.CloseButtonText = "Done"; deferral.Complete(); }
    }
    dialog.PrimaryButtonClick += (s, a) => { check = false; Submit(s, a); };
    dialog.SecondaryButtonClick += (s, a) => { check = true; Submit(s, a); };
    var dialogResult = await dialog.ShowAsync();
    if (savedAny || dialogResult is ContentDialogResult.Primary or ContentDialogResult.Secondary) await RenderAsync();
  }
  internal static string ApiAccountOutcome(string? state) => state switch
  {
    "valid" => "Saved. Key checked successfully.",
    "invalid" => "Saved. The key is invalid. Edit it and check again.",
    "no-access" => "Saved. This key does not have access. Check its permissions or use another key.",
    "needs-key" => "Saved. The key is missing. Enter a key and check again.",
    "unreadable" => "Windows could not open the saved key. Enter the key again and check it.",
    "unavailable" => "Saved. The key could not be checked. Try again when the service is available.",
    _ => "Saved. The key has not been checked."
  };
}
