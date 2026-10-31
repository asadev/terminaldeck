using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Chats;

public sealed class WindowsChatLaunchPlanner(AppDataRoot root, string toolsDirectory, bool codexAppServer = true)
{
  public bool CodexAppServer => codexAppServer;
  public ProcessLaunch Plan(ChatRecord chat, ChatMessage? execMessage = null)
  {
    chat.Definition.Validate(); var provider = chat.Definition.Provider;
    var basePlan = new WindowsProviderLaunchPlanner(root, toolsDirectory).Plan(ChatSessions.Session(chat), false);
    var arguments = new List<string>();
    if (provider == "claude")
    {
      arguments.AddRange(["--print", "--output-format", "stream-json", "--input-format", "stream-json", "--verbose", "--include-partial-messages", "--replay-user-messages", "--permission-mode", ChatPermissionModes.Claude(chat.Definition.PermissionMode), "--permission-prompts", "host", "--permission-prompt-tool", "stdio"]);
      if (chat.ConversationId is not null) arguments.AddRange(["--resume", chat.ConversationId]);
      if (chat.Definition.Options.Model.Length > 0) arguments.AddRange(["--model", chat.Definition.Options.Model]);
      if (chat.Definition.Options.Effort is not ("" or "auto")) arguments.AddRange(["--effort", chat.Definition.Options.Effort]);
      arguments.AddRange(new WindowsProviderLaunchPlanner(root, toolsDirectory).ExtraFolderArguments(chat.Definition.Cwd));
    }
    else if (provider == "gemini") arguments.AddRange(["--acp", "--approval-mode", ChatPermissionModes.Gemini(chat.Definition.PermissionMode)]);
    else if (codexAppServer) arguments.AddRange(["app-server", "--stdio"]);
    else
    {
      arguments.AddRange(["exec", "--json", "--color", "never"]);
      if (chat.Definition.Options.Model.Length > 0) arguments.AddRange(["--model", chat.Definition.Options.Model]);
      if (chat.Definition.Options.Effort is not ("" or "auto")) arguments.AddRange(["-c", "model_reasoning_effort=" + System.Text.Json.JsonSerializer.Serialize(chat.Definition.Options.Effort)]);
      // The compatibility exec path cannot present native approval cards.
      if (chat.Definition.PermissionMode != TerminalDeck.Core.Mcp.AiPermissionMode.Ask && chat.Definition.PermissionMode != TerminalDeck.Core.Mcp.AiPermissionMode.Plan)
        throw new InvalidOperationException("This Codex connection cannot apply that permission mode. Use the app-server connection.");
      arguments.AddRange(["--sandbox", "read-only"]);
      if (chat.ConversationId is not null) arguments.AddRange(["resume", chat.ConversationId]);
      if (execMessage is not null)
        foreach (var image in execMessage.Media) arguments.AddRange(["--image", Path.Combine(root.DirectoryPath, "chats", Guid.Parse(chat.Definition.Id).ToString("N"), image.RelativePath)]);
      arguments.Add("-");
    }
    var environment = basePlan.Environment;
    // An OpenAI-compatible API account points Codex at its own server.
    arguments.InsertRange(0, Accounts.WindowsApiAccountLaunch.Arguments(root, provider, chat.Definition.AccountHome));
    // Every signed-in AI chat gets the app tool door (Mac: deck-control in every
    // session). The bridge fetches or renews its private key from the open app
    // on first use, so chats started before an app restart keep working.
    var executable = Path.Combine(AppContext.BaseDirectory, "tools-bridge", "TerminalDeck.ToolBridge.exe");
    if (File.Exists(executable))
    {
      var toolArgs = new[] { "--root", root.DirectoryPath, "--chat", chat.Definition.Id };
      if (provider == "claude")
      {
        var config = Path.Combine(root.DirectoryPath, "mcp", "chat-tools", chat.Definition.Id + ".json");
        WindowsPrivateDirectory.Ensure(Path.GetDirectoryName(config)!);
        File.WriteAllText(config, System.Text.Json.JsonSerializer.Serialize(new { mcpServers = new Dictionary<string, object> { ["deck-tools"] = new { command = executable, args = toolArgs } } }));
        arguments.AddRange(["--mcp-config", config]);
      }
      else if (provider == "codex")
      {
        arguments.InsertRange(0, ["-c", "mcp_servers.deck-tools.command=" + System.Text.Json.JsonSerializer.Serialize(executable),
          "-c", "mcp_servers.deck-tools.args=" + System.Text.Json.JsonSerializer.Serialize(toolArgs)]);
      }
    }
    return new WindowsProviderLaunchPlanner(root, toolsDirectory).Resolve(provider, arguments, environment, chat.Definition.Cwd);
  }
}
