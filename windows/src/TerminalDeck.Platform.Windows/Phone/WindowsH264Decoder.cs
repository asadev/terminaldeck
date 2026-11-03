using System.Buffers.Binary;
using System.Runtime.InteropServices;
using TerminalDeck.Core.Computers;

namespace TerminalDeck.Platform.Windows.Phone;

// "Other computers" (contract §11.7): another computer's screen arrives as H.264 on the direct link. Microsoft's H.264
// decoder MFT (software, synchronous, low latency) is fed Annex B built from the `sims.video` AVCC + SPS/PPS, the way
// the phones feed VideoToolbox / MediaCodec; its NV12 comes out as BGRA (BT.709, limited range: what the encoders make).
public sealed class WindowsH264Decoder : IComputerVideoDecoder
{
  private readonly IMFTransform transform;
  private bool typed;
  private int frameWidth, frameHeight, stride;
  private long time;
  private int disposed;

  public WindowsH264Decoder()
  {
    MediaFoundation.Start();
    transform = (IMFTransform)Activator.CreateInstance(Type.GetTypeFromCLSID(MediaFoundation.SoftwareH264Decoder, true)!)!;
    var input = MediaFoundation.NewType((MediaFoundation.MajorType, MediaFoundation.MediaTypeVideo), (MediaFoundation.Subtype, MediaFoundation.FormatH264));
    try { MediaFoundation.Check(transform.SetInputType(0, input, 0), "decoder SetInputType"); } finally { Marshal.Release(input); }
    // Low latency: each picture out as soon as it is in (else the decoder holds a few back).
    if (transform.GetAttributes(out var attributesPointer) >= 0 && attributesPointer != IntPtr.Zero)
    {
      var attributes = MediaFoundation.Attributes(attributesPointer);
      var lowLatency = MediaFoundation.LowLatency;
      _ = attributes.SetUINT32(ref lowLatency, 1);
      Marshal.ReleaseComObject(attributes); Marshal.Release(attributesPointer);
    }
    if (transform is ICodecAPI codec)
    {
      var key = MediaFoundation.CodecLowLatency; var value = MediaFoundation.Bool(true);
      _ = codec.SetValue(ref key, ref value);
    }
    ChooseOutput();
    MediaFoundation.Check(transform.ProcessMessage(MediaFoundation.MessageBeginStreaming, IntPtr.Zero), "decoder begin");
  }

  // NV12 out, and its real geometry (the decoder pads the height to 16 lines; the stride may be wider than the width).
  private void ChooseOutput()
  {
    typed = false;
    for (uint i = 0; transform.GetOutputAvailableType(0, i, out var type) >= 0; i++)
    {
      var attributes = MediaFoundation.Attributes(type);
      var subtype = MediaFoundation.Subtype;
      var ok = attributes.GetGUID(ref subtype, out var format) >= 0 && format == MediaFoundation.FormatNv12;
      if (ok && transform.SetOutputType(0, type, 0) >= 0)
      {
        var size = MediaFoundation.FrameSize; var strideKey = MediaFoundation.DefaultStride;
        frameWidth = frameHeight = 0;
        if (attributes.GetUINT64(ref size, out var packed) >= 0) { frameWidth = (int)(packed >> 32); frameHeight = (int)(packed & 0xFFFFFFFF); }
        stride = attributes.GetUINT32(ref strideKey, out var s) >= 0 && (int)s >= frameWidth ? (int)s : frameWidth;
        typed = true;
      }
      Marshal.ReleaseComObject(attributes); Marshal.Release(type);
      if (typed) return;
    }
  }

  /// AVCC (4-byte big-endian lengths) with SPS/PPS in front of a keyframe, as Annex B.
  public static byte[] AnnexB(byte[] avcc, byte[]? sps, byte[]? pps)
  {
    using var stream = new MemoryStream(avcc.Length + 64);
    byte[] start = [0, 0, 0, 1];
    if (sps is not null) { stream.Write(start); stream.Write(sps); }
    if (pps is not null) { stream.Write(start); stream.Write(pps); }
    for (var at = 0; at + 4 <= avcc.Length;)
    {
      var length = BinaryPrimitives.ReadInt32BigEndian(avcc.AsSpan(at));
      if (length <= 0 || at + 4 + length > avcc.Length) throw new InvalidDataException("The screen picture is broken (AVCC).");
      stream.Write(start); stream.Write(avcc.AsSpan(at + 4, length));
      at += 4 + length;
    }
    return stream.ToArray();
  }

  /// One `sims.video` picture (AVCC + parameter sets) through the decoder (IComputerVideoDecoder).
  public IReadOnlyList<ComputerVideoPicture> Decode(ComputerVideoFrame frame) => Decode(AnnexB(frame.Avcc, frame.Sps, frame.Pps), frame.Width, frame.Height);

  /// The pictures that came out for this input (none while the decoder still holds it), cropped to width × height.
  public IReadOnlyList<ComputerVideoPicture> Decode(byte[] annexB, int width, int height)
  {
    MediaFoundation.Check(MediaFoundation.MFCreateSample(out var sample), "MFCreateSample");
    MediaFoundation.Check(MediaFoundation.MFCreateMemoryBuffer(annexB.Length, out var buffer), "MFCreateMemoryBuffer");
    try
    {
      MediaFoundation.Check(buffer.Lock(out var data, out _, out _), "Lock");
      try { Marshal.Copy(annexB, 0, data, annexB.Length); } finally { buffer.Unlock(); }
      buffer.SetCurrentLength(annexB.Length);
      sample.AddBuffer(buffer);
      sample.SetSampleTime(time); time += 333_333;
      MediaFoundation.Check(transform.ProcessInput(0, sample, 0), "decoder ProcessInput");
    }
    finally { Marshal.ReleaseComObject(buffer); Marshal.ReleaseComObject(sample); }
    var pictures = new List<ComputerVideoPicture>(1);
    for (var round = 0; round < 8; round++)
    {
      var (outcome, picture) = Take(width, height);
      if (outcome == 1) { if (picture is not null) pictures.Add(picture); continue; }
      if (outcome == 0) break;
      // A format change (a new size): take the new NV12 output and ask again.
      ChooseOutput();
    }
    return pictures;
  }

  // 1 = a picture, 0 = needs more input, -1 = the output format changed.
  private (int Outcome, ComputerVideoPicture? Picture) Take(int width, int height)
  {
    if (!typed) return (-1, null);
    MediaFoundation.Check(transform.GetOutputStreamInfo(0, out var info), "decoder GetOutputStreamInfo");
    MediaFoundation.Check(MediaFoundation.MFCreateSample(out var sample), "MFCreateSample");
    MediaFoundation.Check(MediaFoundation.MFCreateMemoryBuffer((int)Math.Max(info.Size, 4096u), out var buffer), "MFCreateMemoryBuffer");
    sample.AddBuffer(buffer);
    Marshal.ReleaseComObject(buffer);
    var buffers = new MediaFoundation.OutputDataBuffer[1];
    buffers[0].Sample = Marshal.GetIUnknownForObject(sample);
    try
    {
      var hr = transform.ProcessOutput(0, 1, buffers, out _);
      if (buffers[0].Events != IntPtr.Zero) Marshal.Release(buffers[0].Events);
      if (hr == MediaFoundation.NeedMoreInput) return (0, null);
      if (hr == MediaFoundation.StreamChange) { typed = false; return (-1, null); }
      MediaFoundation.Check(hr, "decoder ProcessOutput");
      MediaFoundation.Check(sample.ConvertToContiguousBuffer(out var contiguous), "ConvertToContiguousBuffer");
      try
      {
        MediaFoundation.Check(contiguous.Lock(out var data, out _, out var length), "Lock");
        try
        {
          var nv12 = new byte[length];
          Marshal.Copy(data, nv12, 0, length);
          return (1, ToBgra(nv12, stride, frameHeight, Math.Min(width, frameWidth), Math.Min(height, frameHeight)));
        }
        finally { contiguous.Unlock(); }
      }
      finally { Marshal.ReleaseComObject(contiguous); }
    }
    finally { Marshal.Release(buffers[0].Sample); Marshal.ReleaseComObject(sample); }
  }

  /// NV12 (luma rows of `stride` bytes, `rows` of them, then the interleaved chroma) as opaque BGRA, BT.709 limited range.
  public static ComputerVideoPicture? ToBgra(byte[] nv12, int stride, int rows, int width, int height)
  {
    width &= ~1; height &= ~1;
    if (width < 2 || height < 2 || stride < width || rows < height || nv12.Length < stride * rows + stride * (height / 2)) return null;
    var bgra = new byte[width * height * 4];
    var chroma = stride * rows;
    Parallel.For(0, height / 2, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Math.Min(4, Environment.ProcessorCount / 2)) }, pair =>
    {
      var uvRow = chroma + pair * stride;
      for (var line = 0; line < 2; line++)
      {
        var y = pair * 2 + line;
        var luma = y * stride;
        var output = y * width * 4;
        for (var x = 0; x < width; x++)
        {
          var c = 298 * (nv12[luma + x] - 16);
          var d = nv12[uvRow + (x & ~1)] - 128;
          var e = nv12[uvRow + (x & ~1) + 1] - 128;
          var o = output + x * 4;
          bgra[o] = (byte)Math.Clamp((c + 541 * d + 128) >> 8, 0, 255);
          bgra[o + 1] = (byte)Math.Clamp((c - 55 * d - 136 * e + 128) >> 8, 0, 255);
          bgra[o + 2] = (byte)Math.Clamp((c + 459 * e + 128) >> 8, 0, 255);
          bgra[o + 3] = 255;
        }
      }
    });
    return new(bgra, width, height);
  }

  public void Dispose()
  {
    if (Interlocked.Exchange(ref disposed, 1) == 0) Marshal.ReleaseComObject(transform);
  }
}
