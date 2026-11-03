using System.Diagnostics;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Platform.Windows.Accounts;

public interface IGeminiAccountReadiness
{
  ValueTask<bool> VerifyAsync(ProcessLaunch launch, CancellationToken ct);
}

// Ask the installed provider to verify/refresh its cached Google login. There
// is no model prompt, session creation, browser login or copied OAuth secret.
public sealed class GeminiAccountReadiness : IGeminiAccountReadiness
{
  public async ValueTask<bool> VerifyAsync(ProcessLaunch launch, CancellationToken ct)
  {
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
    deadline.CancelAfter(TimeSpan.FromSeconds(30));
    var token = deadline.Token;
    var start = new ProcessStartInfo(launch.Executable)
    {
      WorkingDirectory = launch.WorkingDirectory, UseShellExecute = false, CreateNoWindow = true,
      RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
      StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false)
    };
    foreach (var argument in launch.Arguments) start.ArgumentList.Add(argument);
    start.Environment.Clear(); foreach (var pair in launch.Environment) start.Environment[pair.Key] = pair.Value;
    // Expired/revoked credentials must fail quietly, never open a sign-in page.
    start.Environment["NO_BROWSER"] = "true";
    using var process = Process.Start(start) ?? throw new IOException("Gemini could not check this account. Try refreshing it again.");
    var diagnostics = DrainAsync(process.StandardError, token);
    try
    {
      async ValueTask<JsonElement> Request(string id, string method, object parameters)
      {
        await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { jsonrpc = "2.0", id, method, @params = parameters }).AsMemory(), token);
        await process.StandardInput.FlushAsync(token);
        var total = 0;
        while (true)
        {
          var line = await ReadLineAsync(process.StandardOutput, token);
          total += line.Length;
          if (total > 256 * 1024) throw new IOException("Gemini's account check did not return a usable reply.");
          using var document = JsonDocument.Parse(line, new JsonDocumentOptions { MaxDepth = 32 });
          var row = document.RootElement;
          if (row.ValueKind != JsonValueKind.Object) throw new JsonException();
          // A readiness check cannot answer permission requests or run tools.
          if (row.TryGetProperty("method", out _) && row.TryGetProperty("id", out _))
            throw new IOException("Gemini asked for an interactive action while checking this account.");
          if (row.TryGetProperty("id", out var reply) && reply.ValueKind == JsonValueKind.String && reply.GetString() == id) return row.Clone();
        }
      }
      var hello = await Request("account-hello", "initialize", new { protocolVersion = 1,
        clientInfo = new { name = "terminaldeck-account-check", version = "1" }, clientCapabilities = new { terminal = false } });
      if (!hello.TryGetProperty("result", out var initialized) || initialized.ValueKind != JsonValueKind.Object ||
          !initialized.TryGetProperty("protocolVersion", out var version) || !version.TryGetInt32(out var number) || number != 1 ||
          !initialized.TryGetProperty("authMethods", out var methods) || methods.ValueKind != JsonValueKind.Array ||
          !methods.EnumerateArray().Any(m => m.ValueKind == JsonValueKind.Object && m.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String && id.GetString() == "oauth-personal"))
        throw new IOException("This Gemini version cannot verify its saved Google account. Update Gemini and try again.");
      var answer = await Request("account-auth", "authenticate", new { methodId = "oauth-personal" });
      if (answer.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object)
      {
        if (error.TryGetProperty("code", out var code) && code.TryGetInt32(out var errorCode) && errorCode == -32000) return false;
        throw new IOException("Gemini could not verify this account. Update Gemini or try refreshing again.");
      }
      if (!answer.TryGetProperty("result", out var result) || result.ValueKind != JsonValueKind.Object) throw new JsonException();
      return true;
    }
    catch (OperationCanceledException) when (!ct.IsCancellationRequested)
    { throw new IOException("Gemini's account check timed out. Check the connection and try refreshing again."); }
    catch (JsonException) { throw new IOException("Gemini's account check did not return a usable reply."); }
    finally
    {
      deadline.Cancel();
      if (!process.HasExited) process.Kill(entireProcessTree: true);
      await process.WaitForExitAsync(CancellationToken.None);
      try { await diagnostics; } catch (Exception ex) when (ex is IOException or OperationCanceledException) { }
    }
  }
  private static async ValueTask<string> ReadLineAsync(StreamReader reader, CancellationToken ct)
  {
    var line = new StringBuilder(); var single = new char[1];
    while (await reader.ReadAsync(single.AsMemory(), ct) != 0)
    {
      if (single[0] == '\n') return line.ToString().TrimEnd('\r');
      if (line.Length >= 64 * 1024) throw new IOException("Gemini's account check reply is too large.");
      line.Append(single[0]);
    }
    throw new IOException("Gemini stopped before it could check this account. Try refreshing it again.");
  }
  private static async Task DrainAsync(StreamReader reader, CancellationToken ct)
  {
    var buffer = new char[2048]; var total = 0; int read;
    while ((read = await reader.ReadAsync(buffer.AsMemory(), ct)) != 0)
      if ((total += read) > 256 * 1024) throw new IOException("Gemini's account check could not finish.");
  }
}
