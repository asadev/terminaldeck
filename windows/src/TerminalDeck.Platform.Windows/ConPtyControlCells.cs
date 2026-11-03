namespace TerminalDeck.Platform.Windows;

// Windows 10's console host keeps most C0 control characters as cells: it
// shows them as the old code page 437 glyphs (SI is ☼) instead of running or
// dropping them. In the UTF-8 code page, which Claude Code and other current
// tools select, ConPTY then sends the raw control character on and counts it as
// one column. The terminal treats it as a control that takes no column (SI and
// SO switch character sets, VT and FF move down a line), so every later
// relative move from ConPTY lands one column off. Claude Code writes an SI when
// it redraws after a pause, and the next letter replaced the character before
// the cursor. Sending a blank instead keeps the terminal on the column that
// ConPTY counts.
public static class ConPtyControlCells
{
  // Measured on Windows 10 19045, where every build has this console host.
  // Other Windows versions are left as they are.
  public static bool Needed { get; } = OperatingSystem.IsWindows() && !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000);
  // NUL, BEL, BS, TAB, LF, CR, ESC and DEL take no cell.
  public static bool TakesCell(byte value) => value is (>= 0x01 and <= 0x06) or 0x0B or 0x0C or (>= 0x0E and <= 0x1A) or (>= 0x1C and <= 0x1F);
  // Rewrites the chunk in place. A C0 byte never occurs inside a UTF-8
  // sequence, so each chunk can be handled on its own.
  public static void Blank(Span<byte> output)
  {
    for (var i = 0; i < output.Length; i++) if (TakesCell(output[i])) output[i] = (byte)' ';
  }
}
