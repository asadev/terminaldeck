using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.WhatsApp;

namespace TerminalDeck.App.Views.WhatsApp;

// Switching from where he is (DESIGN-WHATSAPP section 3; the Mac's NativeWhatsAppSubmenu and NativeWhatsAppChip).
// The "WhatsApp" submenu goes into menus that already exist (a session row's right-click and the session's "…", an
// agent's menu, Hoot's settings menu); no new button anywhere. The heading chip and its mini switch show ONLY while a
// WhatsApp agent is attached to that page. Session rows get nothing.
public static class WhatsAppMenus
{
  /// Opens Settings > AI apps (the shell sets it once); used by the submenu's "Add a WhatsApp agent…".
  public static Func<Task>? OpenSettings { get; set; }

  /// Hoot's page and the Agents page are also compiled into proofs that do not carry these screens, so they take the
  /// submenu and the chip through hooks the shell sets here, once.
  public static void InstallPageHooks()
  {
    Hoot.HootPage.WhatsAppSubmenu = menu => Submenu(WhatsAppReceiver.Hoot, refreshOn: menu);
    Hoot.HootPage.WhatsAppChip = () => new WhatsAppChip(WhatsAppReceiver.Hoot);
    Agents.AgentsPage.WhatsAppSubmenu = (agent, menu) => Submenu(WhatsAppReceiver.Agent(agent.Id, agent.Name), refreshOn: menu);
    Agents.AgentsPage.WhatsAppChip = agent => new WhatsAppChip(WhatsAppReceiver.Agent(agent.Id, agent.Name), separated: false);
  }

  /// "WhatsApp ›" for a menu: filled now and again each time the menu opens (it may be built long before).
  public static MenuFlyoutSubItem Submenu(WhatsAppReceiver here, WhatsAppAgentsStore? store = null, MenuFlyout? refreshOn = null)
  {
    var sub = new MenuFlyoutSubItem { Text = WhatsAppWords.SubmenuTitle };
    AutomationProperties.SetAutomationId(sub, "whatsapp.submenu");
    Fill(sub.Items, here, store ?? WhatsAppAgentsStore.Shared);
    if (refreshOn is not null) refreshOn.Opening += (_, _) => Fill(sub.Items, here, store ?? WhatsAppAgentsStore.Shared);
    return sub;
  }

  /// The items, used by the submenu and by the chip's own list.
  public static void Fill(IList<MenuFlyoutItemBase> items, WhatsAppReceiver here, WhatsAppAgentsStore store)
  {
    items.Clear();
    foreach (var entry in WhatsAppMenu.Entries(store.Agents, here))
    {
      switch (entry.Kind)
      {
        case WhatsAppMenuEntryKind.Separator: items.Add(new MenuFlyoutSeparator()); break;
        case WhatsAppMenuEntryKind.AddAgent:
          var add = new MenuFlyoutItem { Text = entry.Text };
          add.Click += async (_, _) => { if (OpenSettings is { } open) await open(); };
          items.Add(add);
          break;
        case WhatsAppMenuEntryKind.Off:
          var off = new MenuFlyoutItem { Text = entry.Text, IsEnabled = entry.Enabled };
          off.Click += async (_, _) => await WhatsAppMenu.PerformAsync(entry, here, store);
          items.Add(off);
          break;
        default:
          var item = new ToggleMenuFlyoutItem { Text = entry.Text, IsChecked = entry.Checked };
          item.Click += async (_, _) => await WhatsAppMenu.PerformAsync(entry, here, store);
          items.Add(item);
          break;
      }
    }
  }
}

/// The heading chip: the WhatsApp glyph and the agent's name (secondary colour while its switch is off), a click opens
/// the same list; right after it one mini switch without a label ("Send to WhatsApp"). Nothing at all when no WhatsApp
/// agent is attached here. It follows the store by itself.
public sealed class WhatsAppChip : StackPanel
{
  private readonly WhatsAppReceiver here;
  private readonly WhatsAppAgentsStore store;
  private readonly bool separated;
  private WhatsAppChipLook? shown;
  private bool drawn;

  public WhatsAppChip(WhatsAppReceiver here, WhatsAppAgentsStore? store = null, bool separated = true)
  {
    this.here = here; this.store = store ?? WhatsAppAgentsStore.Shared; this.separated = separated;
    Orientation = Orientation.Horizontal; Spacing = 5; VerticalAlignment = VerticalAlignment.Center;
    AutomationProperties.SetAutomationId(this, "whatsapp.chip");
    Draw();
    Loaded += (_, _) => { this.store.Changed += Later; Draw(); };
    Unloaded += (_, _) => this.store.Changed -= Later;
  }

  private void Later() => DispatcherQueue?.TryEnqueue(Draw);

  private void Draw()
  {
    var look = WhatsAppChipLook.For(store.Agents, here);
    if (drawn && look == shown) return;
    drawn = true; shown = look;
    Children.Clear();
    Visibility = look is null ? Visibility.Collapsed : Visibility.Visible;
    if (look is null) return;
    if (separated) Children.Add(new TextBlock { Text = "·", VerticalAlignment = VerticalAlignment.Center });

    var glyph = new DeckIcon { Glyph = "whatsapp", FontSize = 10.5, VerticalAlignment = VerticalAlignment.Center };
    glyph.SetResourceReference(Control.ForegroundProperty, look.Sending ? "DeckSidebarSelectionInkBrush" : "DeckSecondaryInkBrush");
    var list = DeckMenu.CreateFor(this);
    void Fill()
    {
      WhatsAppMenus.Fill(list.Items, here, store);
      // Sending is the first choice; selecting an agent follows it.
      var send = list.Items.OfType<ToggleMenuFlyoutItem>().FirstOrDefault(i => i.Text == WhatsAppWords.Send);
      if (send is not null) { list.Items.Remove(send); list.Items.Insert(0, send); list.Items.Insert(1, new MenuFlyoutSeparator()); }
    }
    list.Opening += (_, _) => Fill(); Fill();
    var chip = new Button { Content = glyph, Flyout = list, Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"], Width = 18, MinWidth = 18, Height = 18, MinHeight = 18, Padding = new(0), CornerRadius = new(5), VerticalAlignment = VerticalAlignment.Center, BorderThickness = new(look.Sending ? 0 : 0.5) };
    chip.SetResourceReference(Control.BackgroundProperty, look.Sending ? "AccentFillColorDefaultBrush" : "DeckTransparentBrush");
    chip.SetResourceReference(Control.BorderBrushProperty, "DeckSecondaryInkBrush");
    ToolTipService.SetToolTip(chip, look.Help); AutomationProperties.SetName(chip, "WhatsApp: " + look.Name + (look.Sending ? ", sending" : ", off"));
    AutomationProperties.SetAutomationId(chip, "whatsapp.chip.button");
    Children.Add(chip);
  }
}
