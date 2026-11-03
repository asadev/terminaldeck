using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.App.ViewModels;

public enum ShellPage { Sessions, Browser, Projects, Agents, Tasks, Artifacts, Servers, Receiver, Hoot, Settings, Devices, Mcp, Files, SourceControl, GitHub, Store, Hooks }
public enum SessionPresentation { Terminal, Chat }
public enum SplitPresentation { None, Sessions, Browser }

// UI drafts are never presented as live keeper sessions.
public sealed class SessionDraft(string title, string provider, string folder, SessionPresentation presentation) : INotifyPropertyChanged
{
  public string Id { get; init; } = Guid.NewGuid().ToString("N");
  public bool IsLive { get; init; }
  public string State { get; set; } = "draft";
  public bool Unread { get; private set; }
  private string? lastOutput;
  public void MarkRead() { if (!Unread) return; Unread = false; PropertyChanged?.Invoke(this, new(nameof(Unread))); }
  private void ObserveOutput(string output)
  {
    if (lastOutput is not null && lastOutput != output) { Unread = true; PropertyChanged?.Invoke(this, new(nameof(Unread))); }
    lastOutput = output;
  }
  public string Title { get; private set; } = title;
  public string Provider { get; } = provider;
  public string Folder { get; } = folder;
  public SessionPresentation Presentation { get; } = presentation;
  public string Subtitle { get; private set; } = provider;
  public string ProjectInitial { get; private set; } = Initial(title);
  public static string Initial(string value) => string.IsNullOrWhiteSpace(value) ? "?" : System.Globalization.StringInfo.GetNextTextElement(value.Trim()).ToUpperInvariant();
  public string? ProjectId { get; private set; }
  public string AgentName { get; private set; } = TerminalDeck.Core.Agents.AgentSeats.ProviderName(provider);
  public string AgentIcon { get; private set; } = "person";
  public bool HasAgent { get; private set; }
  public bool IsHoot { get; private set; }
  public bool HasProject => ProjectId is { Length: > 0 } id && id != TerminalDeck.Core.Projects.ProjectIdentity.IndependentId;
  public string DisplaySubtitle { get; private set; } = TerminalDeck.Core.Agents.AgentSeats.ProviderName(provider.ToLowerInvariant());
  public string ProviderMark => Provider.ToLowerInvariant() switch { "claude" => "✳", "codex" => "◎", "gemini" => "✦", _ => ">_" };
  public string? PicturePath { get; private set; }
  public string? PictureUri => PicturePath is { } path ? new Uri(path).AbsoluteUri : null;
  public void SetAppearance(string projectName, string? picturePath, string agentLabel, string? projectId = null, string? agentIcon = null, bool hoot = false)
  {
    ProjectInitial = Initial(string.IsNullOrWhiteSpace(projectName) ? Title : projectName);
    ProjectId = projectId; AgentName = agentLabel; AgentIcon = agentIcon ?? "person";
    HasAgent = agentIcon is not null || hoot; IsHoot = hoot;
    PicturePath = picturePath; Subtitle = agentLabel + " · " + State;
    var ai = TerminalDeck.Core.Agents.AgentSeats.ProviderName(Provider.ToLowerInvariant());
    DisplaySubtitle = agentLabel == ai ? ai : agentLabel + " · " + ai;
    foreach (var name in new[] { nameof(HasAgent), nameof(IsHoot), nameof(HasProject), nameof(ProjectId), nameof(AgentName), nameof(AgentIcon), nameof(DisplaySubtitle), nameof(ProjectInitial), nameof(PicturePath), nameof(PictureUri), nameof(Subtitle), nameof(State) }) PropertyChanged?.Invoke(this, new(name));
  }
  public void ObserveStatus(string state)
  {
    if (State == state) return;
    State = state; Subtitle = AgentName + " · " + State;
    foreach (var name in new[] { nameof(State), nameof(Label), nameof(Subtitle) }) PropertyChanged?.Invoke(this, new(name));
  }
  public void Rename(string title)
  {
    Title = title; PropertyChanged?.Invoke(this, new(nameof(Title))); PropertyChanged?.Invoke(this, new(nameof(Label)));
  }
  public string Label => $"{Title} · {State}";
  private string message = "";
  public string Message { get => message; set { if (message == value) return; message = value; PropertyChanged?.Invoke(this, new(nameof(Message))); } }
  public event PropertyChangedEventHandler? PropertyChanged;
  public void Update(TerminalDeck.Core.Chats.ChatRecord row)
  {
    ObserveOutput(row.Events.Length.ToString() + ":" + row.Events.LastOrDefault()?.Text);
    Title = row.Definition.Title; State = row.Ended ? "ended" : row.Busy ? "working" : row.WaitingSince is not null ? "needs-input" : row.Problem is not null ? "needs attention" : "chat";
    PropertyChanged?.Invoke(this, new(nameof(Title))); PropertyChanged?.Invoke(this, new(nameof(Label))); PropertyChanged?.Invoke(this, new(nameof(State)));
  }
  public void Update(TerminalDeck.Core.Sessions.SessionRecord row)
  {
    ObserveOutput(row.Replay);
    Title = row.Definition.Title; State = row.State.ToString().ToLowerInvariant();
    PropertyChanged?.Invoke(this, new(nameof(Title))); PropertyChanged?.Invoke(this, new(nameof(Label))); PropertyChanged?.Invoke(this, new(nameof(State)));
  }
}

public sealed class ShellViewModel : INotifyPropertyChanged
{
  private ShellPage page;
  private SessionDraft? selected;
  private SplitPresentation split;
  private string notice = "Connecting to your sessions…";
  public ObservableCollection<SessionDraft> Sessions { get; } = [];
  public ShellPage Page { get => page; set { page = value; Changed(); Changed(nameof(Title)); } }
  public SessionDraft? Selected { get => selected; set { selected = value; Changed(); Changed(nameof(Title)); } }
  public SplitPresentation Split { get => split; set { split = value; Changed(); } }
  public string Notice { get => notice; set { notice = value; Changed(); } }
  public string Title => Page switch { ShellPage.Tasks => "Tasks", ShellPage.Artifacts => "Artifacts", ShellPage.Servers => "Servers", ShellPage.Receiver => "Receiver", ShellPage.Hoot => "Hoot", ShellPage.Browser => "Browser", ShellPage.Settings => "Settings", ShellPage.Devices => "Devices", ShellPage.Mcp => "MCP servers", ShellPage.Projects => "Projects", ShellPage.Agents => "Agents", ShellPage.Files => "Files", ShellPage.SourceControl => "Source control", ShellPage.GitHub => "GitHub", _ => Selected?.Title ?? "Sessions" };
  public event PropertyChangedEventHandler? PropertyChanged;
  private void Changed([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new(name));

  public SessionDraft AddDraft(string provider, string folder, SessionPresentation presentation)
  {
    if (string.IsNullOrWhiteSpace(folder)) throw new ArgumentException("Choose a folder first.");
    if (presentation == SessionPresentation.Chat && provider == "Shell") throw new ArgumentException("Shell sessions use the terminal view.");
    var draft = new SessionDraft(presentation == SessionPresentation.Chat ? "New chat" : "New session", provider, folder, presentation);
    Sessions.Add(draft);
    Selected = draft;
    Page = ShellPage.Sessions;
    Notice = "Draft saved in this window. Starting a process needs the Windows session connection.";
    return draft;
  }

  public void Select(SessionDraft draft) { Selected = draft; Page = ShellPage.Sessions; }
  public void CloseDraft(SessionDraft draft)
  {
    var index = Sessions.IndexOf(draft);
    Sessions.Remove(draft);
    if (Selected == draft) Selected = Sessions.Count == 0 ? null : Sessions[Math.Min(index, Sessions.Count - 1)];
    if (Sessions.Count < 2 && Split == SplitPresentation.Sessions) Split = SplitPresentation.None;
  }

  public void Sync(IReadOnlyList<TerminalDeck.Core.Sessions.SessionRecord> rows, IReadOnlyList<TerminalDeck.Core.Chats.ChatRecord>? chats = null)
  {
    foreach (var old in Sessions.Where(s => s.IsLive && !rows.Any(r => r.Definition.Id == s.Id) && !(chats?.Any(c => c.Definition.Id == s.Id) ?? false)).ToArray()) CloseDraft(old);
    foreach (var row in rows)
    {
      var draft = Sessions.FirstOrDefault(s => s.Id == row.Definition.Id);
      if (draft is null)
      {
        draft = new(row.Definition.Title, row.Definition.Provider, row.Definition.Cwd, SessionPresentation.Terminal)
        { Id = row.Definition.Id, IsLive = true, State = row.State.ToString().ToLowerInvariant() };
        Sessions.Add(draft);
      }
      else draft.Update(row);
    }
    foreach (var chat in chats ?? [])
    {
      var draft = Sessions.FirstOrDefault(s => s.Id == chat.Definition.Id);
      if (draft is null) { draft = new(chat.Definition.Title, chat.Definition.Provider, chat.Definition.Cwd, SessionPresentation.Chat) { Id = chat.Definition.Id, IsLive = true }; Sessions.Add(draft); }
      draft.Update(chat);
    }
    if (Selected is null && Sessions.Count > 0) Selected = Sessions[0];
    Changed(nameof(Sessions));
  }
  // Kept for the old draft-only proof runner; product actions use AppRuntime.
  public void ServiceUnavailable(string feature) => Notice = $"{feature} is not connected in this preview. Nothing was changed.";
}

// The browser VM depends only on the existing Core surface contract, never WinUI/WebView2.
public sealed class BrowserViewModel(IBrowserSurface surface)
{
  public async Task NavigateAsync(string input)
  {
    await surface.NavigateAsync(ResolveAddress(input));
  }
  public Task<JsonElement> CommandAsync(string method, object arguments) =>
    surface.DevToolsAsync(method, JsonSerializer.SerializeToElement(arguments));

  public static Uri ResolveAddress(string input)
  {
    input = input.Trim();
    if (string.IsNullOrEmpty(input)) throw new ArgumentException("Enter a web address or search words.");
    if (Uri.TryCreate(input, UriKind.Absolute, out var explicitUri) && explicitUri.Scheme is "http" or "https")
    {
      if (!string.IsNullOrEmpty(explicitUri.UserInfo)) throw new ArgumentException("Enter an address without a username or password.");
      return explicitUri;
    }
    if (!input.Contains(' ') && (input.StartsWith("localhost", StringComparison.OrdinalIgnoreCase) || input.StartsWith("127.0.0.1", StringComparison.Ordinal)))
      return new Uri("http://" + input);
    if (!input.Contains(' ') && input.Contains('.') && !input.Contains(':')) return new Uri("https://" + input);
    if (input.Contains("://", StringComparison.Ordinal) || input.StartsWith("javascript:", StringComparison.OrdinalIgnoreCase) || input.StartsWith("file:", StringComparison.OrdinalIgnoreCase))
      throw new ArgumentException("Only http and https pages can open here.");
    return new Uri("https://www.bing.com/search?q=" + Uri.EscapeDataString(input));
  }
}
