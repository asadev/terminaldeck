using System.Text;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class ConPtyControlCellTests
{
  [Fact]
  public void OnlyControlsThatTakeACellBecomeBlanks()
  {
    byte[] cells = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x0B, 0x0C, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1C, 0x1D, 0x1E, 0x1F];
    var output = Enumerable.Range(0, 256).Select(value => (byte)value).ToArray();
    ConPtyControlCells.Blank(output);
    for (var value = 0; value < 256; value++) Assert.Equal(cells.Contains((byte)value) ? (byte)' ' : (byte)value, output[value]);
  }
  [Fact]
  public void EscapesLineControlsAndTextPassUnchanged()
  {
    var frame = Encoding.UTF8.GetBytes("\u001b[?2004h\u001b]0;título ☼\a\r\nab\bc\t€\u001b[45;5H");
    var output = frame.ToArray(); ConPtyControlCells.Blank(output);
    Assert.Equal(frame, output);
  }
  // Windows 10's console stores an SI written in the UTF-8 code page as a cell,
  // and ConPTY sends it raw. The terminal must receive a blank in its place.
  [Fact(Timeout = 30000)]
  public async Task ControlCharacterKeepsItsColumnThroughConPty()
  {
    if (!ConPtyControlCells.Needed) return;
    var environment = Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>().Where(e => !((string)e.Key).StartsWith('=')).ToDictionary(e => (string)e.Key, e => (string)e.Value!, StringComparer.OrdinalIgnoreCase);
    await using var terminal = await new ConPtyTerminalFactory().StartAsync(new(Path.Combine(Environment.SystemDirectory, "cmd.exe"), ["/d", "/q"], environment, Path.GetTempPath()), new(160, 30));
    using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(25)); var output = new StringBuilder();
    var read = Task.Run(async () =>
    {
      // The caret keeps the typed command line from matching the marker.
      await foreach (var bytes in terminal.ReadOutputAsync(ct.Token))
      {
        output.Append(Encoding.UTF8.GetString(bytes.Span)); if (output.ToString().Contains("TD_DONE")) return;
      }
    });
    await terminal.WriteAsync(Encoding.UTF8.GetBytes("chcp 65001 >nul & powershell -NoLogo -NoProfile -Command \"[Console]::Write('TDCELL'+[char]15+'END')\" & echo TD_^DONE\r"), ct.Token);
    await read;
    Assert.Contains("TDCELL END", output.ToString());
    Assert.DoesNotContain('\u000f', output.ToString());
    await terminal.QuitAsync(ct.Token);
  }
}
