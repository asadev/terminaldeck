using System.Buffers.Binary;

namespace TerminalDeck.Core.Chats;

// A bounded content snapshot, never a caller-selected path for a later worker to open.
public sealed record ChatAttachmentData(string Name, string MimeType, byte[] Data, int Width, int Height)
{
  public static ChatAttachmentData Read(string name, byte[] data)
  {
    if (data.Length is < 5 or > 8 * 1024 * 1024) throw new ArgumentException("Choose an image up to 8 MB or a PDF up to 500 KB.");
    if (data.AsSpan(0, 5).SequenceEqual("%PDF-"u8)) return new(name, "application/pdf", data, 0, 0);
    if (data.Length >= 24 && data.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }) && data.AsSpan(12, 4).SequenceEqual("IHDR"u8))
      return new(name, "image/png", data, BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(16, 4)), BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(20, 4)));
    if (data[0] == 255 && data[1] == 216)
    {
      var p = 2;
      while (p + 3 < data.Length)
      {
        if (data[p++] != 255) break;
        while (p < data.Length && data[p] == 255) p++;
        if (p >= data.Length) break;
        var marker = data[p++];
        if (marker is 217 or 218) break;
        if (marker is 0 or 1 or >= 208 and <= 215) continue;
        if (p + 2 > data.Length) break;
        var size = BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(p, 2));
        if (size < 2 || p + size > data.Length) break;
        if (marker is 192 or 193 or 194 or 195 or 197 or 198 or 199 or 201 or 202 or 203 or 205 or 206 or 207 && size >= 7)
          return new(name, "image/jpeg", data, BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(p + 5, 2)), BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(p + 3, 2)));
        p += size;
      }
    }
    throw new ArgumentException("Choose a readable PNG, JPEG or PDF attachment.");
  }
  public void Validate(string provider)
  {
    var actual = Read(Name, Data);
    if (actual.MimeType != MimeType || actual.Width != Width || actual.Height != Height) throw new ArgumentException("The attachment metadata does not match its content.");
    if (MimeType == "application/pdf")
    { if (provider != "claude" || Data.Length > 500000) throw new ArgumentException("PDF documents up to 500 KB are supported in Claude chats only."); }
    else if (Width is <= 0 or > 2048 || Height is <= 0 or > 2048) throw new ArgumentException("Choose an image up to 2048 pixels on each side.");
  }
}
