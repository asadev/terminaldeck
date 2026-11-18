using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Cloud;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views.Settings;

public sealed class SignInPage : UserControl
{
  private readonly CloudAccountClient account;
  private readonly StackPanel body = AccountPages.Body();
  private readonly Dictionary<string, CancellationTokenSource> pending = new(StringComparer.Ordinal);
  private readonly HashSet<string> sending = new(StringComparer.Ordinal);
  private CloudProfile? read;
  private bool working;
  private string? problem;

  public SignInPage(CloudAccountClient account)
  {
    this.account = account;
    AutomationProperties.SetAutomationId(this, "settings.profile.signIn");
    Content = AccountPages.Scroll(body);
    Loaded += async (_, _) => { if (AccountPages.SignedIn(account.Snapshot)) { read = await account.ProfileAsync(); Render(); } };
    Render();
  }

  private void Render()
  {
    body.Children.Clear();
    if (!AccountPages.SignedIn(account.Snapshot)) return;
    var profile = read ?? CloudProfile.FromSnapshot(account.Snapshot);
    var rows = new List<FrameworkElement>();
    foreach (var way in profile.Ways)
    {
      var waiting = way.Id is { } id && pending.ContainsKey(id);
      FrameworkElement control = SettingsPanel.StateText("Connected");
      if (waiting || way.CanRemove && way.Id is not null && profile.Ways.Count > 1)
      {
        var button = new Button { Content = waiting ? "Undo" : "Disconnect", MinHeight = 28, Padding = new(10, 2, 10, 2), IsEnabled = !working && !sending.Contains(way.Id!) };
        AutomationProperties.SetAutomationId(button, waiting ? "settings.profile.signIn.undo" : "settings.profile.signIn.disconnect");
        AutomationProperties.SetName(button, (waiting ? "Undo disconnecting " : "Disconnect ") + way.ProviderName);
        button.Click += (_, _) =>
        {
          if (way.Id is null) return;
          if (pending.Remove(way.Id, out var cancel)) { cancel.Cancel(); Render(); }
          else { var token = new CancellationTokenSource(); pending[way.Id] = token; Render(); _ = DisconnectAsync(way.Id, token); }
        };
        control = button;
      }
      rows.Add(WayRow(way.ProviderName, waiting ? "Disconnecting…" : way.Account, control));
    }
    foreach (var provider in (profile.Addable ?? []).Where(p => !profile.Ways.Any(w => w.Provider == p)))
    {
      var connect = new Button { Content = "Connect", MinHeight = 28, Padding = new(10, 2, 10, 2), IsEnabled = !working };
      AutomationProperties.SetAutomationId(connect, "settings.profile.signIn.connect");
      AutomationProperties.SetName(connect, "Connect " + CloudProfile.ProviderName(provider));
      connect.Click += async (_, _) =>
      {
        try { await account.ConnectSignInWayAsync(); }
        catch (Exception error) when (error is not OutOfMemoryException) { problem = "Could not open sign-in. Try again."; Render(); }
      };
      rows.Add(WayRow(CloudProfile.ProviderName(provider), "", connect));
    }
    if (rows.Count > 0) body.Children.Add(SettingsPanel.GroupRows(rows));
    var signOut = AccountPages.RedButton(CloudPageText.SignOut); signOut.IsEnabled = !working;
    AutomationProperties.SetAutomationId(signOut, "settings.profile.signOut");
    signOut.Click += async (_, _) =>
    {
      if (working || !await AccountPages.ConfirmSignOutAsync(this)) return;
      working = true; problem = null; Render();
      try { await account.SignOutAsync(); }
      catch (Exception error) when (error is not OutOfMemoryException) { problem = "Could not sign out. Try again."; }
      finally { working = false; Render(); }
    };
    body.Children.Add(SettingsPanel.GroupRows([SettingsPanel.SettingRow("", "", signOut)]));
    if (problem is not null) body.Children.Add(AccountPages.Problem(problem));
  }

  private static FrameworkElement WayRow(string name, string detail, FrameworkElement control)
  {
    var row = new Grid { ColumnSpacing = 12, MinHeight = 44, Padding = new(12, 6, 12, 6) };
    row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    row.Children.Add(SettingsPanel.IconTile(name == "GitHub" ? "" : name == "E-mail" ? "" : "", "DeckProjectGraphiteBrush"));
    var words = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
    words.Children.Add(new TextBlock { Text = name, FontSize = 13 });
    if (detail.Length > 0) { var line = SettingsPanel.StateText(detail); line.FontSize = 11; words.Children.Add(line); }
    Grid.SetColumn(words, 1); row.Children.Add(words); Grid.SetColumn(control, 2); row.Children.Add(control);
    return row;
  }

  private async Task DisconnectAsync(string id, CancellationTokenSource cancel)
  {
    try
    {
      await Task.Delay(TimeSpan.FromSeconds(5), cancel.Token);
      sending.Add(id); Render();
      var updated = await account.DisconnectSignInWayAsync(id);
      read = updated with { Addable = read?.Addable };
    }
    catch (OperationCanceledException) { }
    catch (Exception error) when (error is not OutOfMemoryException) { problem = error is CloudProfileRefusal refusal ? refusal.Words : "Could not disconnect that sign-in. Try again."; }
    finally { if (pending.GetValueOrDefault(id) == cancel) pending.Remove(id); sending.Remove(id); cancel.Dispose(); Render(); }
  }
}
