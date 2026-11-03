using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Chats;

public sealed class WindowsChatFork(AppDataRoot root, string toolsDirectory)
{
  public async ValueTask<string> ForkCodexAsync(ChatRecord parent, string? lastTurnId, CancellationToken ct)
  {
    if (parent.Definition.Provider != "codex" || string.IsNullOrEmpty(parent.ConversationId)) throw new ArgumentException("Choose a Codex chat with a saved provider conversation.");
    var launch = new WindowsChatLaunchPlanner(root, toolsDirectory).Plan(parent);
    var start = new ProcessStartInfo(launch.Executable) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = launch.WorkingDirectory, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
    foreach (var argument in launch.Arguments) start.ArgumentList.Add(argument);
    start.Environment.Clear(); foreach (var pair in launch.Environment) start.Environment[pair.Key] = pair.Value;
    using var process = Process.Start(start) ?? throw new IOException("Codex could not open a separate fork connection.");
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(30));
    var errors = DrainErrorsAsync();
    async Task DrainErrorsAsync() { var bytes = new char[4096]; try { while (await process.StandardError.ReadAsync(bytes.AsMemory(), deadline.Token) > 0) { } } catch (OperationCanceledException) { } }
    async Task<JsonElement> RequestAsync(string id, string method, object parameters)
    {
      await process.StandardInput.WriteLineAsync(ChatLineProtocol.Rpc(method, parameters, id).AsMemory(), deadline.Token); await process.StandardInput.FlushAsync(deadline.Token);
      while (true)
      {
        var line = await process.StandardOutput.ReadLineAsync(deadline.Token); if (line is null || line.Length > ChatLineProtocol.MaximumLineCharacters) throw new IOException("The provider fork connection ended without a usable answer.");
        using var document = JsonDocument.Parse(line); var row = document.RootElement;
        if (!row.TryGetProperty("id", out var responseId) || responseId.ValueKind != JsonValueKind.String || responseId.GetString() != id) continue;
        if (row.TryGetProperty("error", out _)) throw new IOException("Codex refused the fork. The original conversation was kept.");
        return row.GetProperty("result").Clone();
      }
    }
    try
    {
      await RequestAsync("initialize-fork", "initialize", new { clientInfo = new { name = "terminaldeck-fork", version = "1" }, capabilities = new { experimentalApi = true } });
      await process.StandardInput.WriteLineAsync(ChatLineProtocol.Rpc("initialized").AsMemory(), deadline.Token);
      var parameters = new JsonObject { ["threadId"] = parent.ConversationId, ["ephemeral"] = false, ["excludeTurns"] = true };
      if (lastTurnId is not null) parameters["lastTurnId"] = lastTurnId;
      var result = await RequestAsync("fork", "thread/fork", parameters); var thread = result.GetProperty("thread"); var id = thread.GetProperty("id").GetString();
      if (string.IsNullOrEmpty(id) || id == parent.ConversationId || id.Length > 128 || thread.TryGetProperty("forkedFromId", out var origin) && origin.ValueKind == JsonValueKind.String && origin.GetString() != parent.ConversationId) throw new IOException("Codex did not confirm a separate conversation from this chat.");
      return id;
    }
    finally
    {
      // The short-lived fork process owns Codex's new-thread writer lock. It
      // must exit before another chat can resume that thread, never later. It is
      // asked to end by closing its input; killed only if it hangs, never while
      // a sign-in renewal is under way.
      await TerminalDeck.Core.Accounts.AiHelperStop.StopAsync(process, parent.Definition.Provider, launch.Environment, grace: TimeSpan.FromSeconds(5));
      deadline.Cancel(); await errors;
    }
  }
}
