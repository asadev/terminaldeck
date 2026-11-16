namespace TerminalDeck.Core.Cloud;

/// What saved passwords need from the signed-in account, beyond sync: this PC's registration (its two public keys),
/// its ECDH with a sealed key's ephemeral key, and this PC's own trusted list (who may hand it the key, and to whom it
/// hands the key on). Nothing here is reachable from a tool and nothing returns a private key.
public interface ICloudSecretsAccount
{
  /// This PC's registration while it is signed in and registered; null otherwise.
  CloudDeviceRegistration? SecretsDevice { get; }
  byte[] SecretsSharedSecret(CloudPublicJwk peer);
  /// This PC's trusted list for the signed-in account; null when there is none or it cannot be built.
  CloudTrustStore? SecretsTrust { get; }
}

public sealed partial class CloudAccountClient : ICloudSecretsAccount
{
  public CloudDeviceRegistration? SecretsDevice =>
    saved is { Registered: true } && keys is { } own ? own.Registration(configuration.DeviceLabel, configuration.AppVersion, configuration.Platform) : null;
  public byte[] SecretsSharedSecret(CloudPublicJwk peer) => (keys ?? throw new CloudFailure("sign_in_required", 401)).SharedSecret(peer);
  public CloudTrustStore? SecretsTrust
  {
    get { try { return saved is { } record ? TrustFor(record) : null; } catch (Exception) { return null; } }
  }
}
