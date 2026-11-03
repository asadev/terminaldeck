using System.Text;

namespace TerminalDeck.Core.Sessions;

// Append costs the new chunk, rather than copying a megabyte of prior output
// for every small PTY read. Text materializes only for a real reader/save.
public sealed class SessionReplayBuffer(int maximumBytes = SessionKeeper.MaximumReplayBytes)
{
  private readonly object gate = new();
  private readonly LinkedList<(string Text, int Start, int Bytes)> chunks = new();
  private int bytes;
  private string? cached;
  public void Replace(string text)
  {
    lock (gate) { chunks.Clear(); bytes = 0; cached = null; Append(text); }
  }
  public void Append(string text)
  {
    if (text.Length == 0) return;
    lock (gate)
    {
      var amount = Encoding.UTF8.GetByteCount(text); chunks.AddLast((text, 0, amount)); bytes += amount; cached = null;
      while (bytes > maximumBytes && chunks.First is { } first)
      {
        var excess = bytes - maximumBytes;
        if (first.Value.Bytes <= excess) { bytes -= first.Value.Bytes; chunks.RemoveFirst(); continue; }
        var value = first.Value.Text; var offset = first.Value.Start; var removed = 0;
        while (removed < excess && offset < value.Length)
        {
          var units = offset + 1 < value.Length && char.IsSurrogatePair(value[offset], value[offset + 1]) ? 2 : 1;
          removed += Encoding.UTF8.GetByteCount(value.AsSpan(offset, units)); offset += units;
        }
        first.Value = (value, offset, first.Value.Bytes - removed); bytes -= removed;
      }
    }
  }
  public string Snapshot()
  {
    lock (gate)
    {
      if (cached is not null) return cached;
      var text = new StringBuilder(bytes);
      foreach (var chunk in chunks) text.Append(chunk.Text.AsSpan(chunk.Start));
      return cached = text.ToString();
    }
  }
  public int Bytes { get { lock (gate) return bytes; } }
}
