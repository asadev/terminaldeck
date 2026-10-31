using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views.Code;
using TerminalDeck.Core.Code;

namespace TerminalDeck.App.Views;

// Files, Source control and GitHub pages: one retained page each, fed every
// open project plus Independent sessions' folders.
public sealed partial class ShellWindow
{
  private static readonly ProjectFiles codeFiles = new();
  private static readonly GitClient codeGit = new();
  private CodeHost? codeHost;
  private FilesPage? filesPage;
  private SourceControlPage? sourceControlPage;
  private GitHubPage? gitHubPage;

  private CodeHost CodePagesHost => codeHost ??= new(this);
  private FrameworkElement CodePageView(ShellPage page) => page switch
  {
    ShellPage.Files => filesPage ??= new FilesPage(CodePagesHost, codeFiles),
    ShellPage.SourceControl => sourceControlPage ??= new SourceControlPage(CodePagesHost, codeGit),
    _ => gitHubPage ??= new GitHubPage(CodePagesHost, Runtime.CopyGitHub)
  };

  private sealed class CodeHost(ShellWindow shell) : ICodePageHost
  {
    public IReadOnlyList<CodeRoot> Roots() => CodeWorkspace.Roots(shell.Runtime.Projects.List(),
      shell.Model.Sessions.Select(s => new CodeSessionFolder(s.ProjectId ?? shell.Runtime.Projects.Resolve(null, s.Folder), s.Folder)));
    public (string? ProjectId, string? Folder) Current() => shell.Model.Selected is { } session ? (session.ProjectId, session.Folder) : (shell.Runtime.Projects.ActiveProjectId, null);
    public UIElement Picture(CodeRoot root, double size)
    {
      if (root.ProjectId is { } id && shell.Runtime.Projects.List().FirstOrDefault(p => p.Id == id) is { } project) return shell.ShellProjectPicture(project, size);
      return new Border
      {
        Width = size, Height = size, CornerRadius = new CornerRadius(size / 4), Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"],
        Child = new FontIcon { Glyph = "", FontSize = size * 0.6, FontFamily = TerminalDeck.App.Views.DeckFonts.Icons, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }
      };
    }
    public async Task OpenTerminalAsync(CodeRoot root, string folder)
    {
      var project = root.ProjectId ?? shell.Runtime.Projects.Resolve(null, folder);
      var row = await shell.Runtime.StartShellForProjectAsync(folder, project);
      shell.OpenSession(row.Definition.Id);
    }
    public async Task OpenInBrowserAsync(string url)
    {
      if (!GitHubRules.SafeWebUrl(url)) throw new ArgumentException("Only https pages open here.");
      shell.Model.Page = ShellPage.Browser;
      await shell.browser.PrepareShellAsync();
      var page = await shell.browser.Core.OpenAsync(url);
      shell.browser.ObserveShellPages(); shell.SyncWindows(); shell.windowState.Select(page.Id); shell.RenderWindows();
    }
    public void Notice(string message) => shell.Model.Notice = message;
  }
}
