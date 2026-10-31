using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Accounts;

// An API-key account (Mac: Add account → Connection: API key). Only metadata is
// saved here; the key lives in Windows Credential Manager under CredentialReference.
public sealed record ApiConnection(string Kind, string? BaseUrl = null, string? WorkspaceId = null, string? Model = null,
  string? CredentialReference = null, string? CheckState = null, string? CheckDetail = null, DateTimeOffset? CheckedAt = null)
{
  public bool RequiresKey => Kind != ApiKinds.CompatibleLocal;
  public bool Configured => !RequiresKey || CredentialReference is not null;
}

public static class ApiKinds
{
  public const string Anthropic = "anthropic", AnthropicToken = "anthropic-token", OpenAi = "openai",
    Compatible = "compatible", CompatibleLocal = "compatible-local", Gemini = "gemini";
  public static IReadOnlyList<(string Kind, string Name)> For(string provider) => provider switch
  {
    "claude" => [(Anthropic, "Anthropic API key"), (AnthropicToken, "Gateway bearer token")],
    "codex" => [(OpenAi, "OpenAI API key"), (Compatible, "OpenAI-compatible (Responses) server"), (CompatibleLocal, "Local server, no key")],
    "gemini" => [(Gemini, "Gemini API key")],
    _ => throw new ArgumentException("Choose Claude Code, Codex or Gemini.")
  };
  public static void Validate(string provider, ApiConnection connection)
  {
    if (For(provider).All(k => k.Kind != connection.Kind)) throw new ArgumentException("Choose a connection type for this AI.");
    if (connection.Kind is Compatible or CompatibleLocal && string.IsNullOrWhiteSpace(connection.BaseUrl)) throw new ArgumentException("Enter the server’s Base URL.");
    if (connection.BaseUrl is { Length: > 0 } url && (!Uri.TryCreate(url, UriKind.Absolute, out var parsed) || parsed.Scheme is not ("https" or "http") ||
        parsed.Scheme == "http" && !parsed.IsLoopback || url.Length > 512))
      throw new ArgumentException("Use an https:// Base URL (http:// only for this computer).");
    if (connection.WorkspaceId is { Length: > 0 } workspace && (workspace.Length > 128 || !workspace.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '-')))
      throw new ArgumentException("Enter the Workspace ID exactly as the Anthropic Console shows it.");
    if (connection.Model is { Length: > 0 } model && (model.Length > 128 || model.Any(c => char.IsControl(c) || char.IsWhiteSpace(c))))
      throw new ArgumentException("Enter a model id without spaces.");
  }
  public static void ValidateKey(string key)
  {
    if (string.IsNullOrWhiteSpace(key) || key.Length > 2048 || key.Any(c => char.IsControl(c) || char.IsWhiteSpace(c)))
      throw new ArgumentException("Paste the key on its own, without spaces or line breaks.");
  }
}

public static class ApiAccountFiles
{
  public static string PathFor(AppDataRoot root, string homeId) => Guid.TryParseExact(homeId, "N", out _) && homeId != AccountHomes.ExistingLogin
    ? Path.Combine(root.DirectoryPath, "accounts", homeId, "api.json") : throw new ArgumentException("Choose an API account.");
  public static ApiConnection? Read(AppDataRoot root, string homeId)
  {
    if (!Guid.TryParseExact(homeId, "N", out _) || homeId == AccountHomes.ExistingLogin) return null;
    var path = PathFor(root, homeId);
    if (!File.Exists(path)) return null;
    if (new FileInfo(path).Length > 16 * 1024) throw new IOException("The API account settings could not be read safely.");
    try { return JsonSerializer.Deserialize<ApiConnection>(File.ReadAllBytes(path), Json); }
    catch (JsonException) { throw new IOException("The API account settings could not be read safely."); }
  }
  public static void Write(AppDataRoot root, string homeId, ApiConnection connection)
  {
    var path = PathFor(root, homeId); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
    File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(connection, Json));
    File.Move(temporary, path, overwrite: true);
  }
  public static void Delete(AppDataRoot root, string homeId) { var path = PathFor(root, homeId); if (File.Exists(path)) File.Delete(path); }
  private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
}

// What a launch adds for an API account. Ambient keys were already removed by
// AccountEnvironment.Apply, so only this account's own values reach the CLI.
public static class ApiAccountEnvironment
{
  public const string CompatibleKeyVariable = "TERMINALDECK_API_KEY";
  public static (Dictionary<string, string> Variables, string[] Arguments) Build(string provider, ApiConnection connection, string? key)
  {
    var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); var arguments = new List<string>();
    if (connection.RequiresKey && string.IsNullOrEmpty(key)) throw new InvalidOperationException("This API account has no saved key. Edit it and paste the key.");
    switch (connection.Kind)
    {
      case ApiKinds.Anthropic: values["ANTHROPIC_API_KEY"] = key!; break;
      case ApiKinds.AnthropicToken: values["ANTHROPIC_AUTH_TOKEN"] = key!; break;
      case ApiKinds.OpenAi: values["OPENAI_API_KEY"] = key!; values["CODEX_API_KEY"] = key!; break;
      case ApiKinds.Compatible or ApiKinds.CompatibleLocal:
        if (connection.Kind == ApiKinds.Compatible) values[CompatibleKeyVariable] = key!;
        arguments.AddRange(["-c", "model_providers.terminaldeck.name=\"Terminal Deck API\"",
          "-c", "model_providers.terminaldeck.base_url=" + JsonSerializer.Serialize(connection.BaseUrl),
          "-c", "model_providers.terminaldeck.wire_api=\"responses\""]);
        if (connection.Kind == ApiKinds.Compatible) arguments.AddRange(["-c", "model_providers.terminaldeck.env_key=\"" + CompatibleKeyVariable + "\""]);
        arguments.AddRange(["-c", "model_provider=\"terminaldeck\""]);
        break;
      case ApiKinds.Gemini: values["GEMINI_API_KEY"] = key!; values["GEMINI_DEFAULT_AUTH_TYPE"] = "gemini-api-key"; break;
      default: throw new ArgumentException("Choose a connection type for this AI.");
    }
    if (provider == "claude")
    {
      // Claude Code keeps its Anthropic credentials out of Bash, hooks and MCP children.
      values["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] = "1";
      if (connection.BaseUrl is { Length: > 0 } url) values["ANTHROPIC_BASE_URL"] = url;
      if (connection.WorkspaceId is { Length: > 0 } workspace) values["ANTHROPIC_CUSTOM_HEADERS"] = "anthropic-workspace-id: " + workspace;
      if (connection.Model is { Length: > 0 } model) values["ANTHROPIC_MODEL"] = model;
    }
    if (connection.Kind == ApiKinds.OpenAi && connection.BaseUrl is { Length: > 0 } openAiUrl) values["OPENAI_BASE_URL"] = openAiUrl;
    if (provider == "gemini")
    {
      if (connection.BaseUrl is { Length: > 0 } geminiUrl) values["GOOGLE_GEMINI_BASE_URL"] = geminiUrl;
      if (connection.Model is { Length: > 0 } geminiModel) values["GEMINI_MODEL"] = geminiModel;
    }
    return (values, arguments.ToArray());
  }
}

// "Check key": one read-only list-models request. Valid / Invalid key / No access /
// unavailable are told apart; a failed check never removes the saved key.
public static class ApiKeyCheck
{
  public static async Task<(string State, string? Detail)> RunAsync(string provider, ApiConnection connection, string? key, HttpClient http, CancellationToken ct)
  {
    var root = connection.BaseUrl is { Length: > 0 } custom ? custom.TrimEnd('/') : connection.Kind switch
    {
      ApiKinds.Anthropic or ApiKinds.AnthropicToken => "https://api.anthropic.com",
      ApiKinds.OpenAi => "https://api.openai.com/v1",
      ApiKinds.Gemini => "https://generativelanguage.googleapis.com/v1beta",
      _ => throw new ArgumentException("Enter the server’s Base URL.")
    };
    var path = connection.Kind is ApiKinds.Anthropic or ApiKinds.AnthropicToken ? (root.EndsWith("/v1") ? root : root + "/v1") + "/models" : root + "/models";
    using var request = new HttpRequestMessage(HttpMethod.Get, path);
    switch (connection.Kind)
    {
      case ApiKinds.Anthropic: request.Headers.Add("x-api-key", key); request.Headers.Add("anthropic-version", "2023-06-01"); break;
      case ApiKinds.AnthropicToken: request.Headers.Authorization = new("Bearer", key); request.Headers.Add("anthropic-version", "2023-06-01"); break;
      case ApiKinds.Gemini: request.Headers.Add("x-goog-api-key", key); break;
      case ApiKinds.CompatibleLocal: break;
      default: request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key); break;
    }
    if (connection.WorkspaceId is { Length: > 0 } workspace) request.Headers.Add("anthropic-workspace-id", workspace);
    try
    {
      using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(20));
      using var response = await http.SendAsync(request, deadline.Token);
      if (response.IsSuccessStatusCode) return ("valid", null);
      var reason = await Reason(response, deadline.Token);
      return response.StatusCode switch
      {
        HttpStatusCode.Unauthorized => ("invalid", reason),
        HttpStatusCode.Forbidden or HttpStatusCode.PaymentRequired => ("no-access", reason),
        HttpStatusCode.BadRequest when connection.Kind == ApiKinds.Gemini => ("invalid", reason),
        _ => ("unavailable", "The service answered " + (int)response.StatusCode + ". Try again later.")
      };
    }
    catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException && !ct.IsCancellationRequested)
    { return ("unavailable", "The service could not be reached. Check the connection and the Base URL."); }
  }
  // The provider's own sentence ("API key expired"), never the key or headers.
  private static async Task<string?> Reason(HttpResponseMessage response, CancellationToken ct)
  {
    try
    {
      var text = await response.Content.ReadAsStringAsync(ct);
      if (text.Length > 16 * 1024) return null;
      using var document = JsonDocument.Parse(text);
      var error = document.RootElement.TryGetProperty("error", out var e) ? e : document.RootElement;
      var message = error.ValueKind == JsonValueKind.Object && error.TryGetProperty("message", out var m) ? m.GetString() : error.ValueKind == JsonValueKind.String ? error.GetString() : null;
      return message is { Length: > 0 and <= 300 } ? message : null;
    }
    catch (JsonException) { return null; }
  }
}
