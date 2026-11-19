using System.Collections.Immutable;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Agents;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Agents;

public interface IAgentLibraryNavigation { void OpenSkillsStore(); }

public sealed partial class AgentsPage
{
  private IReadOnlyList<InstalledSkill>? librarySkills;
  private bool libraryReading;

  private void WorkDirectory(StackPanel body)
  {
    var project = Filter("Project", new[] { ("", "All projects") }.Concat(Model.Projects.List().Select(p => (p.Id, p.Name))), projectFilter ?? "", id => { projectFilter = id.Length == 0 ? null : id; Render(); });
    body.Children.Add(project);
    var active = Model.Agents.List().Where(a => (projectFilter is null || a.ProjectId == projectFilter) && Model.Activity(a).Live > 0)
      .OrderByDescending(a => Model.Activity(a).Busy).ThenBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
    if (active.Length == 0) { body.Children.Add(Words("No agents are at work.", muted: true)); return; }
    foreach (var group in active.GroupBy(a => a.ProjectId))
    {
      body.Children.Add(ProjectHeading(group.Key, group.Count()));
      foreach (var agent in group)
      {
        var card = Stack(12);
        var head = new Grid { ColumnSpacing = 12 };
        head.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        head.Children.Add(Button(agent.Name, () => OpenAgent(agent.Id)));
        var status = (FrameworkElement)StatusLine(agent); Grid.SetColumn(status, 1); head.Children.Add(status); card.Children.Add(head);
        foreach (var run in Model.Hands(agent.Id)) card.Children.Add(SessionRunRow(run));
        body.Children.Add(Card(card));
      }
    }
  }

  private void SkillDirectory(StackPanel body)
  {
    var toolbar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    var search = new AutoSuggestBox { PlaceholderText = "Find a skill", Text = query, MinWidth = 200, MaxWidth = 320 };
    AutomationProperties.SetAutomationId(search, "agents.skills.search"); toolbar.Children.Add(search);
    toolbar.Children.Add(Filter("Project", new[] { ("", "Every project") }.Concat(Model.Projects.List().Select(p => (p.Id, p.Name))), projectFilter ?? "", id => { projectFilter = id.Length == 0 ? null : id; librarySkills = null; Render(); }));
    toolbar.Children.Add(Button("Refresh", () => { librarySkills = null; Render(); }));
    if (navigation is IAgentLibraryNavigation store) toolbar.Children.Add(Button("Get more", store.OpenSkillsStore));
    body.Children.Add(new ScrollViewer { Content = toolbar, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollMode = ScrollMode.Disabled });
    var list = Stack(12); body.Children.Add(list);
    void Fill()
    {
      list.Children.Clear();
      if (librarySkills is null)
      {
        list.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 3 });
        for (var i = 0; i < 3; i++)
        {
          var skeleton = new Border { Height = 90, CornerRadius = new(10) }; skeleton.SetResourceReference(Border.BackgroundProperty, "DeckControlBrush"); list.Children.Add(skeleton);
        }
        if (!libraryReading) _ = ReadSkillsAsync();
        return;
      }
      var visible = librarySkills.Where(s => s.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase) || s.Description.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToArray();
      foreach (var skill in visible)
      {
        var card = Stack(8);
        card.Children.Add(Heading(skill.Name, 15));
        if (skill.Description.Length > 0) card.Children.Add(Words(skill.Description, 12, true));
        var users = Model.Agents.List().Where(a => !a.Skills.IsDefault && a.Skills.Contains(skill.Name, StringComparer.OrdinalIgnoreCase)).Select(a => a.Name).ToArray();
        card.Children.Add(Words(users.Length == 0 ? "No agent has it yet" : string.Join(", ", users), 12, true));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(AsyncButton("Show skill", () => EditLibrarySkillAsync(skill)));
        actions.Children.Add(AsyncButton("Assign skill", () => AssignLibrarySkillAsync(skill)));
        card.Children.Add(actions); list.Children.Add(Card(card));
      }
      if (visible.Length == 0) list.Children.Add(Words(librarySkills.Count == 0 ? "No skills yet." : "No skills match this search.", muted: true));
    }
    search.TextChanged += (_, _) => { query = search.Text; Fill(); }; Fill();
  }

  private async Task ReadSkillsAsync()
  {
    libraryReading = true;
    try
    {
      var folders = Model.Projects.List().Where(p => projectFilter is null || p.Id == projectFilter).SelectMany(p => p.Folders).ToArray();
      var roots = AgentSkills.Roots(folders);
      librarySkills = await Task.Run(() => roots.SelectMany(root => AgentSkills.Find((string[])[root])).GroupBy(s => s.Folder, StringComparer.OrdinalIgnoreCase).Select(g => g.First()).OrderBy(s => s.Name, StringComparer.CurrentCultureIgnoreCase).ToArray());
    }
    finally { libraryReading = false; if (IsLoaded && grouping == "Skills") Render(); }
  }

  private async Task NewLibrarySkillAsync()
  {
    var name = new TextBox { Header = "Name", PlaceholderText = "Release check", MaxLength = 80 };
    var summary = new TextBox { Header = "Summary", MaxLength = 300 };
    var project = new ComboBox { Header = "Use in", HorizontalAlignment = HorizontalAlignment.Stretch };
    project.Items.Add(new ComboBoxItem { Content = "Every project", Tag = "" });
    foreach (var row in Model.Projects.List().Where(p => p.Folders.Length > 0)) project.Items.Add(new ComboBoxItem { Content = row.Name, Tag = row.HomeFolder });
    project.SelectedIndex = 0;
    var text = new TextBox { Header = "Instructions", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 200, MaxHeight = 340, MaxLength = 500000 };
    var form = Stack(12); form.MinWidth = 400; form.Children.Add(name); form.Children.Add(summary); form.Children.Add(project); form.Children.Add(text);
    var error = Words("", 12); form.Children.Add(error);
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "New skill", Content = form, PrimaryButtonText = "Create", CloseButtonText = "Cancel" };
    dialog.PrimaryButtonClick += (_, e) =>
    {
      try
      {
        var folder = (project.SelectedItem as ComboBoxItem)?.Tag as string;
        var root = Path.Combine(string.IsNullOrEmpty(folder) ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) : folder, ".agents", "skills");
        var title = name.Text.Trim();
        if (title.Length == 0) throw new ArgumentException("Give this skill a name.");
        var folderName = System.Text.RegularExpressions.Regex.Replace(title.ToLowerInvariant(), "[^a-z0-9_-]+", "-").Trim('-');
        if (folderName.Length == 0) folderName = "skill-" + Guid.NewGuid().ToString("N")[..8];
        folderName = folderName[..Math.Min(80, folderName.Length)];
        static string Line(string value) => new(value.Where(c => !char.IsControl(c)).ToArray());
        var instructions = "---\nname: " + Line(title) + "\ndescription: " + Line(summary.Text) + "\n---\n\n" + text.Text;
        AgentSkillLibrary.Save(root, folderName, instructions); librarySkills = null;
      }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { e.Cancel = true; error.Text = ex.Message; }
    };
    await dialog.ShowAsync(); Render();
  }

  private async Task EditLibrarySkillAsync(InstalledSkill skill)
  {
    var root = Path.GetDirectoryName(skill.Folder)!; var name = Path.GetFileName(skill.Folder);
    await Model.RunAsync(async () =>
    {
      var document = AgentSkillLibrary.Read(root, name);
      var text = new TextBox { Text = document.Text, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 280, MaxHeight = 480, MinWidth = 440, MaxLength = 500000 };
      var error = Words("", 12); var form = Stack(12); form.Children.Add(text); form.Children.Add(error);
      var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = document.Name, Content = form, PrimaryButtonText = "Save", CloseButtonText = "Close" };
      dialog.PrimaryButtonClick += (_, e) => { try { AgentSkillLibrary.Save(root, name, text.Text, document.Text); librarySkills = null; } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { e.Cancel = true; error.Text = ex.Message; } };
      await dialog.ShowAsync();
    }, ""); Render();
  }

  private async Task AssignLibrarySkillAsync(InstalledSkill skill)
  {
    var list = Stack(8); var assignments = new List<(SavedAgent Agent, CheckBox Box)>();
    foreach (var agent in Model.Agents.List().Where(a => a.Status != SavedAgentStatus.Archived && (projectFilter is null || a.ProjectId == projectFilter)))
    {
      var choice = new CheckBox { Content = agent.Name, IsChecked = !agent.Skills.IsDefault && agent.Skills.Contains(skill.Name, StringComparer.OrdinalIgnoreCase) };
      assignments.Add((agent, choice)); list.Children.Add(choice);
    }
    if (assignments.Count == 0) list.Children.Add(Words("No agents yet.", muted: true));
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Assign " + skill.Name, Content = new ScrollViewer { Content = list, MaxHeight = 400 }, PrimaryButtonText = "Save", CloseButtonText = "Cancel", IsPrimaryButtonEnabled = assignments.Count > 0 };
    if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
    await Model.RunAsync(() =>
    {
      foreach (var (before, choice) in assignments)
      {
        var agent = Model.Agents.Get(before.Id); var skills = agent.Skills.IsDefault ? ImmutableArray<string>.Empty : agent.Skills;
        var had = skills.Contains(skill.Name, StringComparer.OrdinalIgnoreCase);
        if (had == (choice.IsChecked == true)) continue;
        Model.Agents.Save(agent with { Skills = choice.IsChecked == true ? skills.Add(skill.Name) : skills.Where(s => !s.Equals(skill.Name, StringComparison.OrdinalIgnoreCase)).ToImmutableArray() }, agent);
      }
    }, "Skills saved.");
  }
}
