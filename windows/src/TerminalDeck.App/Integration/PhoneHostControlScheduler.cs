namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private readonly CancellationTokenSource phoneManagementLifetime = new();
  private void SchedulePhoneHostControl(bool restart, Func<CancellationToken, ValueTask> recheck)
  {
    _ = Task.Run(async () =>
    {
      try
      {
        await Task.Delay(750, phoneManagementLifetime.Token);
        await recheck(phoneManagementLifetime.Token);
        await Remote.ControlHostAsync(restart, phoneManagementLifetime.Token);
      }
      catch (Exception e) when (e is OperationCanceledException or ObjectDisposedException or IOException or InvalidOperationException)
      { if (!phoneManagementLifetime.IsCancellationRequested) NotificationFailed?.Invoke("The scheduled phone host action did not complete. Check Devices before retrying."); }
    });
  }
}
