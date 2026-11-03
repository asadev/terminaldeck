using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using TerminalDeck.Core.Chats;
namespace TerminalDeck.App.Views.Chat;
public sealed partial class ChatPage
{
  private async Task ShowInspectorAsync()
  {
    var body = new StackPanel { Spacing = 12 };
    body.Children.Add(Words(Model.Snapshot.Definition.Title + "\nSource: recorded chat events · " + Model.Id, 12));
    var status = Words("", 12); var tabs = new Pivot(); var summary = new StackPanel { Spacing = 8 }; var timeline = new StackPanel { Spacing = 12 }; var usage = new StackPanel { Spacing = 8 }; var tools = new StackPanel { Spacing = 12 }; var context = new StackPanel { Spacing = 8 };
    foreach (var item in new[] { ("Summary", summary), ("Timeline", timeline), ("Usage", usage), ("Tools", tools), ("Context", context) }) tabs.Items.Add(new PivotItem { Header = item.Item1, Content = item.Item2 });
    var timelineLimit = 40; var toolLimit = 40;
    var refresh = Button("Refresh", async () => { status.Text = "Reading recorded data…"; await Model.RefreshRecordedAsync(); RenderReading(); });
    body.Children.Add(refresh); body.Children.Add(status); body.Children.Add(tabs);
    string Number(long? number) => number?.ToString("N0") ?? "Not reported";
    void RenderReading()
    {
      foreach (var panel in new[] { summary, timeline, usage, tools, context }) panel.Children.Clear();
      var report = ChatInspector.Read(Model.Snapshot); var contextReport = ChatContext.Read(Model.Snapshot); status.Text = Model.Error ?? "Recorded data through event " + (Model.Snapshot.Events.LastOrDefault()?.Sequence ?? 0);
      summary.Children.Add(Words("Requests: " + (report.Requests.Length == 0 ? "Not reported" : report.Requests.Length.ToString()) + "\nPrompt (fresh input): " + Number(report.FreshInput) + "\nOutput: " + Number(report.Output) + "\nTools: " + report.Tools.Length + "\nContext window: Not reported\nElapsed: per-request recorded times below."));
      summary.Children.Add(Words("Recorded prompts: " + report.RecordedPrompts + " · recorded answers: " + report.RecordedAnswers + " · provider turn usage reports: " + report.ProviderTurnReports, 12));
      timeline.Children.Add(Words(report.Requests.Length + " recorded requests", 12));
      if (report.Requests.Length > timelineLimit) timeline.Children.Add(Button("Show earlier requests", () => { timelineLimit += 40; RenderReading(); return Task.CompletedTask; }));
      foreach (var request in report.Requests.TakeLast(timelineLimit))
      {
        var elapsed = request.FirstAt != default && request.LastAt >= request.FirstAt ? (request.LastAt - request.FirstAt).TotalSeconds.ToString("N1") + "s" : "Not reported";
        timeline.Children.Add(Words(request.Model + "\nRequest: " + request.Id + "\nFresh input " + Number(request.FreshInput) + " · output " + Number(request.Output) + "\nCache writes " + Number(request.CacheWrite) + " · reads " + Number(request.CacheRead) + "\nElapsed between recorded events: " + elapsed, 12));
      }
      foreach (var entry in Model.Snapshot.Events.Where(e => e.Kind == "compaction").TakeLast(40)) timeline.Children.Add(Words("Context compaction · " + entry.At.ToLocalTime().ToString("g"), 12));
      if (report.Requests.Length == 0) timeline.Children.Add(Words("No per-request usage has been recorded. Turn totals are available separately in Usage report when the provider reports them."));
      usage.Children.Add(Words("Fresh input: " + Number(report.FreshInput) + "\nOutput: " + Number(report.Output) + "\nCache writes: " + Number(report.CacheWrite) + "\nCache reads: " + Number(report.CacheRead)));
      usage.Children.Add(Words("Each request ID is counted once. Streaming updates replace cumulative fields; turn totals are kept separate. These figures are not your bill.", 12));
      if (report.FreshInput.HasValue && report.Output.HasValue && report.CacheWrite.HasValue && report.CacheRead.HasValue)
      {
        var total = (decimal)report.FreshInput.Value + report.Output.Value + report.CacheWrite.Value + report.CacheRead.Value;
        var inputTotal = (decimal)report.FreshInput.Value + report.CacheWrite.Value + report.CacheRead.Value;
        usage.Children.Add(Words("Cache-hit share of recorded input: " + (inputTotal > 0 ? ((decimal)report.CacheRead.Value / inputTotal * 100).ToString("N1") + "%" : "No input recorded"), 12));
        foreach (var share in new[] { ("Output", report.Output.Value, "DeckProjectPurpleBrush"), ("Cache writes", report.CacheWrite.Value, "DeckProjectOrangeBrush"), ("Cache reads", report.CacheRead.Value, "DeckProjectGreenBrush"), ("Fresh input", report.FreshInput.Value, "DeckProjectBlueBrush") })
        {
          usage.Children.Add(Words(share.Item1 + " · " + share.Item2.ToString("N0") + (total > 0 ? " · " + ((decimal)share.Item2 / total * 100).ToString("N1") + "%" : ""), 12));
          usage.Children.Add(new ProgressBar { Minimum = 0, Maximum = Math.Max(1, (double)total), Value = share.Item2, Height = 6, Style = (Style)XamlReader.Load($"<Style xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" TargetType=\"ProgressBar\"><Setter Property=\"Foreground\" Value=\"{{ThemeResource {share.Item3}}}\"/></Style>") });
        }
      }
      string ModelTokens(IEnumerable<long?> values)
      { var entries = values.ToArray(); return entries.Any(v => !v.HasValue) ? "Not reported" : entries.Sum(v => (decimal)v!.Value).ToString("N0"); }
      foreach (var group in report.Requests.GroupBy(r => r.Model)) usage.Children.Add(Words(group.Key + " · " + group.Count() + " requests\nFresh input " + ModelTokens(group.Select(r => r.FreshInput)) + " · output " + ModelTokens(group.Select(r => r.Output)) + " · cache writes " + ModelTokens(group.Select(r => r.CacheWrite)) + " · cache reads " + ModelTokens(group.Select(r => r.CacheRead)), 12));
      tools.Children.Add(Words(report.Tools.Length + " calls · " + report.Tools.Count(t => t.Failed) + " reported failures · " + report.Tools.Select(t => t.Name).Distinct().Count() + " distinct tools", 12));
      if (report.Tools.Length > toolLimit) tools.Children.Add(Button("Show earlier tools", () => { toolLimit += 40; RenderReading(); return Task.CompletedTask; }));
      foreach (var tool in report.Tools.TakeLast(toolLimit)) tools.Children.Add(new Expander { Header = tool.Name + (tool.Failed ? " · Failed" : "") + (tool.ElapsedSeconds.HasValue ? " · " + tool.ElapsedSeconds.Value.ToString("N1") + "s" : ""), Content = Words("Recorded ID: " + tool.Id + "\nInput\n" + tool.Input + "\nOutput\n" + tool.Output, 12), HorizontalAlignment = HorizontalAlignment.Stretch });
      if (report.Tools.Length == 0) tools.Children.Add(Words("No tools have been called in the recorded chat."));
      context.Children.Add(Words("Current window: " + Number(contextReport.Window) + "\nReported context tokens: " + Number(contextReport.Tokens) + "\nRemaining context: " + Number(contextReport.Remaining) + "\nContext used: " + (contextReport.Percent?.ToString("N1") is { } percent ? percent + "%" : "Not reported") + "\nPeak recorded context tokens: " + Number(contextReport.PeakRecordedTokens) + "\nFirst-request cost: Not reported\nRecorded compactions: " + contextReport.RecordedCompactions));
      context.Children.Add(Words("An absent provider reading stays unknown. Account limits and saved model choices are separate from the actual context window.", 12));
    }
    RenderReading(); await ShowContentAsync("Session inspector", body);
  }
}
