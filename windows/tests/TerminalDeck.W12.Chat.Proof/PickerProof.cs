using System.Reflection;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.App.Views.Agents;
using TerminalDeck.App.Views.Projects;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;
namespace TerminalDeck.W12.Chat.Proof;
public partial class App
{
  private async Task CheckPickerAsync(ChatPage page, AppDataRoot root, List<string> passed, List<string> frames)
  {
    void Check(string title, bool value) { if (!value) throw new InvalidOperationException(title); passed.Add(title); }
    var sampleFolder = Path.Combine(root.DirectoryPath, "sample project"); Directory.CreateDirectory(sampleFolder);
    var projectStore = new ProofState<ProjectState>(); var projects = new ProjectService(projectStore, new ProofFolders()); var project = projects.Create("Sample", sampleFolder); projects.Select(project.Id);
    var account = new AccountProfile(Guid.NewGuid().ToString("N"), "claude", "Synthetic signed-out account", null, AccountAuthentication.Subscription, false, Guid.NewGuid().ToString("N"));
    var accounts = new AccountService(new ProofState<AccountState>(new(1, [account], [], [])), [new ProofAccountProvider()]);
    var agents = DispatchProxy.Create<IAgents, ProofAgents>(); var backend = (ProofAgents)agents;
    var navigation = new ProofNavigation(WinRT.Interop.WindowNative.GetWindowHandle(window!));
    var task = NewSessionPicker.ShowAsync(page.XamlRoot, agents, projects, accounts, navigation, projectId: project.Id);
    await Task.Delay(250); var dialog = await OpenDialogAsync(page);
    Check("saved project choice includes full folder path", Tree(dialog).OfType<ComboBox>().Where(c => c.Header as string == "Project").SelectMany(c => c.Items.OfType<ProjectAgentUi.ChoiceRow>()).Any(c => c.Name.Contains(sampleFolder)));
    Check("signed-out selection offers sign-in in the picker", Tree(dialog).OfType<Button>().Any(b => (b.Content as string)?.StartsWith("Sign in to Claude", StringComparison.Ordinal) == true && b.Visibility == Visibility.Visible));
    foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
    {
      page.RequestedTheme = theme; dialog.RequestedTheme = theme; await Task.Delay(150);
      await Capture(dialog, root, "new-session-" + theme + ".png", frames);
    }
    var filter = Tree(dialog).OfType<TextBox>().Single(t => t.PlaceholderText == "Filter saved project folders…");
    filter.Text = "no-such-folder"; await Task.Delay(100);
    Check("no matching folder disables Start without clearing typed folder", !dialog.IsPrimaryButtonEnabled && Tree(dialog).OfType<TextBlock>().Any(t => t.Text == "No folder matches."));
    filter.Text = ""; await Task.Delay(100);
    var projectChoice = Tree(dialog).OfType<ComboBox>().Single(c => c.Header as string == "Project"); projectChoice.SelectedValue = project.Id;
    var folder = Tree(dialog).OfType<TextBox>().Single(t => t.Header as string == "Working folder");
    Check("restoring the project keeps real folder identity", folder.Text == sampleFolder && dialog.IsPrimaryButtonEnabled);
    Invoke(Tree(dialog).OfType<Button>().Single(b => b.Name == "PrimaryButton")); await Task.Delay(100);
    Check("starting state is immediate and keeps selected fields", dialog.PrimaryButtonText == "Starting…" && folder.Text == sampleFolder && backend.Starts == 1);
    backend.Start.TrySetException(new InvalidOperationException("Synthetic start failure. Sign in and retry.")); await Task.Delay(150);
    Check("start refusal is inline with retained fields", dialog.IsPrimaryButtonEnabled && folder.Text == sampleFolder && Tree(dialog).OfType<InfoBar>().Any(i => i.IsOpen && i.Message.Contains("Synthetic start failure")));
    Tree(dialog).OfType<CheckBox>().Single().IsChecked = true;
    backend.Start = new(TaskCreationOptions.RunContinuationsAsynchronously);
    Invoke(Tree(dialog).OfType<Button>().Single(b => b.Name == "PrimaryButton")); await Task.Delay(100);
    projectStore.RefuseSave = true;
    var session = Guid.NewGuid().ToString(); backend.Start.SetResult(new(session, null, "Synthetic", "claude", project.Id, null, 0, "", "chat", AgentRunState.Running, DateTimeOffset.UtcNow)); await Task.Delay(150);
    Check("failed defaults save offers Done without losing the started session", dialog.PrimaryButtonText == "Done" && Tree(dialog).OfType<InfoBar>().Any(i => i.IsOpen && i.Message.StartsWith("Session started, but")));
    Invoke(Tree(dialog).OfType<Button>().Single(b => b.Name == "PrimaryButton")); await task;
    Check("Done opens the same fixture session without a second start", backend.Starts == 2 && navigation.Opened == 1);
  }
}
public sealed class ProofState<T>(T? value = default) : IStateStore<T>
{ public bool RefuseSave; public T? Load() => value; public void Save(T state) { if (RefuseSave) throw new InvalidOperationException("Synthetic save failure"); value = state; } }
public sealed class ProofFolders : IProjectFolders
{
  public string RequireFolder(string folder) => Directory.Exists(folder) ? folder : throw new ArgumentException("Choose an existing folder.");
  public IReadOnlyList<ProjectFolder> Browse(string folder, bool showHidden) => [];
}
public sealed class ProofNavigation(nint handle) : IProjectsAgentsNavigation
{
  public nint WindowHandle => handle;
  public int Opened;
  public void OpenSession(string id) { Opened++; }
  public void OpenProject(string id) { }
  public void OpenAgent(string id) { }
}
public sealed class ProofAccountProvider : IAccountProvider
{
  public string Provider => "claude";
  public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken cancellationToken) => ValueTask.FromResult(new ProviderAccountStatus(false, null));
  public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken cancellationToken) => throw new InvalidOperationException("Rendering proof does not sign in.");
  public ValueTask SignOutAsync(AccountProfile account, CancellationToken cancellationToken) => throw new InvalidOperationException("Rendering proof does not sign out.");
  public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken cancellationToken) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]);
}
public class ProofAgents : DispatchProxy
{
  public int Starts;
  public TaskCompletionSource<AgentRun> Start = new(TaskCreationOptions.RunContinuationsAsynchronously);
  protected override object? Invoke(MethodInfo? method, object?[]? args) => method?.Name switch
  {
    nameof(IAgents.List) => Array.Empty<SavedAgent>(),
    "get_CanStartSessions" => true,
    nameof(IAgents.CanStart) => true,
    nameof(IAgents.StartAsync) => Begin(),
    _ => throw new InvalidOperationException("No fixture operation: " + method?.Name)
  };
  private ValueTask<AgentRun> Begin() { Starts++; return new(Start.Task); }
}
