using System.Runtime.InteropServices;
using TerminalDeck.Platform.Windows.Phone;

namespace TerminalDeck.Windows.Tests.Link;

// The test phone's decoder: Microsoft's H.264 decoder MFT (software, synchronous, low latency), fed Annex B built from
// the `sims.video` AVCC + SPS/PPS the way the phones' VideoToolbox / MediaCodec are fed. True = a picture came out.
internal sealed class TestH264Decoder : IDisposable
{
  private readonly IMFTransform transform;
  private bool typed;
  private long time;

  public TestH264Decoder()
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

  private void ChooseOutput()
  {
    for (uint i = 0; transform.GetOutputAvailableType(0, i, out var type) >= 0; i++)
    {
      var attributes = MediaFoundation.Attributes(type);
      var subtype = MediaFoundation.Subtype;
      var ok = attributes.GetGUID(ref subtype, out var format) >= 0 && format == MediaFoundation.FormatNv12;
      Marshal.ReleaseComObject(attributes);
      if (ok) { typed = transform.SetOutputType(0, type, 0) >= 0; Marshal.Release(type); return; }
      Marshal.Release(type);
    }
  }

  public static byte[] AnnexB(byte[] avcc, byte[]? sps, byte[]? pps)
  {
    using var stream = new MemoryStream(avcc.Length + 64);
    byte[] start = [0, 0, 0, 1];
    if (sps is not null) { stream.Write(start); stream.Write(sps); }
    if (pps is not null) { stream.Write(start); stream.Write(pps); }
    for (var at = 0; at + 4 <= avcc.Length;)
    {
      var length = System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(avcc.AsSpan(at));
      if (length <= 0 || at + 4 + length > avcc.Length) throw new InvalidDataException("broken AVCC");
      stream.Write(start); stream.Write(avcc.AsSpan(at + 4, length));
      at += 4 + length;
    }
    return stream.ToArray();
  }

  /// Pictures still inside the decoder, drained.
  public int Drain()
  {
    transform.ProcessMessage(1 /* MFT_MESSAGE_COMMAND_DRAIN */, IntPtr.Zero);
    var pictures = 0;
    for (var round = 0; round < 64; round++)
    {
      var outcome = Take();
      if (outcome == 1) pictures++;
      else if (outcome == 0) break;
      else ChooseOutput();
    }
    return pictures;
  }

  /// Pictures that came out for this input (0 while the decoder still holds it).
  public int Decode(byte[] annexB)
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
    var pictures = 0;
    for (var round = 0; round < 8; round++)
    {
      var outcome = Take();
      if (outcome == 1) { pictures++; continue; }
      if (outcome == 0) break;
      // A format change: take the new NV12 output and ask again.
      ChooseOutput();
    }
    return pictures;
  }

  // 1 = a picture, 0 = needs more input, -1 = the output format changed.
  private int Take()
  {
    if (!typed) return -1;
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
      if (hr == MediaFoundation.NeedMoreInput) return 0;
      if (hr == MediaFoundation.StreamChange) { typed = false; return -1; }
      MediaFoundation.Check(hr, "decoder ProcessOutput");
      return 1;
    }
    finally { Marshal.Release(buffers[0].Sample); Marshal.ReleaseComObject(sample); }
  }

  public void Dispose() => Marshal.ReleaseComObject(transform);
}
