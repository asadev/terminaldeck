using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Cloud;
using TerminalDeck.App.Shell;
using Windows.System;

namespace TerminalDeck.App.Views.Settings;

public sealed class PersonalPage : UserControl
{
  private readonly CloudAccountClient account;
  private readonly StackPanel body = AccountPages.Body();
  private CloudProfile? read;
  private bool working;
  private string? problem;
  private string? savedField;
  private int savedRevision;

  public PersonalPage(CloudAccountClient account)
  {
    this.account = account;
    AutomationProperties.SetAutomationId(this, "settings.profile.personal");
    Content = AccountPages.Scroll(body);
    Loaded += async (_, _) => { if (AccountPages.SignedIn(account.Snapshot)) { read = await account.ProfileAsync(); Render(); } };
    Render();
  }

  private void Render()
  {
    body.Children.Clear();
    var profile = read ?? CloudProfile.FromSnapshot(account.Snapshot);
    var rows = new List<FrameworkElement> { SettingsPanel.SettingRow("Name", "", read is null ? SettingsPanel.StateText(profile.Name) : Field("name", profile.Name)) };
    if (read is not null || profile.Username is not null)
      rows.Add(SettingsPanel.SettingRow("Username", "", read?.UsernameCanChange == true ? Field("username", "@" + (profile.Username ?? "")) : SettingsPanel.StateText(profile.Username is null ? "" : "@" + profile.Username)));
    if (profile.Email is { } email)
    {
      var value = SettingsPanel.StateText(email); value.IsTextSelectionEnabled = true;
      rows.Add(SettingsPanel.SettingRow("E-mail", "", value));
    }
    body.Children.Add(SettingsPanel.GroupRows(rows));
    if (problem is not null) body.Children.Add(AccountPages.Problem(problem));
  }

  private async Task ClearCheckAsync(int revision)
  {
    await Task.Delay(1600);
    if (revision != savedRevision) return;
    savedField = null; Render();
  }

  private FrameworkElement Field(string kind, string current)
  {
    var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    if (savedField == kind) row.Children.Add(SettingsPanel.StateText("✓", "DeckProjectGreenBrush"));
    var field = new TextBox { Text = current, Width = 220, MinHeight = 24, Padding = new(6, 1, 6, 1), FontSize = 13, TextAlignment = TextAlignment.Right, CornerRadius = new(6), BorderThickness = new(0), MaxLength = kind == "name" ? 60 : 41, IsEnabled = !working };
    field.SetResourceReference(Control.BackgroundProperty, "DeckHoverBrush");
    AutomationProperties.SetAutomationId(field, "settings.profile.personal." + kind);
    AutomationProperties.SetName(field, kind == "name" ? "Your name" : "Your username");
    if (kind == "username") field.TextChanged += (_, _) => { if (!field.Text.StartsWith('@')) { var at = field.SelectionStart; field.Text = "@" + field.Text.TrimStart('@'); field.SelectionStart = at + 1; } };
    async Task SaveAsync()
    {
      var typed = field.Text.Trim();
      if (working || typed == current) return;
      working = true; problem = null; field.IsEnabled = false;
      try
      {
        var updated = kind == "name" ? await account.SaveProfileNameAsync(typed) : await account.SaveProfileUsernameAsync(typed);
        read = updated with { Addable = read?.Addable }; savedField = kind;
        _ = ClearCheckAsync(++savedRevision);
      }
      catch (Exception error) when (error is not OutOfMemoryException) { problem = error is CloudProfileRefusal refusal ? refusal.Words : "Could not save that change. Check your connection."; }
      finally { working = false; Render(); }
    }
    field.KeyDown += async (_, args) =>
    {
      if (args.Key == VirtualKey.Enter) { args.Handled = true; await SaveAsync(); }
      else if (args.Key == VirtualKey.Escape) { field.Text = current; args.Handled = true; }
    };
    field.LostFocus += async (_, _) => await SaveAsync();
    row.Children.Add(field);
    return row;
  }
}
