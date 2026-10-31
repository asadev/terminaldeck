using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views;

internal sealed class McpArgumentForm : StackPanel
{
  private readonly Func<(bool HasValue, JsonNode? Value)> read;
  public event Action<string>? DraftChanged;
  public McpArgumentForm(JsonElement schema, string? draft)
  {
    Spacing = 12;
    JsonNode? initial = null;
    try { if (draft is not null) initial = JsonNode.Parse(draft); } catch (JsonException) { }
    read = Field(this, schema, "Arguments", true, initial, 0);
  }
  public JsonElement Read()
  {
    var value = read();
    return JsonSerializer.SerializeToElement(value.Value);
  }
  private void Changed()
  {
    try { DraftChanged?.Invoke(Read().GetRawText()); }
    catch (Exception ex) when (ex is JsonException or McpRefusal or FormatException or OverflowException) { }
  }
  private Func<(bool, JsonNode?)> Field(StackPanel parent, JsonElement schema, string label, bool required, JsonNode? initial, int depth)
  {
    var title = label + (required ? " · Required" : "");
    var type = schema.TryGetProperty("type", out var kind) && kind.ValueKind == JsonValueKind.String ? kind.GetString() : null;
    if (schema.TryGetProperty("description", out var description) && description.ValueKind == JsonValueKind.String)
      parent.Children.Add(new TextBlock { Text = description.GetString(), TextWrapping = TextWrapping.Wrap, Opacity = 0.7 });
    if (depth < 8 && type == "object" && schema.TryGetProperty("properties", out var properties) && properties.ValueKind == JsonValueKind.Object)
    {
      var requiredNames = schema.TryGetProperty("required", out var needed) ? needed.EnumerateArray().Select(v => v.GetString()).ToHashSet() : [];
      var fields = new List<(string Name, Func<(bool HasValue, JsonNode? Value)> Read)>();
      foreach (var property in properties.EnumerateObject())
        fields.Add((property.Name, Field(parent, property.Value, property.Name, requiredNames.Contains(property.Name), initial?[property.Name], depth + 1)));
      return () =>
      {
        var result = new JsonObject();
        foreach (var field in fields) { var value = field.Read(); if (value.HasValue) result[field.Name] = value.Value; }
        return (true, result);
      };
    }
    if (schema.TryGetProperty("enum", out var choices))
    {
      var values = choices.EnumerateArray().Select(v => v.Clone()).ToArray();
      var picker = new ComboBox { Header = title, ItemsSource = new[] { "Choose a value" }.Concat(values.Select(v => v.ValueKind == JsonValueKind.String ? v.GetString()! : v.GetRawText())).ToArray(), SelectedIndex = Array.FindIndex(values, v => initial is not null && JsonNode.DeepEquals(JsonNode.Parse(v.GetRawText()), initial)) + 1, HorizontalAlignment = HorizontalAlignment.Stretch };
      picker.SelectionChanged += (_, _) => Changed(); parent.Children.Add(picker);
      return () => picker.SelectedIndex <= 0 ? required ? throw new McpRefusal("Choose " + label + ".") : (false, null) : (true, JsonNode.Parse(values[picker.SelectedIndex - 1].GetRawText()));
    }
    if (type == "boolean")
    {
      var box = new CheckBox { Content = title, IsThreeState = !required, IsChecked = initial is null ? required ? false : null : initial.GetValue<bool>() };
      box.Checked += (_, _) => Changed(); box.Unchecked += (_, _) => Changed(); box.Indeterminate += (_, _) => Changed(); parent.Children.Add(box);
      return () => box.IsChecked is { } selected ? (true, JsonValue.Create(selected)) : (false, null);
    }
    if (depth < 8 && type == "array" && schema.TryGetProperty("items", out var item))
    {
      var group = new StackPanel { Spacing = 8 }; group.Children.Add(new TextBlock { Text = title });
      var rows = new List<(StackPanel Row, Func<(bool HasValue, JsonNode? Value)> Read)>();
      void Add(JsonNode? seed)
      {
        var row = new StackPanel { Spacing = 8 };
        var reader = Field(row, item, "Item", true, seed, depth + 1);
        var remove = new Button { Content = "Remove item" }; remove.Click += (_, _) => { rows.RemoveAll(r => r.Row == row); group.Children.Remove(row); Changed(); };
        row.Children.Add(remove); rows.Add((row, reader)); group.Children.Add(row);
      }
      var add = new Button { Content = "Add item" }; add.Click += (_, _) => { Add(null); Changed(); }; group.Children.Add(add);
      if (initial is JsonArray array) foreach (var seed in array) Add(seed);
      parent.Children.Add(group);
      return () => (required || rows.Count > 0, new JsonArray(rows.Select(r => r.Read().Value).ToArray()));
    }
    var primitive = type is "string" or "integer" or "number";
    var text = new TextBox { Header = primitive ? title : title + " · JSON", Text = initial is null ? type == "object" ? "{}" : type == "array" ? "[]" : "" : type == "string" ? initial.GetValue<string>() : initial.ToJsonString(), AcceptsReturn = !primitive, TextWrapping = TextWrapping.Wrap, MaxHeight = 180 };
    text.TextChanged += (_, _) => Changed(); parent.Children.Add(text);
    return () =>
    {
      if (!required && text.Text.Length == 0) return (false, null);
      try
      {
        return type switch
        {
          "string" => (true, JsonValue.Create(text.Text)),
          "integer" => (true, JsonValue.Create(long.Parse(text.Text, CultureInfo.InvariantCulture))),
          "number" => (true, double.TryParse(text.Text, CultureInfo.InvariantCulture, out var number) && double.IsFinite(number) ? JsonValue.Create(number) : throw new FormatException()),
          _ => (true, JsonNode.Parse(text.Text))
        };
      }
      catch (Exception ex) when (ex is FormatException or OverflowException or JsonException) { throw new McpRefusal("Enter a valid " + (primitive ? type : "JSON value") + " for " + label + "."); }
    };
  }
}
