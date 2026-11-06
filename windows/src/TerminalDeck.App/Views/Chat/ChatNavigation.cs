namespace TerminalDeck.App.Views.Chat;

// The shell supplies its existing destinations; the chat never creates another
// account editor or owns the application's tab/window state.
public sealed record ChatNavigation(Action OpenCodingAis, Action<string> OpenChat, string? AgentName = null, IReadOnlyList<string>? ProjectFolders = null, Func<string, Task>? SignIn = null, ChatMcpNavigation? Mcp = null, Func<string, TerminalDeck.App.ViewModels.SessionDraft?>? SessionIdentity = null);
