using System.Diagnostics;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Platform.Windows.Accounts;

// Startup only: no user prompt, turn/start, session/prompt, authentication or
// tools are sent. The child uses the selected account's isolated environment.
public static class WindowsModelDiscovery
{
  public static string[] Arguments(string provider) => provider switch
  {
    "claude" => ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--permission-mode", "plan", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"],
    "codex" => ["app-server"],
    "gemini" => ["--acp"],
    _ => throw new ArgumentException("Choose a coding AI.")
  };

  public static async ValueTask<IReadOnlyList<ProviderModel>> DiscoverAsync(string provider, ProcessLaunch launch, CancellationToken ct, bool accountOnly = false)
  {
    var start = new ProcessStartInfo(launch.Executable)
    {
      WorkingDirectory = launch.WorkingDirectory, UseShellExecute = false, CreateNoWindow = true,
      RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
    };
    foreach (var argument in launch.Arguments) start.ArgumentList.Add(argument);
    start.Environment.Clear(); foreach (var (name, value) in launch.Environment) start.Environment[name] = value;
    var process = Process.Start(start) ?? throw new IOException("The AI could not check its models.");
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(45));
    // Error output is read until the helper ends, also after this call has returned.
    _ = DrainAsync(process.StandardError, CancellationToken.None).ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
    try
    {
      async Task SendAsync(object value) => await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(value).AsMemory(), deadline.Token);
      async Task<JsonElement> ReplyAsync(string id)
      {
        for (var count = 0; count < 256; count++)
        {
          var line = await LineAsync(process.StandardOutput, deadline.Token);
          using var document = JsonDocument.Parse(line); var message = document.RootElement;
          var claude = provider == "claude";
          if (claude && Text(message, "type") == "control_response")
          {
            var response = message.GetProperty("response");
            if (Text(response, "request_id") != id) continue;
            if (Text(response, "subtype") == "error") throw new IOException("The AI could not report its models. Refresh after signing in.");
            return response.GetProperty("response").Clone();
          }
          if (message.TryGetProperty("id", out var replyId) && replyId.ToString() == id)
          {
            if (message.TryGetProperty("error", out _)) throw new IOException("The AI could not report its models. Refresh after signing in.");
            return message.GetProperty("result").Clone();
          }
          // A catalogue probe must never approve a server's request to act.
          if (message.TryGetProperty("method", out _) && message.TryGetProperty("id", out var requestId))
            await SendAsync(new { jsonrpc = "2.0", id = requestId.Clone(), error = new { code = -32601, message = "Model discovery cannot perform actions." } });
          if (claude && Text(message, "type") == "control_request")
            await SendAsync(new { type = "control_response", response = new { subtype = "error", request_id = Text(message, "request_id"), error = "Model discovery cannot perform actions." } });
        }
        throw new IOException("The AI did not return a model list.");
      }
      JsonElement result;
      if (provider == "claude")
      {
        await SendAsync(new { type = "control_request", request_id = "models", request = new { subtype = "initialize", hooks = new { } } });
        result = await ReplyAsync("models");
      }
      else if (provider == "codex")
      {
        await SendAsync(new { id = "init", method = "initialize", @params = new { clientInfo = new { name = "deck_models", version = "1" } } });
        _ = await ReplyAsync("init");
        await SendAsync(new { method = "initialized" });
        if (accountOnly)
        {
          await SendAsync(new { id = "account", method = "account/read", @params = new { refreshToken = false } });
          result = await ReplyAsync("account");
          if (!result.TryGetProperty("account", out var account) || account.ValueKind != JsonValueKind.Object) return [];
          var email = Text(account, "email");
          // The plan ("plus", "pro") rides along as a second row for the account card.
          var plan = Text(account, "planType");
          return email.Length > 0 ? plan.Length > 0 ? [new ProviderModel("account", email, 0), new ProviderModel("plan", plan, 0)] : [new ProviderModel("account", email, 0)] : [];
        }
        var models = new List<ProviderModel>(); string? cursor = null;
        for (var page = 0; page < 32; page++)
        {
          await SendAsync(new { id = "models", method = "model/list", @params = new { cursor, limit = 100 } });
          result = await ReplyAsync("models"); models.AddRange(Parse(provider, result));
          cursor = Text(result, "nextCursor");
          if (cursor.Length == 0) return Validate(models);
        }
        throw new IOException("The AI returned too many model pages.");
      }
      else
      {
        await SendAsync(new { jsonrpc = "2.0", id = "init", method = "initialize", @params = new { protocolVersion = 1, clientCapabilities = new { } } });
        _ = await ReplyAsync("init");
        await SendAsync(new { jsonrpc = "2.0", id = "models", method = "session/new", @params = new { cwd = launch.WorkingDirectory, mcpServers = Array.Empty<object>() } });
        result = await ReplyAsync("models");
      }
      return Parse(provider, result);
    }
    catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new IOException("The AI took too long to report its models. Refresh to try again."); }
    catch (Exception ex) when (ex is JsonException or InvalidOperationException or KeyNotFoundException)
    { throw new IOException("The AI's model list could not be read. Update the CLI and refresh."); }
    finally
    {
      // Never end the helper the instant it answers: Claude Code may be renewing the
      // sign-in, and a cut renewal blanks the login (saba-pc, 1 Nov). It is let go
      // gently in the background and killed only if it hangs with no renewal running.
      AiHelperStop.Release(process, provider, launch.Environment);
    }
  }

  public static IReadOnlyList<ProviderModel> Parse(string provider, JsonElement data)
  {
    JsonElement rows;
    if (provider == "claude")
    {
      if (!data.TryGetProperty("models", out rows) && !data.TryGetProperty("supported_models", out rows)) throw new IOException("Claude Code did not report a model list.");
    }
    else if (provider == "codex") rows = data.GetProperty("data");
    else rows = data.GetProperty("models").GetProperty("availableModels");
    if (rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > 1024) throw new IOException("The AI's model list could not be read.");
    var models = new List<ProviderModel>();
    foreach (var row in rows.EnumerateArray())
    {
      if (row.TryGetProperty("hidden", out var hidden) && hidden.ValueKind == JsonValueKind.True) continue;
      var id = Text(row, provider == "claude" ? "value" : provider == "gemini" ? "modelId" : "model");
      if (id.Length == 0) id = Text(row, "id");
      if (id is "default" or "auto") continue;
      var name = Text(row, provider == "gemini" ? "name" : "displayName");
      if (name.Length == 0) name = id;
      if (provider == "claude")
      {
        // Claude Code lists aliases ("opus" · "Opus"); its description names the
        // actual model ("Opus 5.5 · Best for…"). People see "Opus 5.5", and the full
        // id is selected so the chip and the saved choice agree.
        var described = Text(row, "description").Split(" · ")[0].Trim();
        if (described.Length is > 0 and <= 40 && described.StartsWith(name, StringComparison.OrdinalIgnoreCase)) name = described;
        var resolved = Text(row, "resolvedModel");
        if (resolved.StartsWith("claude-", StringComparison.Ordinal) && !id.Contains('[') && !id.StartsWith("claude-", StringComparison.Ordinal)) id = resolved;
      }
      var context = 0;
      foreach (var field in new[] { "contextWindow", "context_window", "contextTokens", "inputTokenLimit" })
        if (row.TryGetProperty(field, out var tokens) && tokens.ValueKind == JsonValueKind.Number && tokens.TryGetInt32(out var value) && value > 0) { context = value; break; }
      // Claude's long-context variants carry their own exact selectable value.
      // A missing capacity stays unknown; never claim a made-up token limit.
      if (id.EndsWith("[1m]", StringComparison.OrdinalIgnoreCase)) context = Math.Max(context, 1_000_000);
      var isDefault = row.TryGetProperty("isDefault", out var preferred) && preferred.ValueKind == JsonValueKind.True;
      if (provider == "gemini" && data.TryGetProperty("models", out var selection)) isDefault |= Text(selection, "currentModelId") == id;
      var efforts = new List<string>();
      foreach (var field in new[] { "supportedReasoningEfforts", "supportedEffortLevels", "effortLevels" })
        if (row.TryGetProperty(field, out var levels) && levels.ValueKind == JsonValueKind.Array)
          foreach (var level in levels.EnumerateArray())
          {
            var effort = level.ValueKind == JsonValueKind.String ? level.GetString() ?? "" : Text(level, "reasoningEffort");
            if (effort is "low" or "medium" or "high" or "xhigh" or "max") efforts.Add(effort);
          }
      models.Add(new(id, name, context, context >= 1_000_000, isDefault, efforts.Count == 0 ? null : efforts.Distinct().ToArray()));
    }
    return Validate(models);
  }
  public static IReadOnlyList<ProviderModel> WithCodexCapacities(IReadOnlyList<ProviderModel> models, string home)
  {
    var path = Path.Combine(home, "models_cache.json");
    if (!File.Exists(path)) return models;
    if (new FileInfo(path).Length > 4 * 1024 * 1024 || File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint)) throw new IOException("The account’s model cache could not be read safely.");
    try
    {
      using var document = JsonDocument.Parse(File.ReadAllBytes(path));
      if (!document.RootElement.TryGetProperty("models", out var rows) || rows.ValueKind != JsonValueKind.Array) return models;
      return models.Select(model =>
      {
        var matches = rows.EnumerateArray().Where(row => Text(row, "slug") == model.Id).ToArray();
        if (matches.Length != 1 || !matches[0].TryGetProperty("context_window", out var window) || window.ValueKind != JsonValueKind.Number || !window.TryGetInt32(out var size) || size <= 0) return model;
        return model with { ContextTokens = size, SupportsOneMillion = size >= 1_000_000 };
      }).ToArray();
    }
    catch (JsonException) { return models; }
  }
  private static IReadOnlyList<ProviderModel> Validate(List<ProviderModel> models)
  {
    if (models.Count == 0 || models.Any(m => string.IsNullOrWhiteSpace(m.Id) || m.Id.Length > 160 || m.Id.Any(char.IsControl) || m.Name.Length > 256 || m.Name.Any(char.IsControl)) || models.Select(m => m.Id).Distinct().Count() != models.Count)
      throw new IOException("The AI did not return a usable model list.");
    return models.ToArray();
  }
  private static string Text(JsonElement value, string name) => value.TryGetProperty(name, out var field) && field.ValueKind == JsonValueKind.String ? field.GetString() ?? "" : "";
  private static async Task<string> LineAsync(StreamReader reader, CancellationToken ct)
  {
    var line = new StringBuilder(); var buffer = new char[1];
    while (await reader.ReadAsync(buffer.AsMemory(), ct) != 0)
    {
      if (buffer[0] == '\n') return line.ToString();
      if (line.Length >= 2 * 1024 * 1024) throw new IOException("The AI's model reply is too large.");
      line.Append(buffer[0]);
    }
    throw new IOException("The AI closed before returning its models.");
  }
  private static async Task DrainAsync(StreamReader reader, CancellationToken ct)
  {
    var buffer = new char[2048];
    while (await reader.ReadAsync(buffer.AsMemory(), ct) != 0) { }
  }
}
