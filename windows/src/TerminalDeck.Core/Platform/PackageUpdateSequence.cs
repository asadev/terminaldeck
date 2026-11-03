namespace TerminalDeck.Core.Platform;

// "Restart to update" in one fixed order. The keeper hands its sessions over
// first (a failed handover stops the update). Then every Claude sign-in renewal
// still under way is let finish saving, because Windows' forced package shutdown
// ends every process of the app at once, helper Claudes included; cutting a
// renewal blanks that login (saba-pc, 1 Nov). Only then is the package replaced.
// A failure brings the sessions back; so does returning, because Windows ends
// this process when it really replaces the package.
public static class PackageUpdateSequence
{
  public static async Task RunAsync(Func<Task> handOver, Func<Task> settleSignIns, Func<Task> apply, Func<Task> resume)
  {
    await handOver();
    try
    {
      await settleSignIns();
      await apply();
    }
    catch { await resume(); throw; }
    // Still running: Windows had nothing newer to apply.
    await resume();
  }
}
