using System.Collections.Immutable;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.ViewModels.Receiver;
using TerminalDeck.Core.Receiver;
using static TerminalDeck.App.Views.Receiver.ReceiverUi;

namespace TerminalDeck.App.Views.Receiver;

public sealed class ReceiverPage : Grid
{
  public ReceiverViewModel Model { get; }
  private readonly IReadOnlyList<(string Id, string Label)> projects;
  private readonly Func<Task>? showBrowserKey;
  private string section = "Events";
  private readonly Action changed;
  public ReceiverPage(ReceiverViewModel model, IReadOnlyList<(string Id, string Label)> projects, Func<Task>? showBrowserKey = null)
  {
    Model = model; this.projects = projects; this.showBrowserKey = showBrowserKey; Style = PageStyle();
    var dispatcher = DispatcherQueue; changed = () => dispatcher.TryEnqueueHandled(Render);
    Loaded += (_, _) => { Model.Changed += changed; Model.Receiver.Changed += changed; Render(); };
    Unloaded += (_, _) => { Model.Changed -= changed; Model.Receiver.Changed -= changed; }; Render();
  }
  public void ShowSection(string name) { if (name == "Inbox") name = "Events";
    if (name is "Flow" or "Events" or "Sources" or "Rules" or "Intake") section = name; Render(); }
  private Task Run(Action action, string message) => Model.RunAsync(() => { action(); return Task.CompletedTask; }, message);
  private void Render()
  {
    Children.Clear(); var body = Stack(20); body.Margin = new Thickness(28);
    var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    foreach (var name in new[] { "Flow", "Events", "Sources", "Rules", "Intake" }) tabs.Children.Add(Button(name, () => { ShowSection(name); return Task.CompletedTask; }, name == section));
    body.Children.Add(tabs);
    var project = Choice("Project", new[] { ("", "All projects") }.Concat(projects), Model.ProjectFilter ?? "");
    project.SelectionChanged += (_, _) => { Model.ProjectFilter = Picked(project) is { Length: > 0 } id ? id : null; Render(); };
    var scoped = Model.Receiver.Items(limit: 1000).Where(i => Model.ProjectFilter is null || i.ProjectId == Model.ProjectFilter).ToArray();
    var summary = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { project,
      Button($"{scoped.Length} events", () => { Model.SourceFilter = null; Model.StatusFilter = null; Model.Query = ""; ShowSection("Events"); return Task.CompletedTask; }),
      Button($"{scoped.Count(i => i.Status == InboxStatus.Unrouted)} not routed", () => { Model.SourceFilter = null; Model.StatusFilter = InboxStatus.Unrouted; Model.Query = ""; ShowSection("Events"); return Task.CompletedTask; }),
      Button("Add source", () => EditSourceAsync(null), true) } };
    summary.SizeChanged += (_, _) => summary.Orientation = summary.ActualWidth < 720 ? Orientation.Vertical : Orientation.Horizontal; body.Children.Add(summary);
    if (Model.Busy) body.Children.Add(new ProgressBar { IsIndeterminate = true });
    if (Model.Message.Length > 0) body.Children.Add(new TerminalDeck.App.Views.Notices.CompactNotice { IsOpen = true, IsClosable = false, Severity = Model.IsError ? InfoBarSeverity.Error : InfoBarSeverity.Informational, Message = Model.Message });
    switch (section) { case "Flow": Flow(body); break; case "Events": Inbox(body); break; case "Sources": Sources(body); break; case "Rules": Rules(body); break; default: Intake(body); break; }
    var scroll = Scroll(body); scroll.SizeChanged += (_, _) => body.Width = Math.Max(0, scroll.ActualWidth - 56);
    Children.Add(scroll);
  }
  private void Inbox(StackPanel body)
  {
    var query = Field("", Model.Query, limit: 200); query.PlaceholderText = "Search events"; query.MaxWidth = 260; query.HorizontalAlignment = HorizontalAlignment.Stretch;
    AutomationProperties.SetName(query, "Search events");
    var filters = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    filters.Children.Add(query);
    filters.Children.Add(Button("Not routed", () => { Model.StatusFilter = Model.StatusFilter == InboxStatus.Unrouted ? null : InboxStatus.Unrouted; Render(); return Task.CompletedTask; }, Model.StatusFilter == InboxStatus.Unrouted));
    var source = Choice("", new[] { ("", "All sources") }.Concat(Model.Receiver.Sources().Select(s => (s.Id, s.Name))), Model.SourceFilter ?? "");
    AutomationProperties.SetName(source, "Source filter");
    source.SelectionChanged += (_, _) => { Model.SourceFilter = Picked(source) is { Length: > 0 } id ? id : null; Render(); };
    filters.Children.Add(source);
    var status = Choice("", new[] { ("", "All statuses") }.Concat(Enum.GetValues<InboxStatus>().Select(s => (s.ToString(), s.ToString()))), Model.StatusFilter?.ToString() ?? "");
    AutomationProperties.SetName(status, "Status filter");
    status.SelectionChanged += (_, _) => { Model.StatusFilter = Enum.TryParse<InboxStatus>(Picked(status), out var value) ? value : null; Render(); };
    filters.Children.Add(status); body.Children.Add(filters);
    var content = new Grid { ColumnSpacing = 20 };
    var tableColumn = new ColumnDefinition(); var inspectorColumn = new ColumnDefinition { Width = GridLength.Auto };
    content.ColumnDefinitions.Add(tableColumn); content.ColumnDefinitions.Add(inspectorColumn);
    var table = Stack(6); table.MinWidth = 680;
    var tableScroll = new ScrollViewer { Content = table, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    tableScroll.SizeChanged += (_, _) => table.Width = Math.Max(680, tableScroll.ActualWidth);
    content.Children.Add(tableScroll);
    var inspector = Stack(12); inspector.MaxWidth = 380; Grid.SetColumn(inspector, 1); content.Children.Add(inspector);
    var list = new ListView { SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = false, MinHeight = 360, HorizontalAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(0) };
    var headings = EventRow(["Time", "Source", "Project", "Summary", "Routed to", "Status"], true); headings.Margin = new Thickness(8, 0, 8, 0);
    table.Children.Add(headings);
    table.Children.Add(list);
    var empty = Words("No events match these filters. Share or drop something onto Receiver, or change the search and filters."); table.Children.Add(empty);
    void ShowDetail()
    {
      inspector.Children.Clear();
      inspectorColumn.Width = content.ActualWidth < 980 || Model.SelectedId is null ? new GridLength(0) : new GridLength(380);
      if (Model.Selected is not { } item) return;
      inspector.Children.Add(Button("Close detail", () => { Model.SelectedId = null; Render(); return Task.CompletedTask; }));
      Detail(inspector, item);
    }
    bool filling = false;
    void Fill()
    {
      filling = true; list.Items.Clear(); var rows = Model.Items;
      // Filtering must never leave an unseen item available for approval in the inspector.
      if (Model.SelectedId is { } selected && !rows.Any(item => item.Id == selected)) Model.SelectedId = null;
      empty.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
      foreach (var item in rows)
      {
        var sourceName = Model.Receiver.Sources().FirstOrDefault(s => s.Id == item.SourceId)?.Name ?? item.SourceId;
        var projectName = projects.FirstOrDefault(p => p.Id == item.ProjectId).Label ?? item.ProjectId;
        var route = item.Target is { } target ? Model.Receiver.Destinations(item.ProjectId).FirstOrDefault(d => d.Target == target)?.Name ?? target.Kind.ToString() : "—";
        var row = new ListViewItem { Content = EventRow([item.ReceivedAt.LocalDateTime.ToString("t"), sourceName, projectName, item.Title, route, item.Status.ToString()]), Tag = item.Id, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(8, 10, 8, 10) };
        list.Items.Add(row); if (item.Id == Model.SelectedId) list.SelectedItem = row;
      }
      filling = false; ShowDetail();
    }
    list.SelectionChanged += (_, _) => { if (filling) return; Model.SelectedId = (list.SelectedItem as ListViewItem)?.Tag as string; ShowDetail(); };
    query.TextChanged += (_, _) => { Model.Query = query.Text; Fill(); };
    // Keep the event table usable at narrow widths by stacking its inspector.
    content.SizeChanged += (_, _) =>
    {
      var narrow = content.ActualWidth < 980;
      filters.Orientation = content.ActualWidth < 720 ? Orientation.Vertical : Orientation.Horizontal;
      if (content.RowDefinitions.Count == 0) { content.RowDefinitions.Add(new()); content.RowDefinitions.Add(new() { Height = GridLength.Auto }); }
      Grid.SetRow(inspector, narrow ? 1 : 0); Grid.SetColumn(inspector, narrow ? 0 : 1);
      inspector.MaxWidth = narrow ? double.PositiveInfinity : 380;
      inspectorColumn.Width = narrow || Model.SelectedId is null ? new GridLength(0) : new GridLength(380);
    };
    Fill(); body.Children.Add(content);
  }
  private static Grid EventRow(string[] values, bool heading = false)
  {
    var row = new Grid { ColumnSpacing = 12, HorizontalAlignment = HorizontalAlignment.Stretch };
    var widths = new[] { .65, 1.1, .9, 2.2, 1.2, .9 };
    for (var i = 0; i < values.Length; i++)
    {
      row.ColumnDefinitions.Add(new() { Width = new GridLength(widths[i], GridUnitType.Star) });
      var text = Words(values[i], heading ? 12 : 13); text.TextWrapping = TextWrapping.NoWrap; text.TextTrimming = TextTrimming.CharacterEllipsis;
      if (heading) text.Opacity = .65;
      ToolTipService.SetToolTip(text, values[i]); Grid.SetColumn(text, i); row.Children.Add(text);
    }
    return row;
  }
  private void Detail(StackPanel body, ReceiverItem item)
  {
    var content = Stack(); content.Children.Add(Words(item.Title, 22)); content.Children.Add(Words(ReceiverStore.OutsideNote, 12));
    content.Children.Add(Words(item.Text));
    if (item.Url is not null) content.Children.Add(Words(item.Url));
    foreach (var file in item.Files) content.Children.Add(Words($"{file.Name} · {file.Bytes:N0} bytes"));
    content.Children.Add(Words(item.Outcome ?? item.Status.ToString()));
    content.Children.Add(Button("Suggest a rule", () =>
    {
      var target = item.Target ?? Model.Receiver.Destinations(item.ProjectId).FirstOrDefault()?.Target;
      if (target is null) { Model.ShowMessage("Open a destination in this project first."); return Task.CompletedTask; }
      return EditRuleAsync(new(Guid.NewGuid().ToString("N"), "For " + item.Title[..Math.Min(100, item.Title.Length)], item.SourceId, item.Title, target));
    }));
    content.Children.Add(Words(item.ReceivedAt.LocalDateTime.ToString("g") + " · " + (Model.Receiver.Sources().FirstOrDefault(s => s.Id == item.SourceId)?.Name ?? item.SourceId), 12));
    if (item.ReplayedFrom is { } original) content.Children.Add(Button("Show the original", () =>
    { Model.SourceFilter = null; Model.StatusFilter = null; Model.ProjectFilter = null; Model.Query = ""; Model.SelectedId = original; ShowSection("Events"); return Task.CompletedTask; }));
    content.Children.Add(Button("Replay through rules", async () =>
    {
      if (await Dialog(this, "Replay through rules?", Words("Create a new event using the current rules. The original event stays. Nothing is sent until you approve it."), "Replay").ShowAsync() == ContentDialogResult.Primary)
        await Run(() => { Model.SelectedId = Model.Receiver.Replay(item.Id).Id; }, "Replayed through the current rules.");
    }));
    var payload = item.Payload?.GetRawText() ?? item.Text;
    var raw = Stack(8); raw.Children.Add(new TextBox { Text = payload, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 240 });
    raw.Children.Add(Button("Copy payload", () => { var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(payload); Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); return Task.CompletedTask; }));
    content.Children.Add(new Expander { Header = "Raw payload", Content = raw, HorizontalContentAlignment = HorizontalAlignment.Stretch });
    if (item.Status is not (InboxStatus.Delivered or InboxStatus.Ignored))
    {
      var targets = Model.Receiver.Destinations(item.ProjectId);
      if (targets.Count > 0)
      {
        var proposed = ReceiverReview.DestinationIndex(targets, item.Target);
        var choice = Choice("Send to", targets.Select((t, i) => (i.ToString(), t.Name)), proposed.ToString());
        if (item.Target is not null && targets[proposed].Target == item.Target) content.Children.Add(Words("Rule proposes " + targets[proposed].Name));
        if (targets.Count > 1) content.Children.Add(choice); else content.Children.Add(Words("Send to " + targets[0].Name));
        var send = Button(item.DeliveryId is not null ? "Retry send" : "Route to…", async () =>
        {
          var target = targets[int.Parse(Picked(choice))];
          var dialog = Dialog(this, "Send this item?", Words($"Send “{item.Title}” and its attachments to {target.Name}?"), "Send");
          if (await dialog.ShowAsync() == ContentDialogResult.Primary) await Model.RouteAsync(target.Target);
        }, true);
        AutomationProperties.SetAutomationId(send, "receiver.approve"); send.IsEnabled = !Model.Busy; content.Children.Add(send);
      }
      else content.Children.Add(Words("No destinations are available in this item's project. Open a session or chat there first."));
      content.Children.Add(Button("Dismiss", () => Run(() => Model.Receiver.Dismiss(item.Id), "Item dismissed.")));
    }
    var trail = new Expander { Header = "What happened", Content = Words(string.Join("\n", item.Trail.Select(t => $"{t.At.LocalDateTime:g} · {t.Action}"))), HorizontalAlignment = HorizontalAlignment.Stretch };
    content.Children.Add(trail); body.Children.Add(Card(content));
  }
  private void Sources(StackPanel body)
  {
    foreach (var source in Model.Receiver.Sources().Where(s => Model.ProjectFilter is null || s.ProjectId == Model.ProjectFilter))
    {
      var row = Stack(8); row.Children.Add(Words(source.Name, 20)); row.Children.Add(Words($"{source.Kind} · {(source.Enabled ? "On" : "Paused")} · {projects.FirstOrDefault(p => p.Id == source.ProjectId).Label ?? source.ProjectId}"));
      var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
      actions.SizeChanged += (_, _) => actions.Orientation = actions.ActualWidth < 560 ? Orientation.Vertical : Orientation.Horizontal;
      actions.Children.Add(Button("Edit source", () => EditSourceAsync(source)));
      actions.Children.Add(Button(source.Enabled ? "Pause" : "Resume", () => Run(() => Model.Receiver.SaveSource(source with { Enabled = !source.Enabled }), "Source updated.")));
      actions.Children.Add(Button("Show items", () => { Model.SourceFilter = source.Id; ShowSection("Inbox"); return Task.CompletedTask; }));
      actions.Children.Add(Button("Remove empty source", () => Run(() => Model.Receiver.RemoveSource(source.Id), "Source removed."))); row.Children.Add(actions); body.Children.Add(Card(row));
    }
  }
  private async Task EditSourceAsync(ReceiverSource? source)
  {
    var fields = Stack(); var name = Field("Name", source?.Name ?? "", limit: 120);
    var project = Choice("Project", projects, source?.ProjectId); var kind = Choice("Receives", Enum.GetValues<IntakeKind>().Select(k => (k.ToString(), k.ToString())), source?.Kind.ToString());
    fields.Children.Add(name); if (source is null) { fields.Children.Add(project); fields.Children.Add(kind); }
    fields.Children.Add(Words("New sources need an intake connection. Built-in share, drop, browser, phone and clipboard sources are connected when the app starts.", 12));
    var dialog = Dialog(this, source is null ? "Add source" : "Edit source", fields, "Save");
    if (await dialog.ShowAsync() == ContentDialogResult.Primary)
      await Run(() => Model.Receiver.SaveSource(source is null ? new(Guid.NewGuid().ToString("N"), name.Text, Enum.Parse<IntakeKind>(Picked(kind)), Picked(project)) : source with { Name = name.Text }), "Source saved.");
  }
  private void Rules(StackPanel body)
  {
    body.Children.Add(Words("Rules suggest where items belong. You still approve each send. Quiet hours use this computer's time."));
    body.Children.Add(Button("Add rule", () => EditRuleAsync(null), true));
    var rules = Model.Receiver.Rules();
    foreach (var rule in rules)
    {
      var row = Stack(8); row.Children.Add(Words(rule.Name, 20)); row.Children.Add(Words($"{(rule.Enabled ? "On" : "Paused")} · contains “{rule.Contains}” · {rule.Target.Kind} · {rule.PerHour}/hour · {rule.Conditions.Length} conditions"));
      row.Children.Add(Button("Edit rule", () => EditRuleAsync(rule)));
      row.Children.Add(Button("Try on latest item", () =>
      {
        var item = Model.Receiver.Items(rule.SourceId, limit: 1).FirstOrDefault();
        if (item is null) Model.ShowMessage("No items have arrived for this source yet.");
        else
        {
          var decision = Model.Receiver.Test(new(item.SourceId, item.Title, item.Text, item.Url) { Payload = item.Payload }, rule);
          Model.ShowMessage($"Preview only: {decision.Reason} Destination: {decision.Target?.Kind.ToString() ?? "None"}. Nothing was sent.");
        }
        return Task.CompletedTask;
      }));
      if (rules[0].Id != rule.Id) row.Children.Add(Button("Move to top", () => Run(() => Model.Receiver.MoveRule(rule.Id, 0), "Rule moved.")));
      row.Children.Add(Button("Delete rule", () => Run(() => Model.Receiver.RemoveRule(rule.Id), "Rule deleted."))); body.Children.Add(Card(row));
    }
  }
  private async Task EditRuleAsync(ReceiverRule? rule)
  {
    var sources = Model.Receiver.Sources(); if (sources.Count == 0) { await Run(() => throw new ArgumentException("Add a source first."), ""); return; }
    var fields = Stack(); var name = Field("Name", rule?.Name ?? "", limit: 120); var contains = Field("Title or text contains", rule?.Contains ?? "", limit: 1000);
    var source = Choice("Source", sources.Select(s => (s.Id, s.Name)), rule?.SourceId); var target = Choice("Destination", []);
    IReadOnlyList<ReceiverDestination> targets = [];
    void Targets() { targets = Model.Receiver.Destinations(sources.Single(s => s.Id == Picked(source)).ProjectId); var replacement = Choice("Destination", targets.Select((d, i) => (i.ToString(), d.Name))); target.Items.Clear(); while (replacement.Items.Count > 0) { var item = replacement.Items[0]; replacement.Items.RemoveAt(0); target.Items.Add(item); } target.SelectedIndex = targets.ToList().FindIndex(d => d.Target == rule?.Target); if (target.SelectedIndex < 0 && target.Items.Count > 0) target.SelectedIndex = 0; }
    source.SelectionChanged += (_, _) => Targets(); Targets();
    var enabled = new ToggleSwitch { Header = "Rule on", IsOn = rule?.Enabled ?? true };
    var limit = new NumberBox { Header = "Suggested sends per hour", Minimum = 1, Maximum = 1000, Value = rule?.PerHour ?? 30 };
    var quiet = new ToggleSwitch { Header = "Quiet hours", IsOn = rule?.QuietStartHour is not null };
    var start = new NumberBox { Header = "Quiet from (hour 0–23)", Minimum = 0, Maximum = 23, Value = rule?.QuietStartHour ?? 22 };
    var end = new NumberBox { Header = "Quiet until (hour 0–23)", Minimum = 0, Maximum = 23, Value = rule?.QuietEndHour ?? 8 };
    foreach (var child in new UIElement[] { name, source, contains, target, enabled, limit, quiet, start, end }) fields.Children.Add(child);
    var conditionRows = Stack(8); fields.Children.Add(Words("All conditions must match the parsed payload. Paths use dots and array indexes, for example build.jobs[0].status.", 12));
    fields.Children.Add(conditionRows);
    var editors = new List<(TextBox Path, ComboBox Operation, TextBox Value)>();
    void AddCondition(ReceiverCondition condition)
    {
      var row = Stack(8); var path = Field("Path", condition.Path, limit: 240);
      var operation = Choice("Operation", Enum.GetValues<ReceiverConditionOperation>().Select(o => (o.ToString(), ReceiverConditions.Label(o))), condition.Operation.ToString());
      var value = Field("Value", condition.Value, limit: 1000);
      row.Children.Add(path); row.Children.Add(operation); row.Children.Add(value);
      var latest = Model.Receiver.Items(Picked(source), limit: 1).FirstOrDefault();
      var paths = latest is null ? [] : ReceiverConditions.Paths(new(latest.SourceId, latest.Title, latest.Text) { Payload = latest.Payload });
      if (paths.Length > 0)
      {
        var picker = Choice("Pick a path from latest payload", new[] { ("", "Choose a path…") }.Concat(paths.Select(p => (p, p))));
        picker.SelectionChanged += (_, _) => { if (Picked(picker).Length > 0) path.Text = Picked(picker); }; row.Children.Add(picker);
      }
      var editor = (path, operation, value); editors.Add(editor);
      row.Children.Add(Button("Remove condition", () => { editors.Remove(editor); conditionRows.Children.Remove(row); return Task.CompletedTask; }));
      conditionRows.Children.Add(Card(row));
    }
    foreach (var condition in rule?.Conditions ?? []) AddCondition(condition);
    fields.Children.Add(Button("Add condition", () => { if (editors.Count < 32) AddCondition(new("", ReceiverConditionOperation.Is)); return Task.CompletedTask; }));
    var error = new Notices.CompactNotice(); fields.Children.Add(error);
    var dialog = Dialog(this, rule is null ? "Add rule" : "Edit rule", fields, "Save");
    dialog.PrimaryButtonClick += async (_, args) =>
    {
      var deferral = args.GetDeferral(); args.Cancel = true;
      try
      {
        await Run(() =>
        {
          if (target.SelectedIndex < 0) throw new ArgumentException("Open a destination in this project first.");
          Model.Receiver.SaveRule(new(rule?.Id ?? Guid.NewGuid().ToString("N"), name.Text, Picked(source), contains.Text, targets[target.SelectedIndex].Target, enabled.IsOn, (int)limit.Value, quiet.IsOn ? (int)start.Value : null, quiet.IsOn ? (int)end.Value : null)
            { Conditions = editors.Select(e => new ReceiverCondition(e.Path.Text, Enum.Parse<ReceiverConditionOperation>(Picked(e.Operation)), e.Value.Text)).ToImmutableArray() });
        }, "Rule saved.");
        error.Text = Model.IsError ? Model.Message : ""; args.Cancel = Model.IsError;
      }
      finally { deferral.Complete(); }
    };
    await dialog.ShowAsync();
  }
  private void Flow(StackPanel body)
  {
    body.Children.Add(Words("Flow", 22)); body.Children.Add(Words("Sources → rules → destinations. Select an event to inspect its actual delivery trail."));
    foreach (var source in Model.Receiver.Sources().Where(s => Model.ProjectFilter is null || s.ProjectId == Model.ProjectFilter))
    {
      var route = Stack(8); route.Children.Add(Words(source.Name + (source.Enabled ? "" : " · Paused"), 18));
      var rules = Model.Receiver.Rules().Where(r => r.SourceId is null || r.SourceId == source.Id).ToArray();
      foreach (var rule in rules)
      {
        var target = Model.Receiver.Destinations(source.ProjectId).FirstOrDefault(d => d.Target == rule.Target)?.Name ?? rule.Target.Kind.ToString();
        route.Children.Add(Words("→ " + rule.Name + (rule.Enabled ? "" : " · Paused") + " → " + target));
      }
      if (rules.Length == 0) route.Children.Add(Words("→ No rule → Not routed"));
      foreach (var item in Model.Receiver.Items(source.Id, limit: 5))
        route.Children.Add(Button(item.Title + " · " + item.Status, () => { Model.SourceFilter = source.Id; Model.StatusFilter = null; Model.Query = ""; Model.SelectedId = item.Id; ShowSection("Events"); return Task.CompletedTask; }));
      body.Children.Add(Card(route));
    }
  }

  private void Intake(StackPanel body)
  {
    var state = Model.Settings.Status;
    body.Children.Add(Words("Clipboard watching copies new clipboard content into this inbox while the app is running. Turn it on only when you want that."));
    var clipboard = new ToggleSwitch { Header = "Watch clipboard", IsOn = state.Clipboard };
    var browser = new ToggleSwitch { Header = "Receive from browser extensions", IsOn = state.Browser };
    clipboard.Toggled += async (_, _) => await Model.RunAsync(async () => await Model.Settings.ConfigureAsync(clipboard.IsOn, null), "Clipboard choice saved.");
    browser.Toggled += async (_, _) => await Model.RunAsync(async () => await Model.Settings.ConfigureAsync(null, browser.IsOn), "Browser intake choice saved.");
    body.Children.Add(clipboard); body.Children.Add(browser);
    if (state.Browser)
    {
      body.Children.Add(Words($"Browser intake is listening on 127.0.0.1:{state.Port}. Extensions need your private intake key."));
      if (showBrowserKey is not null) body.Children.Add(Button("Show intake key", showBrowserKey));
    }
    body.Children.Add(Words("Drag text, links, screenshots or up to 16 files onto Receiver. Files can be up to 20 MB each. Incoming items wait here for review."));
  }
}
