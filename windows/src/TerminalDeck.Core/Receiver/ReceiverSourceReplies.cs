using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Code;

namespace TerminalDeck.Core.Receiver;

public sealed partial class ReceiverSourceService
{
  public ReceiverReplyOutcome[] Replies(string item) { lock (gate) return State().Replies.Where(r => r.ItemId == item).ToArray(); }
  public async Task<ReceiverReplyOutcome> ReplyAsync(string itemId, string text, CancellationToken ct = default, HttpClient? client = null)
  {
    if (string.IsNullOrWhiteSpace(text) || text.Length > 24000 || text.Contains('\0')) throw new ArgumentException("Use a reply from 1 to 24,000 characters.");
    await replyGate.WaitAsync(ct);
    try
    {
      var item = receiver.Item(itemId); var source = Source(item.SourceId); if (!source.Enabled) throw new InvalidOperationException("This source is paused.");
      var configuration = Read(source.Id); var channel = configuration.Reply ?? throw new InvalidOperationException("Replies are not enabled for this source.");
      var digest = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(itemId + "\n" + text)));
      var previous = Replies(itemId).LastOrDefault(r => r.TextDigest == digest); if (previous is not null && previous.State != "failed") return previous;
      var outcome = new ReceiverReplyOutcome(Guid.NewGuid().ToString("N"), itemId, Time.GetUtcNow(), digest, "sending"); SaveReply(outcome);
      try
      {
        var context = item.Payload is { ValueKind: JsonValueKind.Object } payload ? JsonNode.Parse(payload.GetRawText())!.AsObject() : new JsonObject(); context["reply"] = text;
        string reference;
        if (channel.Via == "github")
        {
          var value = JsonSerializer.SerializeToElement(context); var repo = ReceiverPayloadMapper.Template(channel.Repository, value); var number = ReceiverPayloadMapper.Template(channel.Number, value);
          if (!Regex.IsMatch(repo, "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") || !long.TryParse(number, out var issue) || issue < 1) throw new ArgumentException("The event does not identify a GitHub repository and issue number.");
          var result = await (process ?? new CodeProcessRunner()).RunAsync("gh", ["api", "repos/" + repo + "/issues/" + issue + "/comments", "--method", "POST", "--input", "-"], Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), TimeSpan.FromSeconds(30), ct, JsonSerializer.Serialize(new { body = text }));
          if (!result.Ok) throw new IOException("GitHub did not confirm the reply. Its private diagnostic text was omitted.");
          using var response = JsonDocument.Parse(result.Output); reference = response.RootElement.TryGetProperty("html_url", out var url) ? url.GetString() ?? "GitHub accepted the reply" : "GitHub accepted the reply";
        }
        else
        {
          if (configuration.ReplySecretReference is not null) context["secret"] = new JsonObject { ["reply"] = await SecretAsync(configuration.ReplySecretReference, ct) };
          var value = JsonSerializer.SerializeToElement(context); var address = ReceiverPayloadMapper.Template(channel.Url, value);
          if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme != "https" || !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Fragment)) throw new ArgumentException("Use a fixed HTTPS reply address without embedded credentials.");
          using var request = new HttpRequestMessage(new HttpMethod(channel.Method), uri);
          var contentType = "application/json";
          foreach (var (key, template) in channel.Headers ?? [])
          {
            if (key.Equals("Host", StringComparison.OrdinalIgnoreCase) || key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase) || key.Contains('\r') || key.Contains('\n')) throw new ArgumentException("This reply header is not allowed.");
            var header = ReceiverPayloadMapper.Template(template, value); if (header.Contains('\r') || header.Contains('\n')) throw new ArgumentException("A reply header contains a line break.");
            if (key.Equals("Content-Type", StringComparison.OrdinalIgnoreCase)) contentType = header; else request.Headers.Add(key, header);
          }
          var json = contentType.StartsWith("application/json", StringComparison.OrdinalIgnoreCase) || contentType.Split(';')[0].EndsWith("+json", StringComparison.OrdinalIgnoreCase);
          var body = ReceiverPayloadMapper.Template(channel.Body, value, jsonEscape: json); if (json) { using var parsed = JsonDocument.Parse(body); }
          request.Content = new StringContent(body, Encoding.UTF8); request.Content.Headers.ContentType = System.Net.Http.Headers.MediaTypeHeaderValue.Parse(contentType);
          using var owned = client is null ? new HttpClient(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false }) { Timeout = TimeSpan.FromSeconds(30) } : null;
          using var response = await (client ?? owned!).SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
          if (!response.IsSuccessStatusCode) throw new IOException("The reply channel did not confirm delivery. Review its configuration before retrying.");
          reference = "HTTP " + (int)response.StatusCode;
        }
        outcome = outcome with { State = "sent", Reference = reference, At = Time.GetUtcNow() }; SaveReply(outcome); return outcome;
      }
      catch (Exception error) when (error is IOException or HttpRequestException or OperationCanceledException or ArgumentException or JsonException or FormatException)
      {
        outcome = outcome with { State = error is ArgumentException or JsonException or FormatException ? "failed" : "uncertain", Problem = error is ArgumentException ? error.Message : "Delivery was not confirmed. It may have reached the sender; check there before sending another reply.", At = Time.GetUtcNow() }; SaveReply(outcome); return outcome;
      }
    }
    finally { replyGate.Release(); }
  }
  private void SaveReply(ReceiverReplyOutcome reply)
  { lock (gate) { var state = State(); store.Save(state with { Replies = state.Replies.Where(r => r.Id != reply.Id).Append(reply).TakeLast(1000).ToArray() }); } Changed?.Invoke(); }
}
