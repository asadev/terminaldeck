namespace TerminalDeck.App.Shell;

// Semantic names resolve through the one original vector catalog in DeckIcon.
internal static class WorkspaceIcons
{
  internal static string For(string kind) => kind.ToLowerInvariant() switch
  {
    "browser" => "browser", "chat" => "chat", "hoot" => "chat",
    "agents" => "agents", "tasks" => "tasks", "projects" => "folder",
    "artifacts" => "rich-document", "servers" => "server", "receiver" => "receiver",
    "usage" => "usage", "devices" => "devices", "mcp" => "mcp",
    "files" => "folder", "sourcecontrol" => "branch", "github" => "repository",
    _ => "terminal"
  };
}
