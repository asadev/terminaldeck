using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

public sealed partial class CloudAccountClient
{
  private long? subscriptionReadAt;
  private CloudSubscriptionSnapshot subscription = CloudSubscriptionSnapshot.Unknown;

  // Called by the account's existing refresh/wake/socket path. No new timer or independent watcher.
  private async Task ReadSubscriptionLockedAsync(Saved record, CancellationToken ct)
  {
    if (subscriptionReadAt is { } last && Now - last is >= 0 and < 300_000) return;
    subscriptionReadAt = Now;
    CloudSubscription? answer = null;
    try
    {
      var body = await SendAsync(HttpMethod.Get, configuration.Endpoints.Cloud("/subscription"), [], Bearer(record.Session.AccessToken), ct);
      answer = CloudSubscription.Read(body);
    }
    catch (Exception error) when (error is CloudFailure or HttpRequestException or JsonException || error is TaskCanceledException && !ct.IsCancellationRequested) { }
    subscription = subscription.Received(answer);
  }
}
