using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Quality;
using static TerminalDeck.App.Views.Servers.ServerUi;

namespace TerminalDeck.App.Views.Quality;

public sealed partial class StaysFixedPage
{
  private void RenderResult(JsonElement envelope, string action)
  {
    var value = envelope;
    if (envelope.ValueKind == JsonValueKind.Object && envelope.TryGetProperty("result", out _))
      try { value = StaysFixedEvidence.Result(envelope); } catch (Exception error) when (error is IOException or JsonException) { notice.Text = error.Message; }
    if (value.ValueKind != JsonValueKind.Object) { Details(envelope); return; }
    string? Text(string key) => value.TryGetProperty(key, out var item) && item.ValueKind == JsonValueKind.String ? item.GetString() : null;
    var blocked = value.TryGetProperty("blocked", out var block) && block.ValueKind == JsonValueKind.True;
    var hasVerdict = value.TryGetProperty("ok", out var ok) && ok.ValueKind is JsonValueKind.True or JsonValueKind.False;
    var headline = Text("headline") ?? (blocked ? "Could not run the check" : action == "check" && hasVerdict ? ok.GetBoolean() ? "Check passed" : "Differences to review" : action switch { "doctor" or "coverage" => "What this PC can check", "preview" => "Review setup", "setup" => "Setup result", "repair" => "Finish setup", "mark-good" => "Good build result", "accept-diff" => "Reviewed difference", _ => "Check result" });
    var outcome = Section(headline);
    var summary = Text("summary") ?? Text("detail") ?? Text("error");
    if (!string.IsNullOrWhiteSpace(summary)) outcome.Children.Add(Words(summary, 13, true));
    if (Text("modeWarning") is { Length: > 0 } warning) Row(outcome, "Comparison coverage", warning);
    foreach (var buildKey in new[] { "reference", "candidate" }) if (value.TryGetProperty(buildKey, out var build) && build.ValueKind == JsonValueKind.Object && build.TryGetProperty("id", out var buildId)) Row(outcome, buildKey == "reference" ? "Good reference" : "Checked build", string.IsNullOrEmpty(buildId.ToString()) ? "No recorded build" : buildId.ToString());
    if (value.TryGetProperty("durationMs", out var duration) && duration.TryGetDouble(out var milliseconds)) outcome.Children.Add(Words("Elapsed " + TimeSpan.FromMilliseconds(Math.Max(0, milliseconds)).ToString(@"hh\:mm\:ss"), 12, true));
    foreach (var key in new[] { "checked", "unchanged", "notChecked", "referenceNote" })
      if (Text(key) is { Length: > 0 } text) Row(outcome, key switch { "notChecked" => "Not checked", "referenceNote" => "Good reference", "unchanged" => "Unchanged", _ => "Checked" }, text);
    if (value.TryGetProperty("coverage", out var coverage) && coverage.ValueKind == JsonValueKind.Object)
    {
      var section = Section("Checked");
      foreach (var key in new[] { "paths", "journeys" }) if (coverage.TryGetProperty(key, out var count)) Row(section, key == "paths" ? "Observed paths" : "Journeys", count.ToString());
      Rows(coverage, "gaps", "Not checked");
    }
    Rows(value, "surfaces", "What this PC can check"); Rows(value, "tools", "Tools"); Rows(value, "nextSteps", "What would unlock more");
    Rows(value, "findings", "Differences to review"); Rows(value, "differences", "Differences to review"); Rows(value, "gaps", "Not checked");
    Rows(value, "guards", "Rules that keep fixed bugs from returning"); Rows(value, "files", "Files to review"); Rows(value, "pictures", "Before and after evidence");
    if (value.TryGetProperty("project", out var project) && project.ValueKind == JsonValueKind.Object && project.TryGetProperty("referenceNote", out var reference)) Row(outcome, "Good reference", reference.ToString());
    Details(envelope);
  }
  private StackPanel Section(string title)
  {
    var section = new StackPanel { Spacing = 12 }; var heading = Words(title, 15); heading.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
    section.Children.Add(heading); report.Children.Add(section); return section;
  }
  private static void Row(StackPanel host, string title, string detail)
  {
    var row = new StackPanel { Spacing = 4 }; var heading = Words(title, 13); heading.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
    row.Children.Add(heading); row.Children.Add(Words(detail, 12, true)); host.Children.Add(row);
  }
  private void Rows(JsonElement owner, string key, string title)
  {
    if (!owner.TryGetProperty(key, out var items) || items.ValueKind != JsonValueKind.Array || items.GetArrayLength() == 0) return;
    var section = Section(title);
    foreach (var item in items.EnumerateArray().Take(200))
    {
      if (item.ValueKind != JsonValueKind.Object) { section.Children.Add(Words(item.ToString(), 13)); continue; }
      string? Get(string name) => item.TryGetProperty(name, out var field) && field.ValueKind is not JsonValueKind.Null and not JsonValueKind.Undefined ? field.ToString() : null;
      var heading = Get("title") ?? Get("name") ?? Get("what") ?? Get("path") ?? Get("id") ?? title;
      var content = new StackPanel { Spacing = 8 };
      Row(content, heading, string.Join("\n", new[] { Get("summary"), Get("detail"), Get("why"), Get("because"), Get("status"), Get("state"), Get("fix"), Get("unlocks"), Get("instead") }.Where(s => !string.IsNullOrWhiteSpace(s))));
      foreach (var field in new[] { "before", "after", "reference", "candidate" })
        if (item.TryGetProperty(field, out var evidence)) { Row(content, field == "before" || field == "reference" ? "Before" : "After", evidence.ToString()); if (evidence.ValueKind == JsonValueKind.String) EvidenceImage(content, evidence.GetString()); }
      if (item.TryGetProperty("differences", out var differences) && differences.ValueKind == JsonValueKind.Array)
        foreach (var difference in differences.EnumerateArray().Take(200))
        {
          if (difference.ValueKind != JsonValueKind.Object) continue;
          var evidence = new StackPanel { Spacing = 8 };
          if (difference.TryGetProperty("path", out var path)) evidence.Children.Add(Words(path.ToString(), 13));
          foreach (var side in new[] { "before", "after", "was", "now" }) if (difference.TryGetProperty(side, out var observed)) { Row(evidence, side is "before" or "was" ? "Before" : "After", observed.ToString()); if (observed.ValueKind == JsonValueKind.String) EvidenceImage(evidence, observed.GetString()); }
          content.Children.Add(evidence);
        }
      section.Children.Add(Card(content));
    }
  }
  private void Details(JsonElement value) => report.Children.Add(new Expander { Header = "Details", IsExpanded = false, HorizontalAlignment = HorizontalAlignment.Stretch,
    Content = new TextBox { Text = JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true }), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontFamily = DeckFonts.Mono, FontSize = 12, MaxHeight = 480 } });
}
