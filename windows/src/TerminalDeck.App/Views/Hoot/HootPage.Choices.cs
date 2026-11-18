using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views.Hoot;

public sealed partial class HootPage
{
  private async Task<HootSettings?> ReadyChoicesAsync()
  {
    if (Model.State.Settings is null) await Model.ReadyAsync();
    if (Model.State.Settings is null) await ShowSettingsAsync();
    return Model.State.Settings;
  }

  private async Task ShowAccountChoicesAsync()
  {
    var current = await ReadyChoicesAsync();
    if (current is null) return;
    var menu = new MenuFlyout();
    if (accounts().FirstOrDefault(a => a.Id == current.AccountId)?.Authentication == AccountAuthentication.ApiKey && EditApiAccount is { } edit)
      AddMenu(menu, "Edit this account’s API key…", () => edit(current.AccountId));
    foreach (var group in accounts().Where(a => a.SignedIn).GroupBy(a => a.Provider))
    {
      var section = new MenuFlyoutSubItem { Text = TerminalDeck.Core.Agents.AgentSeats.ProviderName(group.Key) };
      foreach (var account in group.OrderBy(a => a.Name))
      {
        var item = new ToggleMenuFlyoutItem { Text = account.Name, IsChecked = account.Id == current.AccountId };
        item.Click += async (_, _) =>
        {
          if (Model.State.Settings != current || account.Id == current.AccountId) return;
          if (account.Provider != current.Provider && await Dialog("Change Hoot's coding AI?", Words("The earlier conversation stays visible. The next message opens a connection with the selected AI."), "Change AI").ShowAsync() != ContentDialogResult.Primary) return;
          await Model.RunAsync(async () =>
          {
            var offered = await Model.ModelsAsync(account.Id);
            if (Model.State.Settings != current) return;
            var model = offered.FirstOrDefault(m => m.Id == current.Options.Model);
            if (account.Provider == current.Provider && current.Options.Model.Length > 0 && model is null)
              throw new InvalidOperationException("Hoot's current model is not offered by this account. Open Hoot settings to choose the account and model together.");
            model ??= offered.FirstOrDefault(m => m.Id == ModelCatalog.Top(account.Provider)?.Id) ?? offered.FirstOrDefault();
            if (model is null) throw new InvalidOperationException("This account did not report any models. Check it in Coding AIs.");
            var efforts = ModelEfforts.For(account.Provider, model);
            if (account.Provider == current.Provider && current.Options.Effort is { Length: > 0 } and not "auto" && !efforts.Contains(current.Options.Effort))
              throw new InvalidOperationException("Hoot's current effort is not offered by this account. Open Hoot settings to choose its model and effort together.");
            var effort = account.Provider == current.Provider ? current.Options.Effort : efforts.Contains(current.Options.Effort ?? "") ? current.Options.Effort : efforts.Contains(ModelCatalog.TopEffort(account.Provider) ?? "") ? ModelCatalog.TopEffort(account.Provider) : efforts.LastOrDefault();
            var modes = TerminalDeck.Core.Chats.ChatPermissionModes.Supported(account.Provider);
            var mode = modes.Contains(current.PermissionMode) ? current.PermissionMode : AiPermissionMode.Ask;
            // Configure owns the connection transition; keep all unrelated choices.
            await ConfigureChoiceAsync(current with { Provider = account.Provider, AccountId = account.Id, Options = current.Options with { Model = model.Id, Effort = effort ?? "" }, PermissionMode = mode });
          });
        };
        section.Items.Add(item);
      }
      menu.Items.Add(section);
    }
    if (AddAccount is not null) AddMenu(menu, "Add account…", AddAccount);
    else if (openCodingAis is not null) AddMenu(menu, "Add account…", () => { openCodingAis(); return Task.CompletedTask; });
    menu.ShowAt(accountChip);
  }

  // Called within RunAsync so failures and pending state use the same owner as sends.
  private ValueTask ConfigureChoiceAsync(HootSettings settings) => Model.ApplySettingsAsync(settings);

  private async Task ShowModelChoicesAsync()
  {
    var current = await ReadyChoicesAsync(); if (current is null) return;
    await Model.RunAsync(async () =>
    {
      var offered = await Model.ModelsAsync(current.AccountId);
      if (Model.State.Settings != current) return;
      var menu = new MenuFlyout();
      foreach (var model in offered)
      {
        var item = new ToggleMenuFlyoutItem { Text = model.Name, IsChecked = model.Id == current.Options.Model };
        item.Click += async (_, _) =>
        {
          if (Model.State.Settings != current) return;
          var efforts = ModelEfforts.For(current.Provider, model);
          var effort = efforts.Contains(current.Options.Effort ?? "") ? current.Options.Effort : efforts.Contains(ModelCatalog.TopEffort(current.Provider) ?? "") ? ModelCatalog.TopEffort(current.Provider) : efforts.LastOrDefault();
          await Model.ConfigureAsync(current with { Options = current.Options with { Model = model.Id, Effort = effort ?? "" } });
        };
        menu.Items.Add(item);
      }
      if (menu.Items.Count == 0) throw new InvalidOperationException("This account did not report any models. Check it in Coding AIs.");
      menu.ShowAt(modelChip);
    });
  }

  private async Task ShowEffortChoicesAsync()
  {
    var current = await ReadyChoicesAsync(); if (current is null) return;
    await Model.RunAsync(async () =>
    {
      var models = await Model.ModelsAsync(current.AccountId); if (Model.State.Settings != current) return;
      var menu = new MenuFlyout();
      foreach (var effort in ModelEfforts.For(current.Provider, models.FirstOrDefault(m => m.Id == current.Options.Model)))
      {
        var item = new ToggleMenuFlyoutItem { Text = ModelCatalog.EffortName(effort), IsChecked = effort == current.Options.Effort };
        item.Click += async (_, _) => { if (Model.State.Settings == current) await Model.ConfigureAsync(current with { Options = current.Options with { Effort = effort ?? "" } }); };
        menu.Items.Add(item);
      }
      if (menu.Items.Count > 0) menu.ShowAt(effortChip);
    });
  }

  private void ShowPermissionChoices()
  {
    var current = Model.State.Settings; if (current is null) { _ = ShowSettingsAsync(); return; }
    var menu = new MenuFlyout();
    foreach (var mode in TerminalDeck.Core.Chats.ChatPermissionModes.Supported(current.Provider))
    {
      var item = new ToggleMenuFlyoutItem { Text = TerminalDeck.Core.Chats.ChatPermissionModes.Label(mode), IsChecked = current.PermissionMode == mode };
      item.Click += async (_, _) =>
      {
        if (Model.State.Settings != current) return;
        if (mode == AiPermissionMode.Bypass && current.PermissionMode != mode && await Dialog("Allow Bypass permissions?", Words("Hoot skips the coding AI's permission questions. Saved app access and server confirmations still apply."), "Allow Bypass").ShowAsync() != ContentDialogResult.Primary) return;
        if (Model.State.Settings == current) await Model.ConfigureAsync(current with { PermissionMode = mode });
      };
      menu.Items.Add(item);
    }
    menu.ShowAt(permissionChip);
  }
}
