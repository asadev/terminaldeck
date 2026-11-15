using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Shapes;
using TerminalDeck.App.Shell;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.WhatsApp;

namespace TerminalDeck.App.Views.WhatsApp;

// Settings > AI apps, the LAST group "WhatsApp" (DESIGN-WHATSAPP section 2; the Mac's NativeWhatsAppSettingsGroup).
// Title with ONE info button (the three steps and one secondary line); one row per WhatsApp agent: 7 px dot, its name,
// at the right "Paused" / the waiting words / "Answered by …" in secondary text, the pop-up of where it is received (or
// the orange "The key was refused" instead), then the plain "…" menu (Pause/Resume, Rename, Replace key, Remove).
// Last row, ALWAYS: "+ Add WhatsApp agent", which turns into a name field, a key field and a small "Add". Rename and
// Replace key turn their row into its one field in place. Nothing else: no log, no test button.
public sealed class WhatsAppSettingsGroup : StackPanel
{
  private enum Editing { None, Name, Key }

  private readonly WhatsAppAgentsStore store;
  private readonly Func<WhatsAppReceiverChoices> choices;
  private readonly Border holder = new();
  // What the person is typing survives a redraw of the rows (the list changes while he types).
  private bool adding;
  private string addName = "", addKey = "";
  private string? editingId;
  private Editing editing;
  private string editText = "";
  private bool focusAfterDraw;
  private Button? addButton, saveKeyButton;

  public WhatsAppSettingsGroup(WhatsAppAgentsStore store, Func<WhatsAppReceiverChoices> choices, bool startsAdding = false)
  {
    this.store = store; this.choices = choices;
    Spacing = 8;
    AutomationProperties.SetAutomationId(this, "aiApps.whatsapp");
    Children.Add(Title());
    Children.Add(holder);
    if (startsAdding) Begin();
    Draw();
    Loaded += (_, _) => { store.Changed += Later; store.PropertyChanged += StoreProperty; Draw(); };
    Unloaded += (_, _) => { store.Changed -= Later; store.PropertyChanged -= StoreProperty; };
  }

  private void Later() => DispatcherQueue?.TryEnqueue(Draw);
  private void StoreProperty(object? sender, System.ComponentModel.PropertyChangedEventArgs e) => DispatcherQueue?.TryEnqueue(() =>
  {
    if (e.PropertyName == nameof(WhatsAppAgentsStore.Checking)) { if (addButton is not null) addButton.IsEnabled = CanAdd(); if (saveKeyButton is not null) saveKeyButton.IsEnabled = !store.Checking; }
  });

  // ---- the title and its one info button ----

  private static FrameworkElement Title()
  {
    var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(12, 0, 0, 0) };
    line.Children.Add(new TextBlock { Text = WhatsAppWords.GroupTitle, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
    var info = SettingsPanel.InfoButton(WhatsAppWords.GroupTitle, WhatsAppWords.Steps);
    info.Flyout = new Flyout { Content = InfoContent() };
    AutomationProperties.SetAutomationId(info, "aiApps.whatsapp.info");
    line.Children.Add(info);
    return line;
  }

  /// What the info button opens: the three steps, then one secondary line (also drawn by the pictures).
  internal static FrameworkElement InfoContent()
  {
    var words = new StackPanel { Spacing = 8, Width = 280 };
    words.Children.Add(new TextBlock { Text = WhatsAppWords.Steps, FontSize = 13, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
    words.Children.Add(Secondary(WhatsAppWords.NotEncrypted, wrap: true));
    return words;
  }

  // ---- the rows ----

  private void Draw()
  {
    addButton = saveKeyButton = null;
    var agents = store.Agents;
    if (editingId is not null && agents.All(a => a.Id != editingId)) { editingId = null; editing = Editing.None; }
    var lists = choices();
    var rows = new List<FrameworkElement>();
    foreach (var agent in agents)
      rows.Add(agent.Id == editingId && editing != Editing.None ? EditRow(agent) : AgentRow(agent, lists));
    rows.Add(adding ? AddForm() : AddClosed());
    holder.Child = SettingsPanel.GroupRows(rows);
  }

  private static Border Row(FrameworkElement content)
  {
    var row = new Border { Child = content, MinHeight = 44, Padding = new Thickness(12, 6, 12, 6) };
    AutomationProperties.SetAutomationId(row, "settings.row");
    return row;
  }

  internal static FrameworkElement Dot(WhatsAppDot dot)
  {
    var box = new Grid { Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Center };
    if (dot == WhatsAppDot.None) { AutomationProperties.SetAccessibilityView(box, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw); return box; }
    var circle = new Ellipse { Width = 7, Height = 7, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    circle.SetResourceReference(Shape.FillProperty, dot == WhatsAppDot.Green ? "DeckProjectGreenBrush" : "DeckProjectOrangeBrush");
    box.Children.Add(circle);
    var said = dot == WhatsAppDot.Green ? "Connected" : "The key was refused";
    AutomationProperties.SetName(box, said); ToolTipService.SetToolTip(box, said);
    return box;
  }

  private static TextBlock Secondary(string text, bool wrap = false)
  {
    var line = new TextBlock { Text = text, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis };
    line.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    return line;
  }

  private static TextBlock Orange(string text)
  {
    var line = new TextBlock { Text = text, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
    line.SetResourceReference(TextBlock.ForegroundProperty, "DeckProjectOrangeBrush");
    return line;
  }

  private FrameworkElement AgentRow(WhatsAppAgentProfile agent, WhatsAppReceiverChoices lists)
  {
    var look = WhatsAppRowLook.For(agent);
    var grid = new Grid { ColumnSpacing = 10 };
    foreach (var width in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto, GridLength.Auto })
      grid.ColumnDefinitions.Add(new() { Width = width });
    grid.Children.Add(Dot(look.Dot));
    var name = new TextBlock { Text = look.Name, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    Grid.SetColumn(name, 1); grid.Children.Add(name);
    if (look.Refused is { } refused) { var orange = Orange(refused); orange.TextWrapping = TextWrapping.NoWrap; Grid.SetColumn(orange, 3); grid.Children.Add(orange); }
    else
    {
      if (look.Secondary is { } words) { var said = Secondary(words); said.MaxWidth = 220; Grid.SetColumn(said, 2); grid.Children.Add(said); }
      var popUp = ReceiverPopUp(agent, lists); Grid.SetColumn(popUp, 3); grid.Children.Add(popUp);
    }
    var more = MoreButton(RowMenu(agent), agent.Name); Grid.SetColumn(more, 4); grid.Children.Add(more);
    var row = Row(grid);
    AutomationProperties.SetName(row, agent.Name);
    return row;
  }

  /// Where it is received. Choosing moves it there at once; no question.
  private DropDownButton ReceiverPopUp(WhatsAppAgentProfile agent, WhatsAppReceiverChoices lists)
  {
    var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Bottom };
    foreach (var line in lists.Lines(agent.Receiver))
    {
      switch (line.Kind)
      {
        case WhatsAppPopUpLineKind.Separator: menu.Items.Add(new MenuFlyoutSeparator()); break;
        case WhatsAppPopUpLineKind.Header: menu.Items.Add(new MenuFlyoutItem { Text = line.Text, IsEnabled = false }); break;
        default:
          var item = new ToggleMenuFlyoutItem { Text = line.Text, IsChecked = line.Checked };
          var tag = line.Tag;
          item.Click += async (_, _) =>
          {
            var next = lists.Receiver(tag, agent.Receiver);
            if (next.SameTarget(agent.Receiver)) { Draw(); return; }
            await store.SetReceiverAsync(agent.Id, next);
          };
          menu.Items.Add(item);
          break;
      }
    }
    var popUp = new DropDownButton { Content = new TextBlock { Text = agent.Receiver.Title, MaxWidth = 180, TextTrimming = TextTrimming.CharacterEllipsis }, Flyout = menu, FontSize = 13, MinHeight = 28, Padding = new Thickness(8, 2, 8, 2), VerticalAlignment = VerticalAlignment.Center };
    AutomationProperties.SetName(popUp, "Where " + agent.Name + " is received");
    ToolTipService.SetToolTip(popUp, "Where " + agent.Name + " is received");
    return popUp;
  }

  /// The row's "…" menu: Pause / Resume first, Rename, Replace key, then Remove (one press, no question).
  internal MenuFlyout RowMenu(WhatsAppAgentProfile agent)
  {
    var menu = new MenuFlyout();
    foreach (var text in WhatsAppRowLook.For(agent).Menu)
    {
      if (text == WhatsAppRowLook.MenuSeparator) { menu.Items.Add(new MenuFlyoutSeparator()); continue; }
      var item = new MenuFlyoutItem { Text = text };
      item.Click += async (_, _) =>
      {
        switch (text)
        {
          case WhatsAppWords.Pause or WhatsAppWords.Resume: await store.SetSendingAsync(!agent.Sending, agent.Id); break;
          case WhatsAppWords.Rename: BeginEdit(agent, Editing.Name); break;
          case WhatsAppWords.ReplaceKey: BeginEdit(agent, Editing.Key); break;
          case WhatsAppWords.Remove: await store.RemoveAsync(agent.Id); break;
        }
      };
      menu.Items.Add(item);
    }
    return menu;
  }

  internal static Button MoreButton(MenuFlyout menu, string name)
  {
    var more = new Button { Content = new DeckIcon { Glyph = "", FontSize = 13 }, Flyout = menu, Padding = new Thickness(6), MinWidth = 28, MinHeight = 28, VerticalAlignment = VerticalAlignment.Center };
    more.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
    more.SetResourceReference(Control.ForegroundProperty, "DeckSecondaryInkBrush");
    var label = "Actions for " + name;
    AutomationProperties.SetName(more, label); ToolTipService.SetToolTip(more, label);
    return more;
  }

  // ---- Rename and Replace key, in place ----

  private void BeginEdit(WhatsAppAgentProfile agent, Editing what)
  {
    store.Problem = null;
    editingId = agent.Id; editing = what; editText = what == Editing.Name ? agent.Name : "";
    focusAfterDraw = true; Draw();
  }

  private void CancelEdit() { editingId = null; editing = Editing.None; editText = ""; store.Problem = null; Draw(); }

  private FrameworkElement EditRow(WhatsAppAgentProfile agent)
  {
    var line = new Grid { ColumnSpacing = 8 };
    var column = new StackPanel();
    Control field;
    if (editing == Editing.Name)
    {
      foreach (var width in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto })
        line.ColumnDefinitions.Add(new() { Width = width });
      var box = new TextBox { Text = editText, Width = 200, MaxLength = WhatsAppAgentsLimits.MaximumNameLength, PlaceholderText = "Name", VerticalAlignment = VerticalAlignment.Center };
      AutomationProperties.SetName(box, "New name for " + agent.Name);
      box.TextChanged += (_, _) => editText = box.Text;
      box.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; _ = SaveNameAsync(agent); } else if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; CancelEdit(); } };
      line.Children.Add(box); field = box;
      var save = Small("Save", () => _ = SaveNameAsync(agent)); Grid.SetColumn(save, 2); line.Children.Add(save);
      var cancel = Small("Cancel", CancelEdit); Grid.SetColumn(cancel, 3); line.Children.Add(cancel);
    }
    else
    {
      foreach (var width in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto, GridLength.Auto })
        line.ColumnDefinitions.Add(new() { Width = width });
      var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
      label.Children.Add(Dot(WhatsAppRowLook.For(agent).Dot));
      label.Children.Add(new TextBlock { Text = agent.Name, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 140 });
      line.Children.Add(label);
      var key = new PasswordBox { Password = editText, Width = 200, PlaceholderText = WhatsAppWords.KeyPrompt, VerticalAlignment = VerticalAlignment.Center };
      AutomationProperties.SetName(key, "New key for " + agent.Name);
      key.PasswordChanged += (_, _) => editText = key.Password;
      key.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; _ = SaveKeyAsync(agent); } else if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; CancelEdit(); } };
      Grid.SetColumn(key, 2); line.Children.Add(key); field = key;
      saveKeyButton = Small("Save", () => _ = SaveKeyAsync(agent)); saveKeyButton.IsEnabled = !store.Checking; Grid.SetColumn(saveKeyButton, 3); line.Children.Add(saveKeyButton);
      var cancel = Small("Cancel", CancelEdit); Grid.SetColumn(cancel, 4); line.Children.Add(cancel);
    }
    column.Children.Add(line);
    if (store.Problem is { } problem) { var said = Orange(problem); said.Margin = new Thickness(0, 4, 0, 2); column.Children.Add(said); }
    Focus(field);
    return Row(column);
  }

  private async Task SaveNameAsync(WhatsAppAgentProfile agent)
  {
    var typed = editText.Trim();
    if (typed.Length == 0) return;
    if (typed == agent.Name) { CancelEdit(); return; }
    if (await store.RenameAsync(agent.Id, typed)) { editingId = null; editing = Editing.None; editText = ""; }
    Draw();
  }

  private async Task SaveKeyAsync(WhatsAppAgentProfile agent)
  {
    var key = editText.Trim();
    if (key.Length == 0 || store.Checking) return;
    // A refused key keeps the field and says so in one orange line.
    if (await store.ReplaceKeyAsync(agent.Id, key)) { editingId = null; editing = Editing.None; editText = ""; }
    else focusAfterDraw = true;
    Draw();
  }

  // ---- the last row: "+ Add WhatsApp agent" ----

  private FrameworkElement AddClosed()
  {
    var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    label.Children.Add(new DeckIcon { Glyph = "", FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
    label.Children.Add(new TextBlock { Text = WhatsAppWords.AddRow, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
    var open = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(12, 10, 12, 10) };
    open.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
    AutomationProperties.SetName(open, WhatsAppWords.AddRow); AutomationProperties.SetAutomationId(open, "aiApps.whatsapp.add");
    open.Click += (_, _) => { Begin(); Draw(); };
    return open;
  }

  private void Begin()
  {
    store.Problem = null;
    addName = store.NextDefaultName; addKey = ""; adding = true; focusAfterDraw = true;
  }

  private void Close() { adding = false; addKey = ""; store.Problem = null; Draw(); }

  private bool CanAdd() => !store.Checking && addKey.Trim().Length > 0;

  private FrameworkElement AddForm()
  {
    var line = new Grid { ColumnSpacing = 8 };
    foreach (var width in new[] { GridLength.Auto, GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto })
      line.ColumnDefinitions.Add(new() { Width = width });
    var name = new TextBox { Text = addName, Width = 160, MaxLength = WhatsAppAgentsLimits.MaximumNameLength, PlaceholderText = "Name", VerticalAlignment = VerticalAlignment.Center };
    AutomationProperties.SetName(name, "Name of the WhatsApp agent"); AutomationProperties.SetAutomationId(name, "aiApps.whatsapp.name");
    name.TextChanged += (_, _) => addName = name.Text;
    var key = new PasswordBox { Password = addKey, Width = 230, PlaceholderText = WhatsAppWords.KeyPrompt, VerticalAlignment = VerticalAlignment.Center };
    AutomationProperties.SetName(key, WhatsAppWords.KeyPrompt); AutomationProperties.SetAutomationId(key, "aiApps.whatsapp.key");
    var add = Small(WhatsAppWords.Add, () => _ = AddAsync());
    AutomationProperties.SetAutomationId(add, "aiApps.whatsapp.addButton");
    addButton = add; add.IsEnabled = CanAdd();
    key.PasswordChanged += (_, _) => { addKey = key.Password; add.IsEnabled = CanAdd(); };
    void Keys(object sender, KeyRoutedEventArgs e)
    {
      if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; _ = AddAsync(); }
      else if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; Close(); }
    }
    name.KeyDown += Keys; key.KeyDown += Keys;
    line.Children.Add(name);
    Grid.SetColumn(key, 1); line.Children.Add(key);
    Grid.SetColumn(add, 3); line.Children.Add(add);
    var column = new StackPanel();
    column.Children.Add(line);
    if (store.Problem is { } problem) { var said = Orange(problem); said.Margin = new Thickness(0, 4, 0, 2); AutomationProperties.SetAutomationId(said, "aiApps.whatsapp.problem"); column.Children.Add(said); }
    Focus(key);
    return Row(column);
  }

  private async Task AddAsync()
  {
    var key = addKey.Trim();
    if (key.Length == 0 || store.Checking) return;
    // A refused key says so in one orange line and keeps the fields.
    if (await store.AddAsync(addName.Trim(), key)) { adding = false; addKey = ""; addName = ""; }
    else focusAfterDraw = true;
    Draw();
  }

  /// The picture proof types a key and presses Add (the same path as Enter).
  internal Task ProofAddAsync(string key) { addKey = key; return AddAsync(); }

  private void Focus(Control field)
  {
    if (!focusAfterDraw) return;
    focusAfterDraw = false;
    field.Loaded += (_, _) => field.Focus(FocusState.Programmatic);
  }

  private static Button Small(string text, Action click)
  {
    var button = new Button { Content = text, FontSize = 12, MinHeight = 28, Padding = new Thickness(10, 2, 10, 2), VerticalAlignment = VerticalAlignment.Center };
    button.Click += (_, _) => click();
    return button;
  }
}
