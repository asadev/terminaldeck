using System.Diagnostics;
using System.Text;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class ConPtyGeometryTests
{
  [Fact(Timeout = 45000)] public async Task OwnConsoleReportsRequestedGridAndDrainsAfterJobExit()
  {
    var directory = Path.Combine(Path.GetTempPath(), "td-conpty-geometry-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
    using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(35));
    var environment = Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>().Where(e => !((string)e.Key).StartsWith('=')).ToDictionary(e => (string)e.Key, e => (string)e.Value!, StringComparer.OrdinalIgnoreCase);
    var launch = new ProcessLaunch(Path.Combine(Environment.SystemDirectory, "cmd.exe"), ["/d", "/q"], environment, directory);
    try
    {
      await using var terminal = (ConPtyProcess)await new ConPtyTerminalFactory().StartAsync(launch, new(100, 30), stop.Token);
      var received = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var text = new StringBuilder();
      var drain = Task.Run(async () =>
      {
        await foreach (var bytes in terminal.ReadOutputAsync(stop.Token))
        {
          text.Append(Encoding.UTF8.GetString(bytes.Span));
          if (text.ToString().Contains("TD_SYNTHETIC_GRID=84x22", StringComparison.Ordinal)) received.TrySetResult();
        }
      }, stop.Token);
      await terminal.ResizeAsync(new(84, 22), stop.Token);
      var command = "powershell.exe -NoLogo -NoProfile -NonInteractive -Command \"[Console]::WriteLine('TD_SYNTHETIC_GRID='+[Console]::WindowWidth+'x'+[Console]::WindowHeight)\"\r";
      await terminal.WriteAsync(Encoding.UTF8.GetBytes(command), stop.Token);
      await received.Task.WaitAsync(stop.Token);
      await terminal.WriteAsync(Encoding.UTF8.GetBytes("exit\r"), stop.Token);
      Assert.Equal(0, await terminal.WaitForExitAsync(stop.Token));
      await terminal.FinishAsync(stop.Token); await drain.WaitAsync(stop.Token);
      Assert.True(terminal.RootExited); Assert.Equal(0, terminal.ActiveProcessCount);
    }
    finally { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
  }
}
