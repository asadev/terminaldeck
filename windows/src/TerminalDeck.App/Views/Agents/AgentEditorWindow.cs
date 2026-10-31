using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Agents;
using Windows.Graphics;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Agents;

// A role has one editor even when several profiles or windows link to it. The
// service instance keeps scratch data and the person's running app separate.
internal static class AgentEditorWindow
{
  private sealed record Entry(Window Window, Action<string?> Focus, TaskCompletionSource Closed);
  private static readonly Dictionary<(IAgents, string), Entry> open = [];
  private static readonly Dictionary<(IAgents, string), RectInt32> frames = [];
  internal static Window? Find(IAgents agents, string id) => open.GetValueOrDefault((agents, id))?.Window;
  public static bool FocusExisting(IAgents agents, string id, string? field)
  {
    if (!open.TryGetValue((agents, id), out var entry)) return false;
    if (Environment.GetEnvironmentVariable("TD_W12_OFFSCREEN") != "1") entry.Window.Activate();
    entry.Focus(field); return true;
  }
  public static Task ShowAsync(IAgents agents, string id, string title, XamlRoot owner, StackPanel form, Action<string?> focus, string? field, Func<Task<bool>> save)
  {
    if (FocusExisting(agents, id, field)) return open[(agents, id)].Closed.Task;
    var window = new Window { Title = title };
    var content = new Grid { Style = PageStyle(), RequestedTheme = owner.Content is FrameworkElement source ? source.ActualTheme : ElementTheme.Default };
    content.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) }); content.RowDefinitions.Add(new() { Height = GridLength.Auto });
    form.Margin = new Thickness(24); form.MinWidth = 0;
    var inputs = new ContentControl { Content = PageScroll(form), HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch }; content.Children.Add(inputs);
    var footer = Stack(8); footer.Orientation = Orientation.Horizontal; footer.HorizontalAlignment = HorizontalAlignment.Right; footer.Margin = new Thickness(24, 8, 24, 16);
    var saving = false;
    var progress = new ProgressBar { IsIndeterminate = true, Width = 80, Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center }; footer.Children.Add(progress);
    var cancel = Button("Cancel", window.Close);
    async Task Save()
    {
      if (saving) return; saving = true; progress.Visibility = Visibility.Visible; inputs.IsEnabled = false; cancel.IsEnabled = false;
      var close = false;
      try { close = await save(); } finally { saving = false; progress.Visibility = Visibility.Collapsed; inputs.IsEnabled = true; cancel.IsEnabled = true; }
      if (close) window.Close();
    }
    var saveButton = AsyncButton("Save", Save, true);
    var shortcut = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = Windows.System.VirtualKey.S, Modifiers = Windows.System.VirtualKeyModifiers.Control, ScopeOwner = content };
    shortcut.Invoked += async (_, e) => { if (!content.IsLoaded) return; e.Handled = true; await Save(); }; content.KeyboardAccelerators.Add(shortcut);
    footer.Children.Add(cancel); footer.Children.Add(saveButton); Grid.SetRow(footer, 1); content.Children.Add(footer); window.Content = content;
    var key = (agents, id); var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    open.Add(key, new(window, focus, closed));
    if (frames.TryGetValue(key, out var bounds)) window.AppWindow.MoveAndResize(bounds); else window.AppWindow.Resize(new SizeInt32(660, 820));
    var ownerElement = owner.Content as FrameworkElement;
    void ThemeChanged(FrameworkElement sender, object args) => content.RequestedTheme = sender.ActualTheme;
    if (ownerElement is not null) ownerElement.ActualThemeChanged += ThemeChanged;
    window.AppWindow.Closing += (_, e) => { if (saving) e.Cancel = true; };
    window.Closed += (_, _) =>
    {
      frames[key] = new RectInt32(window.AppWindow.Position.X, window.AppWindow.Position.Y, window.AppWindow.Size.Width, window.AppWindow.Size.Height);
      open.Remove(key); if (ownerElement is not null) ownerElement.ActualThemeChanged -= ThemeChanged; closed.TrySetResult();
    };
    content.Loaded += (_, _) => focus(field);
    if (Environment.GetEnvironmentVariable("TD_W12_OFFSCREEN") == "1") { window.AppWindow.Move(new PointInt32(-20000, -20000)); window.AppWindow.Show(false); }
    else window.Activate();
    return closed.Task;
  }
}
