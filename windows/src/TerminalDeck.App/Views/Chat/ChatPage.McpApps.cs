using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views.Chat;

internal static class ChatToolContent
{
  internal static StackPanel Render(ChatRecord record, ChatRow row, string dataDirectory, ChatMcpNavigation? mcp, Func<ChatRecord> currentRecord,
    Action<string> copy, Action<string> error, Func<ContentDialog, Task<ContentDialogResult>> showDialog, FrameworkElement scope)
  {
    var content = new StackPanel { Spacing = 8 };
    var result = record.Events.LastOrDefault(e => e.Kind == "toolResult" && e.Id == row.Id);
    if (result is null) return content;
    var parts = new List<string>();
    var objects = new List<JsonElement>();
    if (result.Data is { } data) objects.AddRange(ChatMcpApps.Objects(data));
    try { objects.AddRange(ChatMcpApps.Objects(JsonSerializer.Deserialize<JsonElement>(result.Text))); } catch (JsonException) { }
    foreach (var value in objects)
    {
      if (ChatLineProtocol.S(value, "type") == "text" && ChatLineProtocol.S(value, "text") is { Length: > 0 } text) parts.Add(text);
      if (ChatLineProtocol.S(value, "mimeType").StartsWith("image/", StringComparison.Ordinal) && ChatLineProtocol.S(value, "mediaFile") is { Length: > 0 } media)
      {
        var directory = Path.Combine(dataDirectory, "chats", Guid.Parse(record.Definition.Id).ToString("N"));
        var url = ChatRichContent.ImageUrl(Path.Combine(directory, media), directory);
        if (url.Length > 0) parts.Add("![Tool image](" + url + ")");
      }
      if (ChatLineProtocol.S(value, "type") == "resource_link" && ChatLineProtocol.S(value, "uri") is { Length: > 0 } link && ChatMarkdown.CanOpenLink(link)) parts.Add("<" + link + ">");
    }
    if (parts.Count == 0 && !row.Output.TrimStart().StartsWith('{') && !row.Output.TrimStart().StartsWith('[') && row.Output.Length > 0) parts.Add(row.Output);
    if (parts.Count > 0) content.Children.Add(ChatMarkdownView.Render(string.Join("\n\n", parts.Distinct()), copy, error, record.Definition.Cwd, dataDirectory));
    if (mcp is null) return content;
    var host = new StackPanel(); content.Children.Add(host);
    var started = false;
    host.Loaded += async (_, _) =>
    {
      if (started) return; started = true;
      try
      {
        var app = await ChatMcpApps.ResolveAsync(mcp.Manager, record, row, CancellationToken.None);
        if (app is null || host.XamlRoot is null) return;
        host.Children.Add(new RichChatWebView("", copy, error, dataDirectory, app, async parameters =>
        {
          var name = ChatLineProtocol.S(parameters, "name");
          var arguments = ChatLineProtocol.P(parameters, "arguments");
          if (arguments.ValueKind == JsonValueKind.Undefined) arguments = JsonSerializer.SerializeToElement(new { });
          var current = currentRecord();
          if (current.Ended || current.Definition.PermissionMode == AiPermissionMode.Plan) throw new InvalidOperationException("This session cannot call MCP App tools in its current mode.");
          if (current.Definition.PermissionMode is AiPermissionMode.Ask or AiPermissionMode.AcceptEdits)
          {
            var dialog = new ContentDialog { XamlRoot = scope.XamlRoot, RequestedTheme = scope.ActualTheme, Title = "Allow this MCP App tool?", Content = app.Tool + " → " + name + "\n\n" + arguments.GetRawText(), PrimaryButtonText = "Allow once", CloseButtonText = "Deny", DefaultButton = ContentDialogButton.Close };
            if (await showDialog(dialog) != ContentDialogResult.Primary) throw new InvalidOperationException("The tool call was denied.");
          }
          return await mcp.Call(app.ServerId, name, arguments, CancellationToken.None);
        }));
      }
      catch (Exception ex) when (ex is not OutOfMemoryException)
      { host.Children.Add(new TextBlock { Text = "The MCP App could not open. " + ex.Message, FontSize = 12, TextWrapping = TextWrapping.Wrap }); }
    };
    return content;
  }
}
