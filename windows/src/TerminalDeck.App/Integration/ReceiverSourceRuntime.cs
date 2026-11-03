using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private ReceiverSourceService? receiverSources;
  private ReceiverRelayAdapter? receiverRelay;
  public ReceiverSourceService ReceiverSources => receiverSources ??= new(Receiver,
    new ProtectedReceiverState<ReceiverSourceSettingsState>(new JsonStateStore<byte[]>(Root, "receiver-sources"), new CurrentUserDpapi(Root)), new WindowsCredentialStore(Root), TerminalDeck.Core.Brand.Name + "/" + Root.NamespaceId + "/receiver-sources/", projectExists: id => Projects.List().Any(p => p.Id == id));
  public ReceiverRelayAdapter ReceiverRelay => receiverRelay ??= new(ReceiverSources);
  public void DisposeReceiverSources() { receiverRelay?.Dispose(); receiverRelay = null; receiverSources?.Dispose(); receiverSources = null; }
}
