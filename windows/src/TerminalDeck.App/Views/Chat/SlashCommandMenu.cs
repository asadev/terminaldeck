using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.App.Views.Chat;

// The composer's "/" menu (Mac HootComposer.slashMenu): while the box holds one
// "/word", the session's commands and skills that match it show above the text,
// one line each with a short description. Up/Down choose, Tab fills, Enter runs
// (a command that takes arguments is filled for them first), Escape closes.
internal sealed class SlashCommandMenu
{
  private readonly TextBox box;
  private readonly Func<IReadOnlyList<ChatSlashCommand>> source;
  private readonly Func<Task> send;
  private readonly Action<string>? openControl;
  private readonly StackPanel list = new() { Spacing = 1 };
  private IReadOnlyList<ChatSlashCommand>? catalogue;
  private IReadOnlyList<ChatSlashCommand> shown = [];
  private int selected;
  private string? closedOn;
  public ScrollViewer View { get; }

  public SlashCommandMenu(TextBox box, Func<IReadOnlyList<ChatSlashCommand>> source, Func<Task> send, Action<string>? openControl = null)
  {
    this.box = box; this.source = source; this.send = send; this.openControl = openControl;
    View = new ScrollViewer { Content = list, MaxHeight = 220, Visibility = Visibility.Collapsed, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    AutomationProperties.SetName(View, "Commands"); AutomationProperties.SetAutomationId(View, "chat.slashMenu");
    box.RegisterPropertyChangedCallback(TextBox.TextProperty, (_, _) => Update());
    box.PreviewKeyDown += OnKey;
  }

  public bool IsOpen => View.Visibility == Visibility.Visible;

  private void Update()
  {
    var query = ChatSlashCommands.Query(box.Text);
    // Read the session's list when a new "/" starts, so skills added since show up.
    if (query is null) { catalogue = null; closedOn = null; Hide(); return; }
    if (closedOn == box.Text) { Hide(); return; }
    try { catalogue ??= source(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { catalogue = []; }
    shown = ChatSlashCommands.Matches(catalogue, query).Take(40).ToArray();
    if (shown.Count == 0) { Hide(); return; }
    selected = 0; Render(); View.Visibility = Visibility.Visible;
  }

  private void Hide() { View.Visibility = Visibility.Collapsed; shown = []; }

  private void Render()
  {
    list.Children.Clear();
    for (var index = 0; index < shown.Count; index++)
    {
      var command = shown[index]; var at = index;
      var row = new Grid { ColumnSpacing = 8, Padding = new Thickness(8, 5, 8, 5), CornerRadius = new CornerRadius(6) };
      row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
      row.Children.Add(new TextBlock { Text = "/" + command.Name, FontFamily = TerminalDeck.App.Views.DeckFonts.Mono, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
      var hint = new TextBlock { Text = command.ArgumentHint, FontSize = 12, Opacity = 0.55, VerticalAlignment = VerticalAlignment.Center };
      Grid.SetColumn(hint, 1); row.Children.Add(hint);
      var about = new TextBlock { Text = command.Description, FontSize = 12, Opacity = 0.75, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center };
      Grid.SetColumn(about, 2); row.Children.Add(about);
      ToolTipService.SetToolTip(row, "/" + command.Name + (command.Description.Length > 0 ? " — " + command.Description : ""));
      AutomationProperties.SetName(row, "/" + command.Name + (command.Description.Length > 0 ? ", " + command.Description : ""));
      row.Tapped += async (_, e) => { e.Handled = true; selected = at; await PickAsync(run: true); };
      list.Children.Add(row);
    }
    Highlight();
  }

  private void Highlight()
  {
    Brush? brush = null;
    try { brush = Application.Current.Resources["SubtleFillColorSecondaryBrush"] as Brush; } catch (Exception ex) when (ex is not OutOfMemoryException) { }
    brush ??= new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(40, 128, 128, 128));
    for (var i = 0; i < list.Children.Count; i++) ((Grid)list.Children[i]).Background = i == selected ? brush : null;
    if (selected < list.Children.Count) ((FrameworkElement)list.Children[selected]).StartBringIntoView();
  }

  private async void OnKey(object sender, KeyRoutedEventArgs e)
  {
    if (!IsOpen || shown.Count == 0) return;
    switch (e.Key)
    {
      case Windows.System.VirtualKey.Down: e.Handled = true; selected = (selected + 1) % shown.Count; Highlight(); break;
      case Windows.System.VirtualKey.Up: e.Handled = true; selected = (selected - 1 + shown.Count) % shown.Count; Highlight(); break;
      case Windows.System.VirtualKey.Escape: e.Handled = true; closedOn = box.Text; Hide(); break;
      case Windows.System.VirtualKey.Tab: e.Handled = true; await PickAsync(run: false); break;
      case Windows.System.VirtualKey.Enter:
        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift);
        if ((shift & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0) return;
        e.Handled = true; await PickAsync(run: true); break;
    }
  }

  private async Task PickAsync(bool run)
  {
    if (selected < 0 || selected >= shown.Count) return;
    var command = shown[selected]; Hide();
    if (command.Control is { } control && openControl is not null) { box.Text = ""; openControl(control); return; }
    var text = ChatSlashCommands.Text(command);
    closedOn = text; box.Text = text; box.SelectionStart = text.Length; box.Focus(FocusState.Programmatic);
    // A command with arguments waits for them; one without runs now (the AI expands it).
    if (run && command.ArgumentHint.Length == 0) await send();
  }
}
