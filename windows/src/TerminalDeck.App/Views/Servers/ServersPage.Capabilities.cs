using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Servers;
using static TerminalDeck.App.Views.Servers.ServerUi;

namespace TerminalDeck.App.Views.Servers;

public sealed partial class ServersPage
{
  private void CodingAis(StackPanel body, SavedServer server)
  {
    body.Children.Add(Header(Words("Coding AIs", 15), Button("Check again", async () => await Model.LoadCodingAisAsync())));
    if (Model.CodingAis is not { } rows)
    {
      body.Children.Add(Card(Words(Model.IsError ? "Coding AIs could not be read. Check the connection and try again." : "Checking the coding AIs installed for this server's SSH user…", muted: true))); return;
    }
    var list = Stack(0);
    foreach (var ai in rows)
    {
      var facts = Stack(3); var name = Words(ai.Name, 13); name.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; facts.Children.Add(name);
      facts.Children.Add(Words(ai.Installed ? (ai.Version.Length > 0 ? ai.Version : "Installed") + " · " + (ai.SignIn switch { "yes" => "Signed in", "no" => "Not signed in", _ => "Sign-in not reported" }) : "Not installed", 12, true));
      if (ai.Path.Length > 0) { var path = Words(ai.Path, 11, true); path.TextTrimming = TextTrimming.CharacterEllipsis; path.MaxLines = 1; ToolTipService.SetToolTip(path, ai.Path); facts.Children.Add(path); }
      if (!string.IsNullOrEmpty(ai.Why)) facts.Children.Add(Words(ai.Why, 12, true));
      var actions = Horizontal();
      void Offer(string label, string operation, bool available)
      {
        if (!available) return;
        var button = Button(label, () => ChangeCodingAiAsync(server, ai, operation)); button.IsEnabled = !server.Access.LookOnly && !Model.IsBusy; actions.Children.Add(button);
      }
      if (!ai.Installed) Offer("Install", "install", ai.CanInstall);
      else
      {
        Offer(ai.SignIn == "yes" ? "Sign in again" : "Sign in", "signin", ai.CanSignIn);
        Offer("Sign out", "signout", ai.CanSignOut && ai.SignIn != "no");
        if (ai.CanRemove)
        {
          var menu = new MenuFlyout(); AddMenu(menu, "Remove…", () => ChangeCodingAiAsync(server, ai, "remove"), !server.Access.LookOnly && !Model.IsBusy);
          var more = IconButton("more", "Actions for " + ai.Name, () => Task.CompletedTask); more.Flyout = menu; actions.Children.Add(more);
        }
      }
      list.Children.Add(DataRow(new BrandIcon { Kind = ai.Provider, Width = 28, Height = 28 }, facts, actions));
    }
    if (rows.Count == 0) list.Children.Add(Words("No coding AIs were reported for this SSH user.", muted: true));
    body.Children.Add(Card(list));
    if (host is IServerSigninUiHost signin && signin.ReadServerSigninState(server.Id) is { } state) body.Children.Add(Words(state.Message, 12, true));
  }
  private async Task ChangeCodingAiAsync(SavedServer server, ServerCodingAi ai, string operation)
  {
    await Model.RunAsync(async () =>
    {
      var result = await Model.Servers.ChangeCodingAiAsync(server.Id, ai.Provider, operation, ServerCaller.Person);
      if (result.SessionId is { } session) host.OpenSession(session);
    }, "Waiting for approval…", "Continue in the server terminal. Check Coding AIs again when it finishes.");
  }
  private void Websites(StackPanel body, SavedServer server)
  {
    body.Children.Add(Header(Words("Websites", 15), Button("Check again", async () => await Model.LoadWebsitesAsync())));
    if (Model.Websites is not { } rows)
    {
      body.Children.Add(Card(Words(Model.IsError ? "Websites could not be read. Check the connection and try again." : "Checking this server's configured websites…", muted: true))); return;
    }
    var list = Stack(0);
    foreach (var site in rows)
    {
      var facts = Stack(3); var name = Words(site.Name, 13); name.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; facts.Children.Add(name);
      if (site.Detail.Length > 0) facts.Children.Add(Words(site.Detail, 12, true));
      if (site.Url is not null) facts.Children.Add(Words(site.Url, 12, true));
      var actions = Horizontal();
      if (site.Url is not null)
      {
        actions.Children.Add(Button("Open", () => WebsiteActionAsync(server, site, false)));
        actions.Children.Add(Button("Copy address", () => WebsiteActionAsync(server, site, true)));
      }
      list.Children.Add(DataRow(Icon("browser"), facts, actions));
    }
    if (rows.Count == 0) { var empty = Words("No websites found", 13, true); empty.MinHeight = 100; empty.VerticalAlignment = VerticalAlignment.Center; list.Children.Add(empty); }
    body.Children.Add(Card(list));
  }
  private Task WebsiteActionAsync(SavedServer server, ServerWebsite site, bool copy) => Model.RunAsync(async () =>
  {
    var current = await Model.Servers.WebsiteAsync(server.Id, site.Id, ServerCaller.Person);
    if (current.Url is not { } url || !Uri.TryCreate(url, UriKind.Absolute, out var address) || address.Scheme is not ("http" or "https")) throw new ServerRefusal("This website has no current web address.");
    if (copy) Copy(url); else await host.OpenWebsiteAsync(url);
  }, copy ? "Checking the current address…" : "Opening website…", copy ? "Address copied." : "Website opened.");
}
