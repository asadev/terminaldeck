using System.Collections.Immutable;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using TerminalDeck.App.ViewModels.Projects;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Projects;

public static class ProjectSetupDialog
{
  internal static ContentDialog? ActiveDialogForProof { get; private set; }
  public static async Task ShowAsync(XamlRoot root, ProjectsViewModel model, IProjectsAgentsNavigation navigation, string? projectId, string? initialFolder, string? initialStep, Action<Project>? finished = null, CancellationToken cancellationToken = default)
  {
    Project? project = projectId is null ? null : model.Projects.Get(projectId);
    if (project?.Id == ProjectIdentity.IndependentId) return;
    var steps = new[] { "name", "folders", "lead", "team", "skills", "card", "connections", "review" };
    var index = project is null ? 0 : Math.Max(0, Array.IndexOf(steps, initialStep ?? "lead"));
    var name = Field("Name", project?.Name ?? "", max: 80);
    var about = Field("What it is · optional", project?.Preferences.Text("about") ?? "", true);
    var folder = Field("Home folder", initialFolder ?? project?.HomeFolder ?? "");
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(name, "project.setup.name");
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(folder, "project.setup.home");
    var newFolderName = Field("New folder name", max: 255);
    var otherFolders = project?.Folders.Skip(1).ToList() ?? [];
    string? logoSource = null; var removeLogo = false;
    var logoStatus = Words(project?.Logo.Length > 0 ? "Saved project logo" : "No logo chosen", 13, true);
    var roleName = Field("Agent name", max: 60); var role = Field("Role · optional", max: 64);
    var description = Field("What the agent does", max: 4000);
    var ai = Choice("Coding AI", Providers, model.Accounts?.List().FirstOrDefault(a => a.SignedIn)?.Provider ?? "claude");
    var skills = Field("Skills · names separated by commas");
    var lead = Choice("Lead", [], ""); var skillAgent = Choice("Agent", [], "");
    var card = Field("Goals, top rules and key facts", project is null ? "" : model.Agents.Seats().FirstOrDefault(s => s.SeatKey == "lead:" + project.Id)?.Card ?? "", true, 40000);
    var repo = Field("Code repository · optional", project?.Preferences.Text("githubRepo") ?? "");
    var links = Field("Other useful links · optional", project?.Preferences.Text("links") ?? "", true);
    var newLeadName = Field("New lead name", max: 60);
    var newLeadAI = Choice("Lead coding AI", Providers);
    var error = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error };
    var content = Stack(16); content.MinWidth = 460;
    var dialog = Dialog(root, project is null ? "New project" : "Project setup", content, "Next");
    dialog.SecondaryButtonText = "";
    void FillChoices(ComboBox box, IEnumerable<(string Id, string Name)> rows, string selected)
    {
      box.Items.Clear(); foreach (var row in rows) box.Items.Add(new ChoiceRow(row.Id, row.Name));
      box.SelectedValue = selected; if (box.SelectedIndex < 0 && box.Items.Count > 0) box.SelectedIndex = 0;
    }
    void LeadFields() { var show = Picked(lead) == "new" ? Visibility.Visible : Visibility.Collapsed; newLeadName.Visibility = show; newLeadAI.Visibility = show; }
    lead.SelectionChanged += (_, _) => LeadFields();
    void FolderRows(StackPanel target)
    {
      target.Children.Clear();
      foreach (var path in otherFolders.ToArray())
      {
        var row = Stack(4); row.Children.Add(Words(path, 13));
        row.Children.Add(Button("Remove folder", () => { otherFolders.Remove(path); FolderRows(target); })); target.Children.Add(row);
      }
    }
    void Draw()
    {
      content.Children.Clear(); error.IsOpen = false;
      content.Children.Add(Words($"Step {index + 1} of {steps.Length} · {(index < 2 ? "Required" : "Optional")}", 12, true));
      if (index > 0) content.Children.Add(Button("‹  Back", () => { index--; Draw(); }));
      content.Children.Add(Heading(ProjectSetup.GuideSteps[index], 22));
      dialog.PrimaryButtonText = index == 1 && project is null ? "Create project" : index == 7 ? "Done" : "Next";
      dialog.SecondaryButtonText = index >= 2 && index < 7 ? "Skip for now" : "";
      dialog.CloseButtonText = project is null ? "Cancel" : "Finish later";
      switch (index)
      {
        case 0: content.Children.Add(Words("Give it a clear name. Only its name and home folder are needed to begin.", muted: true)); content.Children.Add(name); content.Children.Add(about);
          content.Children.Add(Heading("Logo", 16)); content.Children.Add(logoStatus);
          content.Children.Add(AsyncButton("Choose…", async () =>
          {
            if (await PickPictureAsync(navigation.WindowHandle) is { } chosen) { logoSource = chosen; removeLogo = false; logoStatus.Text = Path.GetFileName(chosen); }
          }));
          content.Children.Add(Button("Remove", () => { logoSource = null; removeLogo = true; logoStatus.Text = "No logo chosen"; }));
          var drop = Stack(6); drop.MinHeight = 64; drop.AllowDrop = true; drop.Children.Add(Words("Drop one image here. A copy is saved when you save the project.", 12, true));
          drop.DragOver += (_, e) => { if (e.DataView.Contains(StandardDataFormats.StorageItems)) { e.AcceptedOperation = DataPackageOperation.Copy; e.Handled = true; } };
          drop.Drop += async (_, e) =>
          {
            var deferral = e.GetDeferral(); e.Handled = true;
            try
            {
              var files = await e.DataView.GetStorageItemsAsync();
              if (files.Count == 1 && files[0] is Windows.Storage.StorageFile file) { logoSource = file.Path; removeLogo = false; logoStatus.Text = file.Name; error.IsOpen = false; }
              else { error.Message = "Drop one image file for the project logo."; error.IsOpen = true; }
            }
            catch (Exception ex) when (ex is not OutOfMemoryException) { error.Message = "The dropped image could not be read. Choose an image file instead."; error.IsOpen = true; }
            finally { deferral.Complete(); }
          };
          content.Children.Add(Card(drop));
          var suggestions = Stack(6); content.Children.Add(suggestions);
          async Task SuggestLogos()
          {
            try
            {
              if (!Path.IsPathFullyQualified(folder.Text)) return;
              var home = folder.Text; var paths = await Task.Run(() => ProjectLogoSuggestions.Find(home)); if (suggestions.Parent is null) return;
              if (paths.Count > 0) suggestions.Children.Add(Words("Found in the folder", 12, true));
              foreach (var path in paths) suggestions.Children.Add(Button(Path.GetFileName(path), () => { logoSource = path; removeLogo = false; logoStatus.Text = Path.GetFileName(path); }));
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { if (suggestions.Parent is not null) suggestions.Children.Add(Words("Folder suggestions are unavailable. You can still choose an image.", 12, true)); }
          }
          _ = SuggestLogos(); break;
        case 1:
          content.Children.Add(Words("This is where the project’s files live and where new sessions start.", muted: true)); content.Children.Add(folder);
          content.Children.Add(AsyncButton("Choose folder…", async () => { if (await PickFolderAsync(navigation.WindowHandle) is { } selected) folder.Text = selected; }));
          var createFolder = Stack(8); createFolder.Children.Add(newFolderName);
          createFolder.Children.Add(AsyncButton("Create folder", async () =>
          {
            if (await model.RunAsync(() => folder.Text = model.Projects.CreateFolder(folder.Text, newFolderName.Text), "Folder created. It is now the home folder.")) newFolderName.Text = "";
            else { error.Message = model.Message; error.IsOpen = true; }
          }));
          content.Children.Add(new Expander { Header = "New folder", Content = createFolder, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch });
          content.Children.Add(Heading("Other folders", 16));
          var folderRows = Stack(8); FolderRows(folderRows); content.Children.Add(folderRows);
          content.Children.Add(AsyncButton("Add a folder…", async () =>
          {
            if (await PickFolderAsync(navigation.WindowHandle) is { } selected && !otherFolders.Any(p => ProjectPaths.Equal(p, selected)))
            { otherFolders.Add(selected); FolderRows(folderRows); }
          }));
          if (project is null) content.Children.Add(Words("Create project saves these two required choices. The remaining steps can be skipped or finished later.", 13, true)); break;
        case 2:
          FillChoices(lead, new[] { ("", "No lead yet"), ("hoot", "Hoot for now"), ("new", "New lead") }.Concat(model.AgentsFor(project!.Id).Select(a => (a.Id, a.Name))), project!.Lead?.StartsWith("agent:", StringComparison.Ordinal) == true ? project.Lead[6..] : project.Preferences.Flag("setup.hootLeads") ? "hoot" : "");
          content.Children.Add(Words("A lead runs this project’s agents and reports back to Hoot.", muted: true)); content.Children.Add(lead);
          content.Children.Add(newLeadName); content.Children.Add(newLeadAI);
          LeadFields();
          break;
        case 3:
          content.Children.Add(Words("Add a role when there is work for it. The role keeps its memory when someone new takes the seat.", muted: true));
          content.Children.Add(roleName); content.Children.Add(description); content.Children.Add(role); content.Children.Add(ai);
          content.Children.Add(AsyncButton("Add agent", async () =>
          {
            if (await model.RunAsync(() => model.Agents.Hire(roleName.Text, Picked(ai), description.Text, AgentCategory.Agent, project!.Id, string.IsNullOrWhiteSpace(role.Text) ? null : role.Text.Trim())))
            { roleName.Text = ""; role.Text = ""; description.Text = ""; Draw(); }
            else { error.Message = model.Message; error.IsOpen = true; }
          }));
          foreach (var member in model.AgentsFor(project!.Id)) content.Children.Add(Words(member.Name + " · " + member.Seat, 13, true));
          break;
        case 4:
          FillChoices(skillAgent, model.AgentsFor(project!.Id).Select(a => (a.Id, a.Name)), "");
          content.Children.Add(Words("Skills are named instructions your agent knows to use. Add names here after the instructions are available in its working folder.", muted: true));
          if (skillAgent.Items.Count > 0) { content.Children.Add(skillAgent); content.Children.Add(skills); }
          else content.Children.Add(Words("Add an agent first. You can give it skills from its settings later.", muted: true)); break;
        case 5: content.Children.Add(Words("The project lead reads this card first. A few concrete goals and rules are enough.", muted: true)); content.Children.Add(card); break;
        case 6: content.Children.Add(Words("Keep links your agents may need. Saving a link does not sign in or connect a service.", muted: true)); content.Children.Add(repo); content.Children.Add(links); break;
        case 7:
          project = model.Projects.Get(project!.Id); var score = model.SetupFor(project.Id);
          content.Children.Add(Heading(project.Name, 20)); content.Children.Add(Words(project.HomeFolder ?? "", muted: true));
          content.Children.Add(Words($"Setup {score.Percent}%. " + (score.Complete ? "Everything is filled in. The setup card is now hidden." : "Still to add: " + string.Join(", ", score.Missing) + ". These can wait.")));
          content.Children.Add(Words("Your project is ready to use. Its agents, settings and sessions are on its project page.", muted: true)); dialog.CloseButtonText = ""; break;
      }
      content.Children.Add(error);
    }
    dialog.PrimaryButtonClick += async (_, e) =>
    {
      var defer = e.GetDeferral(); e.Cancel = true;
      try
      {
        if (index == 0 && string.IsNullOrWhiteSpace(name.Text)) { error.Message = "Give the project a name first."; error.IsOpen = true; return; }
        var ok = true;
        if (index == 0 && project is not null)
          ok = await model.RunAsync(() =>
          {
            project = model.Projects.Save(new(project.Id, name.Text, project.Folders), project);
            project = model.Projects.PatchSettings(project.Id, new Dictionary<string, JsonElement> { ["about"] = JsonSerializer.SerializeToElement(about.Text) });
            if (logoSource is not null || removeLogo) { project = model.Projects.SetPicture(project.Id, logoSource); logoSource = null; removeLogo = false; }
          });
        else if (index == 1)
        {
          ok = await model.RunAsync(() =>
          {
            project ??= model.Projects.Create(name.Text, folder.Text);
            project = model.Projects.Save(new(project.Id, name.Text, new[] { folder.Text }.Concat(otherFolders).ToImmutableArray()), project);
            if (logoSource is not null || removeLogo) { project = model.Projects.SetPicture(project.Id, logoSource); logoSource = null; removeLogo = false; }
            project = model.Projects.PatchSettings(project.Id, new Dictionary<string, JsonElement> { ["about"] = JsonSerializer.SerializeToElement(about.Text) });
          }, "Project saved. Optional setup can wait.");
        }
        else if (index == 2)
        {
          ok = await model.RunAsync(() =>
          {
            var chosen = Picked(lead);
            if (chosen == "new") chosen = model.Agents.Hire(newLeadName.Text, Picked(newLeadAI), "Leads this project", AgentCategory.Agent, project!.Id).Id;
            model.Agents.SetProjectLead(project!.Id, chosen is "" or "hoot" ? null : chosen);
            model.Projects.PatchSettings(project.Id, new Dictionary<string, JsonElement> { ["setup.hootLeads"] = JsonSerializer.SerializeToElement(chosen == "hoot") });
          });
        }
        else if (index == 3 && roleName.Text.Trim().Length > 0)
          ok = await model.RunAsync(() => model.Agents.Hire(roleName.Text, Picked(ai), description.Text, AgentCategory.Agent, project!.Id, role.Text.Trim().Length == 0 ? null : role.Text.Trim()));
        else if (index == 4 && skillAgent.Items.Count > 0 && skills.Text.Trim().Length > 0)
          ok = await model.RunAsync(() => model.Agents.Save(model.Agents.Get(Picked(skillAgent)) with { Skills = skills.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToImmutableArray() }));
        else if (index == 5)
          ok = await model.RunAsync(() => { var seat = "lead:" + project!.Id; var old = model.Agents.Seats().FirstOrDefault(s => s.SeatKey == seat); model.Agents.SaveSeatMemory(seat, card.Text, old?.Notes ?? ""); });
        else if (index == 6)
          ok = await model.SaveValuesAsync(project!.Id, new Dictionary<string, JsonElement> { ["githubRepo"] = JsonSerializer.SerializeToElement(repo.Text), ["links"] = JsonSerializer.SerializeToElement(links.Text) });
        if (!ok) { error.Message = model.Message; error.IsOpen = true; if (project is not null) dialog.CloseButtonText = "Finish later"; return; }
        if (index == 7) { model.SelectedId = project!.Id; e.Cancel = false; }
        else { index++; Draw(); }
      }
      finally { defer.Complete(); }
    };
    dialog.SecondaryButtonClick += (_, e) => { e.Cancel = true; index++; Draw(); };
    Draw();
    var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread()!;
    using var cancellation = cancellationToken.Register(() => dispatcher.TryEnqueue(() => dialog.Hide()));
    ActiveDialogForProof = dialog;
    try { await dialog.ShowAsync(); }
    finally { ActiveDialogForProof = null; }
    if (project is not null) finished?.Invoke(project);
  }
}
