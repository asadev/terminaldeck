using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Accounts;

namespace TerminalDeck.App.Views;

public sealed partial class SettingsPane
{
  private async Task RefreshCodingAccountsAsync()
  {
    installations.Clear();
    var problems = new List<string>();
    foreach (var saved in runtime.Accounts.List())
    {
      try
      {
        var account = await runtime.Accounts.RefreshAsync(saved.Id);
        if (account.SignedIn) await runtime.Accounts.ModelsAsync(account.Id, allowCached: false);
      }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException)
      { problems.Add(saved.Name + ": status or model list could not be checked. Try Refresh again."); }
    }
    if (problems.Count > 0) throw new InvalidOperationException(string.Join("\n", problems));
  }
  internal async Task ShowAccountModelsAsync(string accountId)
  {
    var account = runtime.Accounts.Get(accountId);
    var content = new StackPanel { Spacing = 12 };
    try
    {
      var list = await runtime.Accounts.ModelsAsync(accountId);
      content.Children.Add(Description((list.Cached ? "Saved model list · " : "Live model list · ") + list.CheckedAt.ToLocalTime().ToString("g")));
      foreach (var row in list.Models)
        content.Children.Add(Description(row.Name + " · " + row.Id + (row.SupportsOneMillion ? " · 1M context" : row.ContextTokens > 0 ? " · " + row.ContextTokens.ToString("N0") + " tokens" : " · context size not reported")));
      content.Children.Add(Description("The CLI reports these choices. A successful reply after sign-in will confirm access."));
    }
    catch (SignInRequiredException ex) { content.Children.Add(Description(ex.Message)); }
    catch (IOException) { content.Children.Add(Description("This AI could not report its model list. Check sign-in, update its CLI if needed, then refresh.")); }
    await new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = account.Name + " models", Content = new ScrollViewer { Content = content, MaxHeight = 440 }, CloseButtonText = "Done" }.ShowAsync();
  }
  internal async Task ShowSignInReadinessAsync()
  {
    var report = SignInReadiness.Read(runtime.Accounts.List());
    var content = new StackPanel { Spacing = 16 };
    content.Children.Add(Description("Checked " + report.CheckedAt.ToLocalTime().ToString("g") + ". " + report.Note));
    foreach (var provider in report.Providers)
    {
      content.Children.Add(new TextBlock { Text = provider.Name + " · " + provider.SignedIn + "/" + provider.Accounts + " accounts signed in", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
      foreach (var check in provider.Checks) content.Children.Add(Description(check.Description + "\n" + check.State));
    }
    await new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "SIGN-IN READINESS CHECK", Content = new ScrollViewer { Content = content, MaxHeight = 440 }, CloseButtonText = "Done" }.ShowAsync();
  }
}
