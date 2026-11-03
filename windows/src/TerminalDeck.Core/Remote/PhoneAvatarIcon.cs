namespace TerminalDeck.Core.Remote;

public static class PhoneAvatarIcon
{
  // Windows saves plain symbol names; both actual phone decoders use sf:/emoji:.
  public static string Encode(string icon) => icon is "hoot" || icon.StartsWith("sf:", StringComparison.Ordinal) || icon.StartsWith("emoji:", StringComparison.Ordinal) ? icon : "sf:" + icon;
}
