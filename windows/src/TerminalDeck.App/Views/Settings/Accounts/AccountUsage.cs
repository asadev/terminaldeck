using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Usage;

namespace TerminalDeck.App.Views;

public sealed partial class SettingsPane
{
  private async Task ShowAccountUsageAsync(string accountId)
  {
    var account = runtime.Accounts.Get(accountId);
    var body = new StackPanel { Spacing = 12 };
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = account.Name + " usage", Content = body, CloseButtonText = "Done", SecondaryButtonText = "Check again" };
    var open = true;
    async Task ReadAsync(bool refresh)
    {
      body.Children.Clear(); body.Children.Add(Description("Reading usage…"));
      try
      {
        var session = runtime.Sessions.FirstOrDefault(s => s.Definition.AccountId == accountId && s.State != TerminalDeck.Core.Sessions.SessionState.Exited)?.Definition.Id
          ?? runtime.Chats?.List().FirstOrDefault(c => c.Definition.AccountId == accountId && !c.Ended)?.Definition.Id;
        if (refresh && session is not null) await runtime.Usage.RefreshAsync(session, true);
        var report = await Task.Run(() => runtime.Usage.Read(session));
        if (!open) return;
        body.Children.Clear();
        var rows = report.Readings.Where(r => r.Account.Id == accountId).ToArray();
        if (rows.Length == 0)
          body.Children.Add(Description(account.Authentication == AccountAuthentication.ApiKey ? UsageService.ApiUsageNote : account.Provider == "gemini"
            ? "Gemini does not report subscription limits here." : "No usage numbers have been reported for this account yet. Open a session with it, then check again."));
        foreach (var reading in rows)
        {
          var shown = UsageReadout.Of(reading, UsageFormat.Now());
          body.Children.Add(Description(reading.Label + " · " + shown.Value));
          if (shown.Facts.Length > 0) body.Children.Add(Description(shown.Facts));
        }
      }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or UnauthorizedAccessException)
      { if (open) { body.Children.Clear(); body.Children.Add(Description("Usage could not be read. Your account is kept. Check again.")); } }
    }
    dialog.Opened += async (_, _) => await ReadAsync(false);
    dialog.SecondaryButtonClick += async (_, args) =>
    {
      args.Cancel = true; var deferral = args.GetDeferral(); dialog.IsSecondaryButtonEnabled = false;
      try { await ReadAsync(true); }
      finally { dialog.IsSecondaryButtonEnabled = true; deferral.Complete(); }
    };
    try { await dialog.ShowAsync(); }
    finally { open = false; }
  }
}
