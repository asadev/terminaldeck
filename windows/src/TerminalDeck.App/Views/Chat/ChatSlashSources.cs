using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Views.Chat;

// What the "/" menu offers for one chat: the AI's reported list plus the team's
// skills and commands on disk for the chat's folder, its project's other folders
// and the account's own config folder.
internal static class ChatSlashSources
{
  public static IReadOnlyList<ChatSlashCommand> For(ChatRecord? chat, string provider, string cwd, string? accountHome, AppDataRoot? root)
  {
    // The AI's own list from its newest start; after an app restart the new worker has not
    // reported yet, so the previous report is used rather than showing no menu at all.
    var fields = chat is null ? null : ChatProviderSnapshot.Read(chat).Fields
      ?? (chat.Events.LastOrDefault(e => e.Kind == "providerInit")?.Data is { } saved && ChatLineProtocol.P(saved, "fields") is { ValueKind: System.Text.Json.JsonValueKind.Object } last ? last : null);
    IReadOnlyList<string> extra = root is null ? [] : TerminalDeck.Core.Projects.ProjectStartFolders.ExtraFolders(root, cwd);
    string? user = null;
    if (root is not null && accountHome is not null)
    {
      try { user = new TerminalDeck.Platform.Windows.WindowsProviderLaunchPlanner(root, TerminalDeck.Platform.Windows.WindowsProviderLaunchPlanner.BundledToolsDirectory).AccountHome(provider, accountHome); }
      catch (Exception ex) when (ex is ArgumentException or InvalidOperationException) { }
    }
    return ChatSlashCommands.Catalogue(provider, fields, cwd, extra.Select(f => f.Replace('/', Path.DirectorySeparatorChar)).ToArray(), user);
  }
  public static IReadOnlyList<ChatSlashCommand> For(ChatRecord chat, AppDataRoot? root) =>
    For(chat, chat.Definition.Provider, chat.Definition.Cwd, chat.Definition.AccountHome, root);
}
