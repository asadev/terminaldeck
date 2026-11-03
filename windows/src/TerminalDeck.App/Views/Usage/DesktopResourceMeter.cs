using TerminalDeck.App.Shell;
using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TerminalDeck.App.Integration;
using TerminalDeck.Platform.Windows.Phone;

namespace TerminalDeck.App.Views.Usage;

// One sampler per app runtime, active only while a header is visible. CPU and
// RAM have no change event on Windows, so this bounded two-second cadence is
// shared by every split/detached header rather than one timer per session.
public sealed class DesktopResourceMeter : StackPanel
{
  private sealed class Sampler(AppRuntime runtime)
  {
    private readonly WindowsSystemActivity reader = new(() => [], runtime.Root.DirectoryPath);
    private readonly object gate = new();
    private Timer? timer;
    private int sampling;
    public event Action<JsonObject>? Changed;
    public void Attach(Action<JsonObject> listener)
    {
      lock (gate) { Changed += listener; timer ??= new Timer(_ => Sample(), null, TimeSpan.Zero, TimeSpan.FromSeconds(2)); }
    }
    public void Detach(Action<JsonObject> listener)
    {
      lock (gate) { Changed -= listener; if (Changed is null) { timer?.Dispose(); timer = null; } }
    }
    public JsonObject Read() => reader.Sample(false);
    private void Sample()
    {
      if (Interlocked.Exchange(ref sampling, 1) != 0) return;
      try { var sample = reader.Sample(false); Action<JsonObject>? listeners; lock (gate) listeners = Changed; listeners?.Invoke(sample); }
      finally { Volatile.Write(ref sampling, 0); }
    }
  }
  private static readonly ConditionalWeakTable<AppRuntime, Sampler> samplers = new();
  public static JsonObject Read(AppRuntime runtime) => samplers.GetValue(runtime, r => new(r)).Read();
  private readonly Sampler sampler;
  private readonly Button cpu = new(), memory = new();
  private readonly Grid cpuRing = new() { Width = 12, Height = 12 }, memoryRing = new() { Width = 12, Height = 12 };
  public DesktopResourceMeter(AppRuntime runtime)
  {
    sampler = samplers.GetValue(runtime, r => new(r)); Orientation = Orientation.Horizontal; Spacing = 6; VerticalAlignment = VerticalAlignment.Center;
    foreach (var (button, ring, name) in new[] { (cpu, cpuRing, "This PC CPU"), (memory, memoryRing, "This PC memory") })
    {
      button.Content = ring; button.Padding = new(6, 3, 6, 3); button.MinWidth = 0; button.MinHeight = 0;
      button.Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"];
      AutomationProperties.SetName(button, name + ": waiting for a reading");
      Children.Add(button);
    }
    Draw(cpuRing, null, "DeckProjectBlueBrush"); Draw(memoryRing, null, "DeckProjectGreenBrush");
    Loaded += (_, _) => sampler.Attach(Changed);
    Unloaded += (_, _) => sampler.Detach(Changed);
  }
  private void Changed(JsonObject sample) => DispatcherQueue.TryEnqueue(() =>
  {
    var cpuPercent = Number(sample["cpu"]?["total"]);
    var used = Number(sample["memory"]?["used"]); var total = Number(sample["memory"]?["total"]);
    var memoryPercent = total is > 0 && used is not null ? used / total * 100 : null;
    Update(cpu, cpuRing, "This PC CPU", cpuPercent, "DeckProjectBlueBrush", cpuPercent is { } c ? c.ToString("0.0") + "% busy" : "Waiting for two readings");
    Update(memory, memoryRing, "This PC memory", memoryPercent, "DeckProjectGreenBrush", used is { } u && total is { } t ? (u / 1073741824).ToString("0.0") + " / " + (t / 1073741824).ToString("0.0") + " GB" : "Memory reading unavailable");
  });
  private static double? Number(JsonNode? value) => value is not null && double.TryParse(value.ToJsonString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var number) && double.IsFinite(number) ? number : null;
  private static void Update(Button button, Grid ring, string title, double? percent, string color, string detail)
  {
    Draw(ring, percent, color); AutomationProperties.SetName(button, title + ": " + detail); ToolTipService.SetToolTip(button, title + " · " + detail);
    if (button.Flyout is Flyout { IsOpen: true }) return;
    button.Flyout = new Flyout { Content = new StackPanel { Spacing = 6, Children = { new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }, new TextBlock { Text = detail }, new TextBlock { Text = "Whole computer · refreshed every 2 seconds while a session header is visible", MaxWidth = 260, TextWrapping = TextWrapping.Wrap } } } };
  }
  internal static void Draw(Grid ring, double? percent, string color)
  {
    ring.Children.Clear();
    var track = new Ellipse { Width = 12, Height = 12, StrokeThickness = 2, Opacity = 0.3 }; track.SetResourceReference(Shape.StrokeProperty, color); ring.Children.Add(track);
    if (percent is not { } p || p <= 0) return;
    var fill = Math.Clamp(p / 100, 0, 1); var brush = (Brush)Application.Current.Resources[color];
    if (fill >= 0.999) { ring.Children.Add(new Ellipse { Width = 12, Height = 12, StrokeThickness = 2, Stroke = brush }); return; }
    var angle = fill * Math.PI * 2;
    var figure = new PathFigure { StartPoint = new(6, 1) };
    figure.Segments.Add(new ArcSegment { Point = new(6 + Math.Sin(angle) * 5, 6 - Math.Cos(angle) * 5), Size = new(5, 5), SweepDirection = SweepDirection.Clockwise, IsLargeArc = fill > 0.5 });
    var geometry = new PathGeometry(); geometry.Figures.Add(figure);
    ring.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Stroke = brush, StrokeThickness = 2, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round });
  }
}
