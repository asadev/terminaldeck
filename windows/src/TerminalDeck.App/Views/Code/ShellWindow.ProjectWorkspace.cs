using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Views.Code;
using TerminalDeck.Core.Code;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  public FrameworkElement ProjectDeploymentHistory(string projectId) => new Quality.DeploymentHistory(Runtime.Deployments, projectId);
  private readonly Dictionary<(string Project, string Section), FrameworkElement> projectWorkspaces = [];
  public FrameworkElement ProjectWorkspaceView(string projectId, string section)
  {
    if (projectWorkspaces.TryGetValue((projectId, section), out var saved)) return saved;
    var host = new ProjectCodeHost(this, projectId);
    FrameworkElement view = section switch
    {
      "Files" => Embedded(new FilesPage(host, codeFiles)),
      "Code" => new ProjectCodeWorkspace(section =>
      {
        if (section == "Changes") return Embedded(new SourceControlPage(host, codeGit));
        var github = new GitHubPage(host, Runtime.CopyGitHub); github.SelectProjectSection(section); return Embedded(github);
      }),
      "Readiness" => new Quality.ProjectReadinessPage(Runtime.ProjectReadiness, Runtime.Projects.Get(projectId).HomeFolder ?? throw new ArgumentException("Choose a project folder."), Runtime.ReadinessDismissals, provider => Quality.QualityAiTargetDialog.ShowAsync(Runtime, Runtime.Projects.Get(projectId).HomeFolder!, "readiness", Root.XamlRoot, OpenSession, provider), path => CodeUi.Reveal(Path.IsPathFullyQualified(path) ? path : Path.Combine(Runtime.Projects.Get(projectId).HomeFolder!, path)), Runtime.ReadinessRunner),
      "Stays Fixed" => new Quality.StaysFixedPage(Runtime.StaysFixed, Runtime.Projects.Get(projectId).HomeFolder ?? throw new ArgumentException("Choose a project folder."), () => { Projects.OpenProject(projectId, "Code"); }, () => Quality.QualityAiTargetDialog.ShowAsync(Runtime, Runtime.Projects.Get(projectId).HomeFolder!, "staysfixed", Root.XamlRoot, OpenSession), path => CodeUi.Reveal(Path.IsPathFullyQualified(path) ? path : Path.Combine(Runtime.Projects.Get(projectId).HomeFolder!, path))),
      _ => throw new ArgumentException("Choose Files, Changes or Code.")
    };
    projectWorkspaces[(projectId, section)] = view; return view;
  }
  private static CodePage Embedded(CodePage page) { page.EmbedInProject(); return page; }
  private sealed class ProjectCodeHost(ShellWindow shell, string projectId) : ICodePageHost
  {
    public IReadOnlyList<CodeRoot> Roots() => CodeWorkspace.Roots([shell.Runtime.Projects.Get(projectId)], []);
    public (string? ProjectId, string? Folder) Current() => (projectId, shell.Runtime.Projects.Get(projectId).HomeFolder);
    public UIElement Picture(CodeRoot root, double size) => shell.CodePagesHost.Picture(root, size);
    public Task OpenTerminalAsync(CodeRoot root, string folder) => shell.CodePagesHost.OpenTerminalAsync(root, folder);
    public Task OpenInBrowserAsync(string url) => shell.CodePagesHost.OpenInBrowserAsync(url);
    public void Notice(string message) => shell.CodePagesHost.Notice(message);
  }
}
