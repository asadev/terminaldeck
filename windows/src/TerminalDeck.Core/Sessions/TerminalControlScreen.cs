namespace TerminalDeck.Core.Sessions;

// Only the cursor's input line is needed here. Removing ANSI escapes from a
// replay loses cursor motion and can mistake a previous empty prompt for idle.
// Unknown screen-changing commands refuse the write rather than guessing.
internal static class TerminalControlScreen
{
  public static bool AtEmptyPrompt(SessionRecord row)
  {
    var width = Math.Clamp(row.ReplaySize?.Columns ?? 120, 20, 500);
    var height = Math.Clamp(row.ReplaySize?.Rows ?? 40, 5, 200);
    var lines = Enumerable.Range(0, height).Select(_ => new string(' ', width).ToCharArray()).ToArray();
    var x = 0; var y = 0; var savedX = 0; var savedY = 0; var known = true;
    var top = 0; var bottom = height - 1;
    char[] Blank() => new string(' ', width).ToCharArray();
    void Scroll(int first, int last, int count, bool up)
    {
      count = Math.Min(count, last - first + 1);
      if (up) { Array.Copy(lines, first + count, lines, first, last - first + 1 - count); for (var r = last - count + 1; r <= last; r++) lines[r] = Blank(); }
      else { Array.Copy(lines, first, lines, first + count, last - first + 1 - count); for (var r = first; r < first + count; r++) lines[r] = Blank(); }
    }
    void Down()
    {
      if (y == bottom) Scroll(top, bottom, 1, true);
      else y = Math.Min(height - 1, y + 1);
    }
    var text = row.Replay;
    for (var i = 0; i < text.Length; i++)
    {
      var c = text[i];
      if (c == '\u001b')
      {
        if (++i >= text.Length) return false;
        c = text[i];
        if (c == ']')
        {
          while (++i < text.Length && text[i] != '\u0007')
            if (text[i] == '\u001b' && i + 1 < text.Length && text[i + 1] == '\\') { i++; break; }
          continue;
        }
        if (c == '[')
        {
          var start = ++i;
          while (i < text.Length && text[i] is >= '\u0020' and <= '\u003f') i++;
          if (i >= text.Length) return false;
          var args = text[start..i]; var command = text[i];
          if (args.StartsWith('?'))
          {
            if (args is "?1049" or "?1047" or "?47") { foreach (var line in lines) Array.Fill(line, ' '); x = y = 0; known = true; }
            continue;
          }
          if (command is 'm' or 'q' or 'n' or 'c' or 't') continue;
          var values = args.Split(';');
          int Number(int index = 0, int fallback = 1) => index < values.Length && int.TryParse(values[index], out var n) && n > 0 ? Math.Min(n, 10000) : fallback;
          switch (command)
          {
            case 'H': case 'f': y = Math.Clamp(Number() - 1, 0, height - 1); x = Math.Clamp(Number(1) - 1, 0, width - 1); break;
            case 'A': y = Math.Max(0, y - Number()); break;
            case 'B': y = Math.Min(height - 1, y + Number()); break;
            case 'C': x = Math.Min(width - 1, x + Number()); break;
            case 'D': x = Math.Max(0, x - Number()); break;
            case 'E': y = Math.Min(height - 1, y + Number()); x = 0; break;
            case 'F': y = Math.Max(0, y - Number()); x = 0; break;
            case 'G': case '`': x = Math.Clamp(Number() - 1, 0, width - 1); break;
            case 'd': y = Math.Clamp(Number() - 1, 0, height - 1); break;
            case 'r': top = Math.Clamp(Number() - 1, 0, height - 1); bottom = Math.Clamp(Number(1, height) - 1, top, height - 1); x = y = 0; break;
            case 'S': Scroll(top, bottom, Number(), true); break;
            case 'T': Scroll(top, bottom, Number(), false); break;
            case 'L': if (y >= top && y <= bottom) Scroll(y, bottom, Number(), false); break;
            case 'M': if (y >= top && y <= bottom) Scroll(y, bottom, Number(), true); break;
            case 'X': Array.Fill(lines[y], ' ', Math.Min(x, width - 1), Math.Min(Number(), width - Math.Min(x, width - 1))); break;
            case 'P':
              var deleted = Math.Min(Number(), width - Math.Min(x, width - 1));
              Array.Copy(lines[y], Math.Min(x, width - 1) + deleted, lines[y], Math.Min(x, width - 1), width - Math.Min(x, width - 1) - deleted);
              Array.Fill(lines[y], ' ', width - deleted, deleted); break;
            case '@':
              var inserted = Math.Min(Number(), width - Math.Min(x, width - 1));
              Array.Copy(lines[y], Math.Min(x, width - 1), lines[y], Math.Min(x, width - 1) + inserted, width - Math.Min(x, width - 1) - inserted);
              Array.Fill(lines[y], ' ', Math.Min(x, width - 1), inserted); break;
            case 'J':
              var mode = Number(fallback: 0);
              if (mode is 2 or 3) { foreach (var line in lines) Array.Fill(line, ' '); known = true; }
              else if (mode == 0) { Array.Fill(lines[y], ' ', Math.Min(x, width - 1), width - Math.Min(x, width - 1)); for (var r = y + 1; r < height; r++) Array.Fill(lines[r], ' '); }
              else { for (var r = 0; r < y; r++) Array.Fill(lines[r], ' '); Array.Fill(lines[y], ' ', 0, Math.Min(x + 1, width)); }
              break;
            case 'K':
              var erase = Number(fallback: 0);
              if (erase == 2) Array.Fill(lines[y], ' ');
              else if (erase == 1) Array.Fill(lines[y], ' ', 0, Math.Min(x + 1, width));
              else Array.Fill(lines[y], ' ', Math.Min(x, width - 1), width - Math.Min(x, width - 1));
              break;
            case 's': savedX = x; savedY = y; break;
            case 'u': x = savedX; y = savedY; break;
            default: known = false; break;
          }
          continue;
        }
        if (c == '7') { savedX = x; savedY = y; }
        else if (c == '8') { x = savedX; y = savedY; }
        else if (c == 'D') Down();
        else if (c == 'E') { x = 0; Down(); }
        else if (c == 'M') { if (y == top) Scroll(top, bottom, 1, false); else y = Math.Max(0, y - 1); }
        else if (c is '(' or ')') i++;
        else known = false;
        continue;
      }
      if (c == '\r') { x = 0; continue; }
      if (c == '\n') { Down(); continue; }
      if (c == '\b') { x = Math.Max(0, x - 1); continue; }
      if (c == '\t') { x = Math.Min(width - 1, (x / 8 + 1) * 8); continue; }
      if (char.IsControl(c)) continue;
      if (x >= width) { x = 0; Down(); }
      lines[y][x++] = c;
    }
    return known && new string(lines[y]).Trim() is "❯" or ">";
  }
}
