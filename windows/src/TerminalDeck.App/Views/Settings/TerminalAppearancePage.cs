using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Settings;
using TerminalDeck.Platform.Windows;
using static TerminalDeck.App.Views.Servers.ServerUi;

namespace TerminalDeck.App.Views.Settings;

public sealed class TerminalAppearancePage : StackPanel
{
  private readonly TerminalAppearanceService service;
  private bool rendering;
  private readonly Action changed;
  public TerminalAppearancePage(TerminalAppearanceService service)
  {
    this.service = service; Spacing = 16; changed = () => DispatcherQueue.TryEnqueueHandled(Render);
    ActualThemeChanged += (_, _) => Render();
    Loaded += (_, _) => { service.Changed += changed; Render(); }; Unloaded += (_, _) => service.Changed -= changed; Render();
  }
  private void Render()
  {
    if (rendering) return; rendering = true;
    try
    {
      Children.Clear(); var state = service.Preferences(); Children.Add(Words("Sessions", 18));
      var fonts = TerminalFontCatalog.Installed(); var choices = new[] { "App default" }.Concat(fonts).ToList(); if (state.FontFamily.Length > 0 && !fonts.Contains(state.FontFamily)) choices.Add(state.FontFamily + " (not installed)");
      var font = new ComboBox { Header = "Terminal font", ItemsSource = choices, SelectedItem = state.FontFamily.Length == 0 ? "App default" : fonts.Contains(state.FontFamily) ? state.FontFamily : state.FontFamily + " (not installed)", HorizontalAlignment = HorizontalAlignment.Stretch };
      var size = new NumberBox { Header = "Size", Minimum = 9, Maximum = 24, Value = state.FontSize, SmallChange = 1, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, Width = 120 };
      var row = new Grid { ColumnSpacing = 12 }; row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.Children.Add(font); Grid.SetColumn(size, 1); row.Children.Add(size); Children.Add(row);
      font.SelectionChanged += (_, _) => { if (rendering) return; var selected = (string)font.SelectedItem; Save(() => service.Set(fontFamily: selected == "App default" ? "" : selected.Replace(" (not installed)", "", StringComparison.Ordinal))); };
      size.ValueChanged += (_, _) => { if (!rendering && double.IsFinite(size.Value)) Save(() => service.Set(fontSize: (int)Math.Clamp(Math.Round(size.Value), 9, 24))); };
      Children.Add(new TextBlock { Text = "The quick brown fox jumps over the lazy dog · 0123456789", FontSize = state.FontSize, FontFamily = state.FontFamily.Length == 0 ? DeckFonts.Mono : new FontFamily(state.FontFamily), TextWrapping = TextWrapping.Wrap });
      var palettes = new ComboBox { Header = "Terminal colours", ItemsSource = new[] { new PaletteChoice("follow-app", "Follow app appearance") }.Concat(service.Palettes().Select(p => new PaletteChoice(p.Id, p.Name))).ToArray(), SelectedValuePath = "Id", DisplayMemberPath = "Name", SelectedValue = state.Scheme, HorizontalAlignment = HorizontalAlignment.Stretch };
      palettes.SelectionChanged += (_, _) => { if (!rendering && palettes.SelectedValue is string id) Save(() => service.Set(scheme: id)); }; Children.Add(palettes);
      var palette = service.Resolved(ActualTheme == ElementTheme.Dark); Children.Add(Preview(palette, state.FontSize));
      var actions = Horizontal(); actions.Children.Add(Button("Make a copy", () => { Save(() => service.Copy(palette.Id)); return Task.CompletedTask; })); actions.Children.Add(Button("Import…", ImportAsync)); actions.Children.Add(Button("Copy JSON", () => { var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(service.Export(palette.Id)); Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); return Task.CompletedTask; }));
      if ((state.Custom ?? []).Any(p => p.Id == palette.Id))
      {
        actions.Children.Add(Button("Edit colours…", () => EditAsync(palette)));
        actions.Children.Add(Button("Remove…", async () => { if (await Dialog(XamlRoot, "Remove " + palette.Name + "?", Words("Sessions using this palette will follow the app appearance."), "Remove").ShowAsync() == ContentDialogResult.Primary) Save(() => service.Remove(palette.Id)); }));
      }
      actions.Children.Add(Button("Reset defaults", () => { Save(service.Reset); return Task.CompletedTask; })); Children.Add(actions);
    }
    finally { rendering = false; }
  }
  private static Border Preview(TerminalPalette palette, int size)
  {
    var body = new StackPanel { Spacing = 8, Padding = new Thickness(16), Background = Brush(palette.Colors["background"]) };
    foreach (var words in new[] { new[] { ("➜ ", "green"), ("app ", "cyan"), ("git:(", "blue"), ("main", "red"), (") ", "blue"), ("npm test", "foreground") }, new[] { ("✓ 42 passed", "green"), ("   ! 1 skipped", "yellow"), ("   × 0", "red") } })
    {
      var line = new TextBlock { FontFamily = DeckFonts.Mono, FontSize = size, TextWrapping = TextWrapping.Wrap };
      foreach (var (text, color) in words) line.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = text, Foreground = Brush(palette.Colors[color]) }); body.Children.Add(line);
    }
    var samples = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
    samples.Children.Add(new Border { Background = Brush(palette.Colors["selectionBackground"]), Child = new TextBlock { Text = "Selected text", Foreground = Brush(palette.Colors["foreground"]), FontFamily = DeckFonts.Mono, FontSize = size } });
    samples.Children.Add(new Border { Background = Brush(palette.Colors["cursor"]), Child = new TextBlock { Text = "_", Foreground = Brush(palette.Colors["cursorAccent"]), FontFamily = DeckFonts.Mono, FontSize = size } }); body.Children.Add(samples);
    return new Border { Child = body, CornerRadius = new CornerRadius(8) };
  }
  private async Task ImportAsync()
  {
    var text = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxLength = 65536, MinHeight = 240, FontFamily = DeckFonts.Mono, PlaceholderText = "Paste a JSON palette or Windows Terminal schemes file" };
    if (await Dialog(XamlRoot, "Import terminal colours", text, "Import").ShowAsync() == ContentDialogResult.Primary) Save(() => service.Import(text.Text));
  }
  private async Task EditAsync(TerminalPalette palette)
  {
    var form = Stack(8); var name = Field("Name", palette.Name); form.Children.Add(name); var fields = new Dictionary<string, TextBox>();
    foreach (var slot in TerminalAppearanceService.Slots) { var field = Field(slot, palette.Colors[slot]); fields[slot] = field; form.Children.Add(field); }
    if (await Dialog(XamlRoot, "Edit " + palette.Name, new ScrollViewer { Content = form, MaxHeight = 520 }, "Save colours").ShowAsync() == ContentDialogResult.Primary) Save(() => service.Edit(palette.Id, name.Text, fields.ToDictionary(p => p.Key, p => p.Value.Text)));
  }
  private async void Save(Action action)
  {
    try { action(); Render(); }
    catch (Exception error) when (error is ArgumentException or IOException or InvalidOperationException or System.Text.Json.JsonException) { await Dialog(XamlRoot, "Could not save terminal appearance", Words(error.Message), "Done").ShowAsync(); }
  }
  private static SolidColorBrush Brush(string value)
  {
    value = TerminalAppearanceService.Color(value); var a = value.Length == 9 ? Convert.ToByte(value[7..9], 16) : (byte)255;
    return new(Windows.UI.Color.FromArgb(a, Convert.ToByte(value[1..3], 16), Convert.ToByte(value[3..5], 16), Convert.ToByte(value[5..7], 16)));
  }
  private sealed record PaletteChoice(string Id, string Name);
}
