using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Agents;

namespace TerminalDeck.App.Views.Settings;

// Every field is consumed by the launch guard or the keeper's task budget observer.
internal static class AgentEfficiencyEditor
{
  internal static FrameworkElement[] Rows(Func<AgentEfficiency?> read, Action<AgentEfficiency?> save, Action<string> problem)
  {
    var rows = new List<FrameworkElement>();
    FrameworkElement Number(string title, string help, string id, Func<AgentEfficiency, decimal?> value, Func<AgentEfficiency, decimal?, AgentEfficiency> update, bool integer = true)
    {
      var original = value(read() ?? new())?.ToString(CultureInfo.CurrentCulture) ?? "";
      var field = new TextBox { Text = original, PlaceholderText = "App default", Width = 160, MinHeight = 28, TextAlignment = TextAlignment.Right };
      AutomationProperties.SetAutomationId(field, "agents.efficiency." + id);
      void Commit()
      {
        if (field.Text == original) return;
        try
        {
          decimal? amount = string.IsNullOrWhiteSpace(field.Text) ? null : decimal.TryParse(field.Text, NumberStyles.Number, CultureInfo.CurrentCulture, out var n) && (!integer || decimal.Truncate(n) == n) ? n : throw new ArgumentException("Enter a valid " + (integer ? "whole number." : "amount in USD."));
          if (amount is < 0 or > 1_000_000_000) throw new ArgumentException("Use a budget from 0 to 1,000,000,000.");
          var next = update(read() ?? new(), amount); next.Validate(); save(next); original = field.Text;
        }
        catch (Exception error) when (error is ArgumentException or IOException or InvalidOperationException) { field.Text = original; problem(error.Message); }
      }
      field.LostFocus += (_, _) => Commit();
      field.KeyDown += (_, args) => { if (args.Key == Windows.System.VirtualKey.Enter) { Commit(); args.Handled = true; } else if (args.Key == Windows.System.VirtualKey.Escape) { field.Text = original; args.Handled = true; } };
      return SettingsPanel.SettingRow(title, help, field);
    }
    FrameworkElement Pick(string title, string help, string id, string[] labels, Func<AgentEfficiency, int> index, Func<AgentEfficiency, int, AgentEfficiency> update)
    {
      var select = new ComboBox { ItemsSource = labels, SelectedIndex = index(read() ?? new()), MinWidth = 160 };
      AutomationProperties.SetAutomationId(select, "agents.efficiency." + id);
      var kept = select.SelectedIndex; var restoring = false;
      select.SelectionChanged += (_, _) =>
      {
        if (restoring) return;
        try { save(update(read() ?? new(), select.SelectedIndex)); kept = select.SelectedIndex; }
        catch (Exception error) when (error is ArgumentException or IOException or InvalidOperationException)
        { restoring = true; select.SelectedIndex = kept; restoring = false; problem(error.Message); }
      };
      return SettingsPanel.SettingRow(title, help, select);
    }
    rows.Add(Pick("Reuse conversation", "New tasks may resume this agent's exact parked conversation only when its project, account, folder, instructions and security settings match. No live conversation is taken over.", "reuseContext", ["App default (start fresh)", "Reuse compatible context", "Start fresh"], p => p.ReuseContext switch { true => 1, false => 2, _ => 0 }, (p, n) => p with { ReuseContext = n == 0 ? null : n == 1 }));
    rows.Add(Pick("When a task finishes", "When the task is marked Done, wait for its current reply, then Park ends its process and keeps its conversation; Stop ends the session. App default keeps the existing behavior.", "completion", ["App default (keep open)", "Park", "Stop"], p => p.Completion switch { "park" => 1, "stop" => 2, _ => 0 }, (p, n) => p with { Completion = n switch { 1 => "park", 2 => "stop", _ => null } }));
    rows.Add(Pick("Extra add-ons", "Off excludes other MCP child processes at launch and keeps this app's tools. Claude skills and Gemini extensions are also off. A Codex plugin that cannot be disabled for one session makes the launch refuse this choice.", "addonsOff", ["App default (on)", "Off", "On"], p => p.AddonsOff switch { true => 1, false => 2, _ => 0 }, (p, n) => p with { AddonsOff = n == 0 ? null : n == 1 }));
    rows.Add(Pick("One heavy job at a time", "Task briefs ask agents to use the app's one shared work lock before builds and tests. Waiting uses a change event. Manually started commands are not blocked.", "serializeHeavyJobs", ["App default (off)", "On", "Off"], p => p.SerializeHeavyJobs switch { true => 1, false => 2, _ => 0 }, (p, n) => p with { SerializeHeavyJobs = n == 0 ? null : n == 1 }));
    rows.Add(Number("Monthly token budget", "Tokens across this agent's subscription-account sessions this month. Blank inherits; 0 is unlimited. Provider readings that are missing stay unknown.", "monthlyTokens", p => p.MonthlyTokens, (p, n) => p with { MonthlyTokens = n is null ? null : checked((long)n) }));
    rows.Add(Number("Monthly API budget (USD)", "Uses provider-reported cost for API accounts. Missing cost is unknown. Blank inherits; 0 is unlimited.", "monthlyUsd", p => p.MonthlyUsd, (p, n) => p with { MonthlyUsd = n }, false));
    rows.Add(Number("Task token budget", "A token warning budget for each new task. A task can shorten this budget but cannot increase it. Blank inherits; 0 is unlimited.", "taskTokens", p => p.TaskTokens, (p, n) => p with { TaskTokens = n is null ? null : checked((long)n) }));
    rows.Add(Number("Warn at (%)", "The app default is 80%. Warnings appear in the task's activity.", "warningPercent", p => p.WarningPercent, (p, n) => p with { WarningPercent = n is null ? null : checked((int)n) }));
    rows.Add(Pick("When the budget runs out", "Pause checks before a new task starts. Running work continues. When its usage is unknown, Pause also keeps the next task waiting until the budget can be checked or you change this choice.", "onExhaustion", ["App default (warn)", "Only warn", "Pause new tasks"], p => p.OnExhaustion switch { "warn" => 1, "pause" => 2, _ => 0 }, (p, n) => p with { OnExhaustion = n switch { 1 => "warn", 2 => "pause", _ => null } }));
    return rows.ToArray();
  }
}
