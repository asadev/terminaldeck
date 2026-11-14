using System.Text;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// Settings like the Mac (14 Nov): Profile first with the site's own profile; names and dates, never ids.
public sealed class CloudProfileTests
{
  private const string Me = """
    {"name":"Pat Doe","username":"pat","email":"pat@example.com","picture":"https://api.terminaldeck.dev/profile/v1/picture/pat?v=3",
     "pictureSource":"github","memberSince":"2026-10-02T09:00:00Z",
     "waysToSignIn":[
       {"id":"7f1c0b9e-1111-4c4c-9d9d-000000000001","provider":"github","providerName":"GitHub","account":"@pat","connectedSince":"2026-11-03T10:00:00Z","lastUsed":"2026-11-14T08:00:00Z","canRemove":true},
       {"id":"7f1c0b9e-1111-4c4c-9d9d-000000000002","provider":"google","account":"pat@example.com","connectedSince":"2026-11-04T10:00:00Z","canRemove":true}]}
    """;

  [Fact]
  public void The_profile_shows_name_email_picture_and_ways_without_any_id()
  {
    var profile = CloudProfile.Read(Encoding.UTF8.GetBytes(Me));
    Assert.Equal("Pat Doe", profile.Name);
    Assert.Equal("pat@example.com", profile.Email);
    Assert.Equal("https://api.terminaldeck.dev/profile/v1/picture/pat?v=3", profile.Picture?.AbsoluteUri);
    Assert.Equal(new[] { "GitHub", "Google" }, profile.Ways.Select(w => w.ProviderName).ToArray());
    var shown = string.Join(" ", profile.Ways.Select(w => w.ProviderName + " " + CloudProfile.WayDetails(w)));
    Assert.Contains("@pat", shown);
    Assert.Contains("connected 3 Nov 2026", shown);
    Assert.DoesNotContain("7f1c0b9e", shown);
  }

  [Fact]
  public void A_picture_from_anywhere_but_the_site_is_not_loaded_and_initials_stand_in()
  {
    var profile = CloudProfile.Read(Encoding.UTF8.GetBytes("""{"email":"sam@example.com","picture":"http://evil.example/p.png","waysToSignIn":[]}"""));
    Assert.Null(profile.Picture);
    Assert.Equal("sam@example.com", profile.Name);
    Assert.Equal("SE", CloudProfile.Initials(profile.Name));
    Assert.Equal("PD", CloudProfile.Initials("Pat Doe"));
  }

  [Fact]
  public void Before_the_site_answers_the_sign_in_says_name_email_and_its_one_way()
  {
    var profile = CloudProfile.FromSnapshot(new CloudSnapshot(CloudPhase.SignedIn, "pat@example.com", "Pat Doe", Provider: "google"));
    Assert.Equal("Pat Doe", profile.Name); Assert.Equal("pat@example.com", profile.Email);
    Assert.Equal("Google", Assert.Single(profile.Ways).ProviderName);
  }

  [Fact]
  public void Settings_opens_its_list_with_Profile_then_Devices_and_old_device_links_land_on_Devices()
  {
    Assert.Equal(new[] { "profile", "devices" }, SettingsNavigation.Categories.Where(c => c.Group == 0).Select(c => c.Id).ToArray());
    Assert.Equal(new[] { "general", "cloud" }, SettingsNavigation.Categories.Where(c => c.Group == 1).Take(2).Select(c => c.Id).ToArray());
    Assert.Equal("devices", SettingsNavigation.Canonical("devices"));
    Assert.Equal("devices", Assert.Single(SettingsNavigation.Matching("paired")).Id);
  }
}
