using System.Net;
using System.Net.Http.Headers;

namespace TerminalDeck.Core.WhatsApp;

/// Security review fault 5 (the Mac's WhatsAppRedirectGuard): a redirect is followed only to https on WhatsApp's and
/// Meta's own hosts, and every other one is refused (its response is handed back as it is, so the transport treats it as
/// a failure). The composition gives WhatsAppHttpTransport this handler over a SocketsHttpHandler with automatic
/// redirects turned off: `new WhatsAppHttpTransport(WhatsAppRedirectGuard.Make())`.
public sealed class WhatsAppRedirectGuard(HttpMessageHandler inner, IReadOnlyList<string>? hosts = null) : DelegatingHandler(inner)
{
  public const int MostHops = 5;
  private readonly IReadOnlyList<string> hosts = hosts ?? WhatsAppHttpTransport.DefaultMediaHosts;

  public static WhatsAppRedirectGuard Make() => new(new SocketsHttpHandler { AllowAutoRedirect = false });

  public static bool Allowed(Uri? url, IReadOnlyList<string> hosts)
  {
    if (url is null || !url.IsAbsoluteUri || url.Scheme != Uri.UriSchemeHttps || url.UserInfo.Length > 0) return false;
    var host = url.Host.ToLowerInvariant();
    return hosts.Any(h => host == h || host.EndsWith("." + h, StringComparison.Ordinal));
  }

  protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
  {
    var response = await base.SendAsync(request, cancellationToken).ConfigureAwait(false);
    for (var hop = 0; hop < MostHops; hop++)
    {
      if (response.StatusCode is not (HttpStatusCode.MovedPermanently or HttpStatusCode.Found or HttpStatusCode.SeeOther
        or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect)) return response;
      var location = response.Headers.Location;
      if (location is not null && !location.IsAbsoluteUri && request.RequestUri is { } from) location = new Uri(from, location);
      if (!Allowed(location, hosts)) return response;
      var method = response.StatusCode == HttpStatusCode.SeeOther ? HttpMethod.Get : request.Method;
      var next = new HttpRequestMessage(method, location);
      if (request.Headers.Authorization is AuthenticationHeaderValue auth) next.Headers.Authorization = auth;
      else if (request.Headers.TryGetValues("Authorization", out var raw)) next.Headers.TryAddWithoutValidation("Authorization", raw);
      if (method != HttpMethod.Get && request.Content is not null) next.Content = request.Content;
      response.Dispose();
      request = next;
      response = await base.SendAsync(request, cancellationToken).ConfigureAwait(false);
    }
    return response;
  }
}
