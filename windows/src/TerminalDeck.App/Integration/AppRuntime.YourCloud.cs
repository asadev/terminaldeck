using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Integration;

/// The Your Cloud page's reader (lane U1's `CloudContents`, its kinds registered by the join). Null until then, and the
/// page says "Sign in to see what is in your Cloud."; the page's actions belong to the person only (never an AI tool).
public sealed partial class AppRuntime
{
  public CloudContents? YourCloud { get; set; }
}
