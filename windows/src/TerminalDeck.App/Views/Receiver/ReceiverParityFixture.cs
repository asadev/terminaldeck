using System.Text.Json;
using Microsoft.UI.Xaml;
using TerminalDeck.App.ViewModels.Receiver;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Views.Receiver;

// In-memory, synthetic fixtures: no keeper, intake listener, clipboard, or live data.
internal static class ReceiverParityFixture
{
  internal static FrameworkElement Inbox()
  {
    var receiver = Store();
    var model = new ReceiverViewModel(receiver, new Settings()) { SelectedId = "event-1" };
    return new ReceiverPage(model, [("studio", "Studio"), ("docs", "Documentation")]);
  }
  internal static FrameworkElement Artifacts() => new ArtifactsPage(new Catalog(), Store(), [new("fixture-studio", "Studio", "studio"), new("fixture-docs", "Documentation", "docs")]);
  private static ReceiverStore Store()
  {
    var at = new DateTimeOffset(2026, 10, 29, 15, 30, 0, TimeSpan.Zero);
    var sources = new ReceiverSource[] { new("browser", "Browser", IntakeKind.Browser, "studio"), new("phone", "Phone", IntakeKind.Phone, "studio"), new("report", "Reports", IntakeKind.Report, "docs") };
    var titles = new[] { "Homepage layout feedback", "Screenshot from phone", "Documentation build complete", "Preview link for review", "Release notes draft" };
    var items = titles.Select((title, i) => new ReceiverItem($"event-{i + 1}", sources[i % 3].Id, sources[i % 3].ProjectId, at.AddMinutes(-i * 16), title,
      i == 0 ? "The new homepage is ready for review. Please check the header spacing and the mobile navigation." : "Shared content is waiting for review.", null, [], $"fixture-{i}", i == 2 ? InboxStatus.Delivered : InboxStatus.Unrouted,
      i == 2 ? new(RouteKind.Session, "design") : null, Trail: [new(at.AddMinutes(-i * 16), "Received from source")]) { Payload = i == 0 ? JsonSerializer.SerializeToElement(new { build = new { status = "failed", seconds = 42 } }) : null }).Reverse().ToArray();
    return new ReceiverStore(new Memory<ReceiverState>(new([.. sources], [], [.. items])), new Delivery());
  }
  private sealed class Memory<T>(T value) : IStateStore<T>
  {
    public T? Load() => value;
    public void Save(T state) => value = state;
  }
  private sealed class Delivery : IReceiverDelivery
  {
    public IReadOnlyList<ReceiverDestination> Destinations() => [new(new(RouteKind.Session, "design"), "Design review", "studio"), new(new(RouteKind.Hoot), "Hoot", "studio")];
    public ValueTask<DeliveryReceipt> DeliverAsync(ReceiverItem item, ReceiverTarget target, string deliveryId, CancellationToken ct) => throw new InvalidOperationException("Visual fixture only.");
  }
  private sealed class Settings : IReceiverIntakeSettings
  {
    public ReceiverIntakeStatus Status => new(false, false, null);
    public ValueTask ConfigureAsync(bool? clipboard, bool? browser, CancellationToken ct = default) => throw new InvalidOperationException("Visual fixture only.");
  }
  private sealed class Catalog : IReceiverArtifacts
  {
    public event Action? Changed { add { } remove { } }
    public IReadOnlyList<ReceiverArtifact> List(string cwd, string? path = null, int limit = 300)
    {
      var names = cwd == "fixture-studio" ? new[] { "pages/homepage.html", "design/wireframe.svg", "pages/design-review.html", "video/walkthrough.webm" } : new[] { "docs/release-notes.pdf", "docs/setup-guide.pdf", "reports/test-results.html" };
      return names.Select((name, i) => new ReceiverArtifact(cwd + i, cwd == "fixture-studio" ? "studio" : "docs", cwd, name, "Design review", new DateTimeOffset(2026, 10, 29, 14, 30, 0, TimeSpan.Zero).AddDays(i > 1 ? -1 : 0).AddMinutes(-i * 25))).ToArray();
    }
    public ArtifactPreview Preview(string cwd, string relPath) => new(List(cwd).First(a => a.RelPath == relPath), "text/plain", "Synthetic artifact preview for layout review.", null, false);
    public ValueTask OpenAsync(string cwd, string relPath, CancellationToken ct = default) => throw new InvalidOperationException("Visual fixture only.");
    public ValueTask SendAsync(string cwd, string relPath, ReceiverTarget target, CancellationToken ct = default) => throw new InvalidOperationException("Visual fixture only.");
    public void Remove(string cwd, string relPath) => throw new InvalidOperationException("Visual fixture only.");
  }
}
