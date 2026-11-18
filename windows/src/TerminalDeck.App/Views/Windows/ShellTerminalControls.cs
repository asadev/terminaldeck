using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private FrameworkElement? WindowTerminalControls(TerminalDeck.App.Shell.WorkspaceTab tab)
  {
    var record = Runtime.Sessions.FirstOrDefault(s => s.Definition.Id == tab.Subject);
    if (tab.Kind != "terminal" || record is null || record.Definition.Provider == "shell" || record.Definition.Purpose is not null) return null;
    var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
    var model = TerminalControlChip("Model", "terminal.model");
    var effort = TerminalControlChip("Effort", "terminal.effort");
    controls.Children.Add(model); controls.Children.Add(effort);
    void Refresh()
    {
      var context = Runtime.Usage.Context(tab.Subject);
      var active = Runtime.Sessions.FirstOrDefault(row => row.Definition.Id == tab.Subject);
      model.Content = TerminalChoiceLabel(context.ModelLabel ?? context.Model ?? active?.Definition.Model, "Model");
      effort.Content = TerminalChoiceLabel(active?.Definition.Effort is { } level ? Chat.ChatAppearance.EffortName(level) : null, "Effort");
      ToolTipService.SetToolTip(model, context.Model is null ? "Choose the model for this terminal" : "Model from the last reply: " + (context.ModelLabel ?? context.Model));
    }
    void Changed() => controls.DispatcherQueue.TryEnqueue(Refresh);
    void UsageChanged(string id) { if (id == tab.Subject) Changed(); }
    controls.Loaded += (_, _) => { Runtime.Changed += Changed; Runtime.Usage.Changed += UsageChanged; Refresh(); };
    controls.Unloaded += (_, _) => { Runtime.Changed -= Changed; Runtime.Usage.Changed -= UsageChanged; };
    Refresh();
    async Task Pick(string control, string value)
    {
      model.IsEnabled = effort.IsEnabled = false;
      try
      {
        Model.Notice = "Sending " + control + " choice to Claude…";
        await Runtime.ApplyTerminalControlAsync(tab.Subject, control, value);
        Model.Notice = "Choice sent to Claude. Its terminal shows the confirmation.";
      }
      catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or IOException) { Model.Notice = ex.Message; }
      finally { model.IsEnabled = effort.IsEnabled = true; }
    }
    bool Refused(MenuFlyout menu)
    {
      var current = Runtime.Sessions.FirstOrDefault(s => s.Definition.Id == tab.Subject);
      var reason = current is null ? "That terminal is no longer open." : current.Definition.Provider != "claude"
        ? "Change model and effort in this coding AI's own terminal menu." : current.State != SessionState.Running ? "This session is not running." : null;
      if (reason is null) return false;
      menu.Items.Add(new MenuFlyoutItem { Text = reason, IsEnabled = false }); return true;
    }
    void PopulateModels(MenuFlyout menu, IReadOnlyList<ProviderModel> choices)
    {
      menu.Items.Clear(); if (Refused(menu)) return;
      foreach (var choice in choices)
      {
        var item = new MenuFlyoutItem { Text = choice.Name };
        item.Click += async (_, _) => await Pick("model", choice.Id); menu.Items.Add(item);
      }
      if (choices.Count == 0) menu.Items.Add(new MenuFlyoutItem { Text = "Models unavailable. Check Coding AIs.", IsEnabled = false });
      menu.Items.Add(new MenuFlyoutSeparator());
      var fast = new MenuFlyoutSubItem { Text = "Fast mode" };
      foreach (var value in new[] { "on", "off" })
      {
        var item = new MenuFlyoutItem { Text = value == "on" ? "On" : "Off" };
        item.Click += async (_, _) => await Pick("fast", value); fast.Items.Add(item);
      }
      menu.Items.Add(fast);
    }
    model.Click += async (_, _) =>
    {
      var menu = DeckMenu.CreateFor(controls);
      PopulateModels(menu, Runtime.Accounts.InstantModels(record.Definition.Provider, record.Definition.AccountId).Models); menu.ShowAt(model);
      if (record.Definition.AccountId is not { } account || record.Definition.Provider != "claude") return;
      try { PopulateModels(menu, (await Runtime.Accounts.ModelsAsync(account)).Models); }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException) { }
    };
    effort.Click += (_, _) =>
    {
      var menu = DeckMenu.CreateFor(controls);
      if (!Refused(menu))
        foreach (var value in ModelEfforts.For(record.Definition.Provider, null))
        {
          var item = new MenuFlyoutItem { Text = Chat.ChatAppearance.EffortName(value) };
          item.Click += async (_, _) => await Pick("effort", value); menu.Items.Add(item);
        }
      menu.ShowAt(effort);
    };
    return controls;
  }

  private static StackPanel TerminalChoiceLabel(string? value, string fallback)
  {
    var empty = string.IsNullOrWhiteSpace(value) || value.Equals("unknown", StringComparison.OrdinalIgnoreCase);
    var label = new TextBlock { Text = empty ? fallback : value, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 140, VerticalAlignment = VerticalAlignment.Center };
    if (empty) label.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
    row.Children.Add(label); row.Children.Add(new DeckIcon { Glyph = "\uE70D", FontSize = 7, VerticalAlignment = VerticalAlignment.Center }); return row;
  }

  private static Button TerminalControlChip(string label, string automationId)
  {
    var chip = new Button { Content = label };
    DeckMenu.Pill(chip);
    AutomationProperties.SetAutomationId(chip, automationId); AutomationProperties.SetName(chip, label + " for this terminal");
    ToolTipService.SetToolTip(chip, label + " for this terminal"); return chip;
  }
}
