using System.Text;

namespace TerminalDeck.Core.Cloud;

/// "How this PC trusts your other devices" (owner, 13 Nov; the Mac's BackendCloudTrustMode). Only WHO adds a key to this
/// PC's list changes; the list, the signature check and the waiting changes stay exactly as they are.
public enum CloudTrustMode
{
  /// DEFAULT. Every device the account lists is put on this PC's list with the key the service reports, the first time
  /// it is seen, with no dialog and no code. A device whose reported key later CHANGES is held until the person presses
  /// "Trust it again". A device the person removed here is never added again by itself.
  Account,
  /// The earlier behaviour exactly: a new device waits until the person compares its code and presses Trust.
  Ask
}

/// Where the choice lives: a protected slot beside the trusted lists (Windows: the same DPAPI + Credential Manager HMAC
/// form, `WindowsCloudTrustStore.TrustMode`), never a plain file, so nothing that can only write the data folder can
/// flip this PC from "Ask me" back to automatic. Nothing stored is "Automatically, with my account"; a slot this build
/// cannot read is the stricter "Ask me".
public sealed class CloudTrustModeStore(ICloudTrustSlot slot)
{
  public CloudTrustMode Load()
  {
    byte[]? stored;
    try { stored = slot.Read(); }
    catch (Exception) { return CloudTrustMode.Ask; }
    if (stored is not null) return From(Encoding.UTF8.GetString(stored));
    try { Save(CloudTrustMode.Account); } catch (CloudTrustRefusal) { }
    return CloudTrustMode.Account;
  }

  /// Only the Cloud page's own press comes here. Read back, like the trusted list.
  public void Save(CloudTrustMode mode)
  {
    var bytes = Encoding.UTF8.GetBytes(Name(mode));
    try { slot.Write(bytes); } catch (Exception) { throw new CloudTrustRefusal(CloudTrustRefusalKind.NotSaved); }
    byte[]? back;
    try { back = slot.Read(); } catch (Exception) { back = null; }
    if (back is null || !back.AsSpan().SequenceEqual(bytes)) throw new CloudTrustRefusal(CloudTrustRefusalKind.NotSaved);
  }

  public static string Name(CloudTrustMode mode) => mode == CloudTrustMode.Account ? "account" : "ask";
  /// Anything unknown is the stricter "ask".
  public static CloudTrustMode From(string text) => text.Trim() is "account" or "" ? CloudTrustMode.Account : CloudTrustMode.Ask;
}
