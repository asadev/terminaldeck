using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Integration;

namespace TerminalDeck.App.Views.Computers;

internal static class ComputerServiceReading
{
  public static string Describe(JsonElement value)
  {
    var lines = new List<string>();
    void Add(JsonElement item, string name, int depth)
    {
      if (depth > 6 || lines.Count >= 120) return;
      if (item.ValueKind == JsonValueKind.Object)
      {
        if (name.Length > 0) lines.Add(name);
        foreach (var field in item.EnumerateObject())
        {
          if (field.Name is "t" or "rid" or "token" or "secret" or "accountHome" or "homeId" or "credential" or "deviceId") continue;
          var label = new StringBuilder(); foreach (var c in field.Name) { if (char.IsUpper(c) && label.Length > 0) label.Append(' '); label.Append(c == '_' ? ' ' : c); }
          var text = label.ToString(); Add(field.Value, text.Length > 0 ? char.ToUpperInvariant(text[0]) + text[1..] : "", depth + 1);
        }
      }
      else if (item.ValueKind == JsonValueKind.Array) { if (name.Length > 0) lines.Add(name + (item.GetArrayLength() == 0 ? ": None" : "")); foreach (var row in item.EnumerateArray().Take(30)) Add(row, "", depth + 1); }
      else if (item.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined))
      {
        var text = item.ValueKind == JsonValueKind.True ? "Yes" : item.ValueKind == JsonValueKind.False ? "No" : item.ToString();
        if (text.Length > 2000) text = text[..2000] + "…";
        if (text.Length > 0) lines.Add((name.Length > 0 ? name + ": " : "") + text);
      }
    }
    Add(value, "", 0); return string.Join('\n', lines);
  }
  public static void Accounts(ComboBox picker, JsonElement reply)
  {
    if (!reply.TryGetProperty("accounts", out var accounts) || accounts.ValueKind != JsonValueKind.Array) return;
    picker.Items.Clear();
    foreach (var account in accounts.EnumerateArray().Where(a => a.ValueKind == JsonValueKind.Object).Take(64))
    {
      var id = OtherComputersService.Text(account, "id", OtherComputersService.Text(account, "accountId", "")); if (id.Length == 0) continue;
      var name = OtherComputersService.Text(account, "name", OtherComputersService.Text(account, "email", id));
      picker.Items.Add(new ComboBoxItem { Content = name + " · " + OtherComputersService.Text(account, "provider", ""), Tag = id });
    }
    if (picker.Items.Count > 0) picker.SelectedIndex = 0;
  }
  public static string Account(ComboBox picker) => picker.SelectedItem is ComboBoxItem { Tag: string id } ? id : throw new InvalidOperationException("Read the available accounts, then choose one.");
}
