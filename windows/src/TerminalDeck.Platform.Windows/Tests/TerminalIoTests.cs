using System.Text;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class TerminalIoTests
{
  [Fact(Timeout = 20000)]
  public async Task OutputActuallyComesThroughConPty()
  {
    var environment = Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>().Where(e => !((string)e.Key).StartsWith('=')).ToDictionary(e => (string)e.Key, e => (string)e.Value!, StringComparer.OrdinalIgnoreCase);
    await using var terminal = await new ConPtyTerminalFactory().StartAsync(new(Path.Combine(Environment.SystemDirectory, "cmd.exe"), ["/d", "/q"], environment, Path.GetTempPath()), new(100, 30));
    using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(12)); var output = new StringBuilder();
    var read = Task.Run(async () =>
    {
      await foreach (var bytes in terminal.ReadOutputAsync(ct.Token))
      {
        output.Append(Encoding.UTF8.GetString(bytes.Span)); if (output.ToString().Contains("W3_REAL_CONPTY")) return;
      }
    });
    await terminal.ResizeAsync(new(110, 35), ct.Token);
    await terminal.WriteAsync(Encoding.UTF8.GetBytes("echo W3_REAL_CONPTY\r"), ct.Token);
    await read;
    Assert.Contains("W3_REAL_CONPTY", output.ToString());
    await terminal.QuitAsync(ct.Token);
  }
}
