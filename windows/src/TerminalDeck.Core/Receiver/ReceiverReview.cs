namespace TerminalDeck.Core.Receiver;

public static class ReceiverReview
{
  public static int DestinationIndex(IReadOnlyList<ReceiverDestination> destinations, ReceiverTarget? proposed)
  {
    for (var i = 0; i < destinations.Count; i++) if (destinations[i].Target == proposed) return i;
    return destinations.Count == 0 ? -1 : 0;
  }
}
