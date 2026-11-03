using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private object SidebarSnapshot(McpCallContext context) => new
  {
    pages = TerminalDeck.App.Shell.SidebarState.Catalogue.Select(p => new { p.Id, p.Title, pinned = p.Id != "Devices" && sidebar.Pinned(p.Id), presentation = p.Id == "Devices" ? "popup" : "page" }),
    pageOrder = sidebar.Read.Pages, sidebar.Read.Width, sidebar.Read.Visible, sidebar.Read.ConfirmDelete,
    archivedChats = (sidebar.Read.ArchivedChats ?? []).Where(id => context.Has("sessions", id)),
    sessionPins = sidebar.Read.SessionPins.Where(id => context.Has("sessions", id)),
    sessionOrder = sidebar.Read.SessionOrder.Where(id => context.Has("sessions", id))
  };
  private async Task ApplySidebarActionAsync(McpCallContext context, JsonElement args, CancellationToken ct)
  {
    context.Require("settings", "workspace"); await context.EnsureCurrentAsync(ct);
    var action = args.GetProperty("action").GetString();
    switch (action)
    {
      case "page-tab": OpenPageTab(args.GetProperty("pageId").GetString()!); break;
      case "page-window": var page = args.GetProperty("pageId").GetString()!; OpenPageTab(page); if (page != "Devices") PopTab("page:" + page); break;
      case "pin-page": var pinPage = args.GetProperty("pageId").GetString()!; if (pinPage == "Devices") { ShowDevicesPopup(); break; } sidebar.Pin(pinPage, args.GetProperty("pinned").GetBoolean()); break;
      case "order-pages": sidebar.OrderPages(args.GetProperty("order").EnumerateArray().Select(p => p.GetString()!).ToArray()); break;
      case "delete-session":
        var deleted = args.GetProperty("sessionId").GetString()!; context.Require("sessions", deleted);
        var row = Model.Sessions.FirstOrDefault(s => s.Id == deleted) ?? throw new McpRefusal("Choose a current session.");
        await DeleteSessionAsync(row); break;
      case "archive-chat":
        var chatId = args.GetProperty("sessionId").GetString()!; context.Require("sessions", chatId);
        ArchiveSidebarChat(chatId, args.GetProperty("archived").GetBoolean()); break;
      case "pin-session":
        var id = args.GetProperty("sessionId").GetString()!; context.Require("sessions", id);
        if (!Model.Sessions.Any(s => s.Id == id)) throw new McpRefusal("Choose a current session.");
        sidebar.PinSession(id, args.GetProperty("pinned").GetBoolean()); break;
      case "move-session":
        var source = args.GetProperty("sessionId").GetString()!; var target = args.GetProperty("targetSessionId").GetString()!;
        context.Require("sessions", source); context.Require("sessions", target); sidebar.MoveSession(source, target); break;
      case "geometry": sidebar.Geometry(args.TryGetProperty("width", out var width) ? width.GetDouble() : sidebar.Read.Width,
        args.TryGetProperty("visible", out var visible) ? visible.GetBoolean() : sidebar.Read.Visible); break;
      case "confirm-delete": sidebar.AskBeforeDelete(args.GetProperty("enabled").GetBoolean()); break;
      default: throw new McpRefusal("Choose a listed sidebar action.");
    }
  }
}
