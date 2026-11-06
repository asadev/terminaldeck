using TerminalDeck.App.Shell;
using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
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
  private readonly Reading cpu = new("This PC CPU", "DeckProjectBlueBrush"), memory = new("This PC memory", "DeckProjectGreenBrush");
  // One button per reading. Its card is built once and only its text changes,
  // and the ring is redrawn only when the rounded figure moves: every header
  // that is loaded (hidden tabs' too) hears each two-second sample.
  private sealed class Reading
  {
    public readonly Button Button = new();
    private readonly Grid ring = MeterRing.Create();
    private readonly TextBlock detail = new();
    private readonly string title, color;
    private double? drawn = double.NaN;
    public Reading(string title, string color)
    {
      this.title = title; this.color = color;
      MeterRing.Host(Button, MeterRing.Capsule(ring));
      AutomationProperties.SetName(Button, title + ": waiting for a reading");
      Button.Flyout = new Flyout { Content = new StackPanel { Spacing = 6, Children = { new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }, detail, new TextBlock { Text = "Whole computer · refreshed every 2 seconds while a session header is visible", MaxWidth = 260, TextWrapping = TextWrapping.Wrap } } } };
      Show(null, "Waiting for a reading");
    }
    public void Show(double? percent, string text)
    {
      var rounded = percent is { } p ? Math.Round(p) : (double?)null;
      if (rounded != drawn) { MeterRing.Draw(ring, rounded, color); drawn = rounded; }
      if (detail.Text == text) return;
      detail.Text = text; AutomationProperties.SetName(Button, title + ": " + text); ToolTipService.SetToolTip(Button, title + " · " + text);
    }
  }
  public DesktopResourceMeter(AppRuntime runtime)
  {
    sampler = samplers.GetValue(runtime, r => new(r)); Orientation = Orientation.Horizontal; Spacing = 4; VerticalAlignment = VerticalAlignment.Center;
    Children.Add(cpu.Button); Children.Add(memory.Button);
    Loaded += (_, _) => sampler.Attach(Changed);
    Unloaded += (_, _) => sampler.Detach(Changed);
  }
  private void Changed(JsonObject sample) => DispatcherQueue.TryEnqueue(() =>
  {
    var cpuPercent = Number(sample["cpu"]?["total"]);
    var used = Number(sample["memory"]?["used"]); var total = Number(sample["memory"]?["total"]);
    var memoryPercent = total is > 0 && used is not null ? used / total * 100 : null;
    cpu.Show(cpuPercent, cpuPercent is { } c ? c.ToString("0.0") + "% busy" : "Waiting for two readings");
    memory.Show(memoryPercent, used is { } u && total is { } t ? (u / 1073741824).ToString("0.0") + " / " + (t / 1073741824).ToString("0.0") + " GB" : "Memory reading unavailable");
  });
  private static double? Number(JsonNode? value) => value is not null && double.TryParse(value.ToJsonString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var number) && double.IsFinite(number) ? number : null;
}
