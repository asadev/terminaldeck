using TerminalDeck.App.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.App.Views.Tasks;

public sealed partial class TasksPage
{
  private bool fullTask;
  private string? popupEditorTask;
  public bool PopupExpanded => fullTask;
  public void SetPopupExpanded(bool value) => fullTask = value;
  private FrameworkElement TaskPopup(DeckTask task)
  {
    var overlay = new Grid { TabFocusNavigation = KeyboardNavigationMode.Cycle };
    overlay.SetResourceReference(BackgroundProperty, "DeckModalScrimBrush");
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(overlay, "tasks.popup");
    var popup = new Border { CornerRadius = new CornerRadius(12), Margin = new Thickness(fullTask ? 0 : 16), MaxWidth = fullTask ? double.PositiveInfinity : 1440, MaxHeight = fullTask ? double.PositiveInfinity : 900,
      HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch,
      Shadow = new ThemeShadow(), Translation = new System.Numerics.Vector3(0, 0, 32) };
    popup.SetResourceReference(Border.BackgroundProperty, fullTask ? "DeckCanvasBrush" : "DeckGlassBrush");
    popup.BorderThickness = new Thickness(fullTask ? 0 : 1);
    popup.SetResourceReference(Border.BorderBrushProperty, "DeckMaterialSheenBrush");
    popup.Child = new TaskDetailPage(Model, task.Id, navigation, () => { fullTask = !fullTask; Render(); }, open =>
    {
      if (open) popupEditorTask = task.Id;
      else if (popupEditorTask == task.Id) popupEditorTask = null;
      if (!open) DispatcherQueue.TryEnqueueHandled(Render);
    });
    RoundedContentClip.Attach(popup);
    overlay.Children.Add(popup);
    overlay.PointerPressed += (_, e) => { if (ReferenceEquals(e.OriginalSource, overlay)) Model.Select(null); };
    overlay.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Escape) { if (Model.EditingTitle) Model.CancelRename(); else Model.Select(null); e.Handled = true; } };

    return overlay;
  }
}
