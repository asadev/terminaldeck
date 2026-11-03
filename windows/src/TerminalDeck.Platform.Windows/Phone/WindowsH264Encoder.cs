using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace TerminalDeck.Platform.Windows.Phone;

/// One encoded picture: AVCC (4-byte big-endian lengths, no parameter sets), with the SPS/PPS on keyframes.
public sealed record H264Frame(byte[] Avcc, bool Key, byte[]? Sps, byte[]? Pps);

// stream step 2: This PC's screen as H.264 with Windows' own Media Foundation encoder: the GPU's encoder when there is
// one (an asynchronous MFT, driven by its events on a thread of its own), else Microsoft's software encoder. Low
// latency, no B-frames, constant bit rate, a keyframe whenever asked. Input is NV12 (see Nv12.FromBgra); output is
// Annex B, turned into AVCC with the parameter sets split off (the Mac's and phones' format).
public sealed class WindowsH264Encoder : IDisposable
{
  public int Width { get; }
  public int Height { get; }
  public int Fps { get; }
  public bool Hardware { get; }
  public string Name { get; }
  private readonly IMFTransform transform;
  private readonly IMFActivate? activate;
  private readonly ICodecAPI? codec;
  private readonly SemaphoreSlim inputs = new(0, int.MaxValue);
  private readonly BlockingCollection<H264Frame> outputs = new();
  // Who holds the transform (the owner, and a GPU encoder's event thread) and who lets it go (the last one out, once).
  private readonly EncoderEventThread lifetime;
  private readonly bool providesSamples;
  private readonly int outputSize;
  private byte[]? sps, pps;
  private long time;
  private int eventsSeen;
  /// Pictures a GPU encoder did not take in time (not encoded).
  public int Refused { get; private set; }
  private int refusedInARow;
  private volatile bool stallForced; // tests only: a healthy encode must not clear it (it resets refusedInARow)
  /// A GPU encoder that took no picture three times in a row has stalled; so has one whose event thread failed.
  public bool Stalled => Hardware && (refusedInARow >= 3 || lifetime.Failed || stallForced);
  internal int Releases => lifetime.Releases;
  internal bool EventsEnded => lifetime.Ended;
  internal void StallForTest() => stallForced = true;

  /// Encode with the GPU encoder; if it stalls, the software encoder takes over (a keyframe first) and the stalled
  /// one is shut down in the background, so a stuck driver never holds the screen.
  public static List<H264Frame> Encode(ref WindowsH264Encoder encoder, byte[] nv12, bool key)
  {
    var frames = encoder.Encode(nv12, key);
    if (!encoder.Stalled) return frames;
    var stalled = encoder;
    Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " video: " + stalled.Name + " stalled; the software encoder takes over");
    encoder = Create(stalled.Width, stalled.Height, stalled.Fps, stalled.Bitrate, preferHardware: false);
    _ = Task.Run(stalled.Dispose);
    return encoder.Encode(nv12, key: true);
  }
  private int bitrate;

  private WindowsH264Encoder(IMFTransform transform, IMFActivate? activate, string name, bool hardware, int width, int height, int fps, int bitrate)
  {
    this.transform = transform; this.activate = activate; Name = name; Hardware = hardware; Width = width; Height = height; Fps = fps; this.bitrate = bitrate;
    if (transform.GetAttributes(out var attributesPointer) >= 0 && attributesPointer != IntPtr.Zero)
    {
      var attributes = MediaFoundation.Attributes(attributesPointer);
      // An asynchronous (GPU) MFT must be unlocked before use; every encoder is told to hold nothing back.
      var unlock = MediaFoundation.AsyncUnlock;
      if (hardware) MediaFoundation.Check(attributes.SetUINT32(ref unlock, 1), "async unlock");
      var lowLatency = MediaFoundation.LowLatency;
      _ = attributes.SetUINT32(ref lowLatency, 1);
      Marshal.ReleaseComObject(attributes); Marshal.Release(attributesPointer);
    }
    else if (hardware) throw new COMException("The GPU encoder has no attributes to unlock.");
    // These shape the stream, so they go before the media types (the software encoder ignores them after).
    try { codec = (ICodecAPI)transform; } catch (InvalidCastException) { codec = null; }
    Set(MediaFoundation.CodecLowLatency, MediaFoundation.Bool(true));
    Set(MediaFoundation.CodecBPictures, MediaFoundation.UInt32(0));
    Set(MediaFoundation.CodecRateControl, MediaFoundation.UInt32(0)); // CBR
    Set(MediaFoundation.CodecMeanBitrate, MediaFoundation.UInt32((uint)bitrate));
    Set(MediaFoundation.CodecGopSize, MediaFoundation.UInt32(100_000));
    var output = MediaFoundation.NewType((MediaFoundation.MajorType, MediaFoundation.MediaTypeVideo), (MediaFoundation.Subtype, MediaFoundation.FormatH264),
      (MediaFoundation.AverageBitrate, (uint)bitrate), (MediaFoundation.FrameSize, MediaFoundation.Pair(width, height)), (MediaFoundation.FrameRate, MediaFoundation.Pair(fps, 1)),
      (MediaFoundation.InterlaceMode, 2u), (MediaFoundation.PixelAspectRatio, MediaFoundation.Pair(1, 1)), (MediaFoundation.Mpeg2Profile, 100u),
      (MediaFoundation.YuvMatrix, 1u), (MediaFoundation.VideoPrimaries, 2u), (MediaFoundation.NominalRange, 2u));
    var input = MediaFoundation.NewType((MediaFoundation.MajorType, MediaFoundation.MediaTypeVideo), (MediaFoundation.Subtype, MediaFoundation.FormatNv12),
      (MediaFoundation.FrameSize, MediaFoundation.Pair(width, height)), (MediaFoundation.FrameRate, MediaFoundation.Pair(fps, 1)),
      (MediaFoundation.InterlaceMode, 2u), (MediaFoundation.PixelAspectRatio, MediaFoundation.Pair(1, 1)), (MediaFoundation.YuvMatrix, 1u), (MediaFoundation.NominalRange, 2u));
    try
    {
      MediaFoundation.Check(transform.SetOutputType(0, output, 0), "SetOutputType");
      MediaFoundation.Check(transform.SetInputType(0, input, 0), "SetInputType");
    }
    finally { Marshal.Release(output); Marshal.Release(input); }
    // Some encoders take the settings only once the types are set: tell them again.
    Set(MediaFoundation.CodecLowLatency, MediaFoundation.Bool(true));
    Set(MediaFoundation.CodecBPictures, MediaFoundation.UInt32(0));
    Set(MediaFoundation.CodecMeanBitrate, MediaFoundation.UInt32((uint)bitrate));
    MediaFoundation.Check(transform.GetOutputStreamInfo(0, out var info), "GetOutputStreamInfo");
    providesSamples = (info.Flags & (MediaFoundation.ProvidesSamples | MediaFoundation.CanProvideSamples)) != 0;
    outputSize = (int)Math.Max(info.Size, (uint)(width * height * 3 / 2));
    ReadSequenceHeader();
    lifetime = new EncoderEventThread("td-h264-events", hardware ? NextEvent : null, hardware ? OnEvent : null, Release);
    lifetime.Start();
    MediaFoundation.Check(transform.ProcessMessage(MediaFoundation.MessageBeginStreaming, IntPtr.Zero), "begin streaming");
    MediaFoundation.Check(transform.ProcessMessage(MediaFoundation.MessageStartOfStream, IntPtr.Zero), "start of stream");
  }

  /// The GPU's encoder when Windows has one that takes NV12, else the software one. Both sides even.
  public static WindowsH264Encoder Create(int width, int height, int fps, int bitrate, bool preferHardware = true)
  {
    if (width % 2 != 0 || height % 2 != 0 || width < 16 || height < 16) throw new ArgumentException("H.264 needs even sizes of at least 16.");
    MediaFoundation.Start();
    if (preferHardware)
    {
      var input = new MediaFoundation.TypeInfo { Major = MediaFoundation.MediaTypeVideo, Sub = MediaFoundation.FormatNv12 };
      var output = new MediaFoundation.TypeInfo { Major = MediaFoundation.MediaTypeVideo, Sub = MediaFoundation.FormatH264 };
      if (MediaFoundation.MFTEnumEx(MediaFoundation.VideoEncoderCategory, MediaFoundation.EnumHardware | MediaFoundation.EnumSortAndFilter, ref input, ref output, out var list, out var count) >= 0 && list != IntPtr.Zero)
      {
        var found = new List<IMFActivate>();
        for (var i = 0; i < count; i++)
        {
          var pointer = Marshal.ReadIntPtr(list, i * IntPtr.Size);
          found.Add((IMFActivate)Marshal.GetObjectForIUnknown(pointer));
          Marshal.Release(pointer);
        }
        Marshal.FreeCoTaskMem(list);
        foreach (var candidate in found)
        {
          var name = FriendlyName(candidate);
          try
          {
            var iid = MediaFoundation.TransformInterface;
            MediaFoundation.Check(candidate.ActivateObject(ref iid, out var pointer), "ActivateObject");
            var made = (IMFTransform)Marshal.GetObjectForIUnknown(pointer);
            Marshal.Release(pointer);
            var encoder = new WindowsH264Encoder(made, candidate, "hardware: " + name, true, width, height, fps, bitrate);
            foreach (var other in found.Where(f => !ReferenceEquals(f, candidate))) Marshal.ReleaseComObject(other);
            return encoder;
          }
          catch (Exception ex) when (ex is COMException or InvalidCastException or ArgumentException)
          {
            Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " video: " + name + " refused (" + ex.Message + "); trying the next encoder");
            try { candidate.ShutdownObject(); } catch (COMException) { }
          }
        }
        foreach (var other in found) Marshal.ReleaseComObject(other);
      }
    }
    var software = (IMFTransform)(Activator.CreateInstance(Type.GetTypeFromCLSID(MediaFoundation.SoftwareH264Encoder, true)!)
      ?? throw new COMException("No H.264 encoder on this PC."));
    return new WindowsH264Encoder(software, null, "software: Microsoft H.264 encoder", false, width, height, fps, bitrate);
  }

  private static string FriendlyName(IMFActivate activate)
  {
    try
    {
      var attributes = (IMFAttributes)activate;
      var key = MediaFoundation.FriendlyName;
      if (attributes.GetAllocatedString(ref key, out var text, out _) < 0) return "GPU encoder";
      try { return Marshal.PtrToStringUni(text) ?? "GPU encoder"; } finally { Marshal.FreeCoTaskMem(text); }
    }
    catch (InvalidCastException) { return "GPU encoder"; }
  }

  private void Set(Guid api, MediaFoundation.Variant value)
  {
    if (codec is null) return;
    var key = api;
    // Not every encoder knows every setting; the ones it refuses keep their defaults.
    _ = codec.SetValue(ref key, ref value);
  }

  public int Bitrate
  {
    get => bitrate;
    set { bitrate = value; Set(MediaFoundation.CodecMeanBitrate, MediaFoundation.UInt32((uint)value)); }
  }

  // Some encoders give the parameter sets only in the output type (MF_MT_MPEG_SEQUENCE_HEADER), not in-band.
  private void ReadSequenceHeader()
  {
    if (transform.GetOutputCurrentType(0, out var type) < 0 || type == IntPtr.Zero) return;
    var attributes = MediaFoundation.Attributes(type);
    try
    {
      var key = MediaFoundation.SequenceHeader;
      if (attributes.GetBlobSize(ref key, out var size) < 0 || size == 0 || size > 4096) return;
      var blob = new byte[size];
      if (attributes.GetBlob(ref key, blob, size, out var written) < 0) return;
      foreach (var nal in AnnexB.Units(blob.AsSpan(0, (int)written)))
      {
        if ((nal[0] & 0x1F) == 7) sps = nal;
        else if ((nal[0] & 0x1F) == 8) pps = nal;
      }
    }
    finally { Marshal.ReleaseComObject(attributes); Marshal.Release(type); }
  }

  /// One NV12 picture (Width × Height) in; every encoded picture that is ready out, in order (an encoder may hold one
  /// back and hand two over later; each depends on the one before, so none may be dropped). Empty when nothing is
  /// ready yet; when a GPU encoder takes no input in time the picture is not encoded at all (caller asks a keyframe).
  public List<H264Frame> Encode(byte[] nv12, bool key)
  {
    ObjectDisposedException.ThrowIf(lifetime.Closed, this);
    if (nv12.Length < Width * Height * 3 / 2) throw new ArgumentException("NV12 picture too small.");
    if (key) Set(MediaFoundation.CodecForceKeyFrame, MediaFoundation.UInt32(1));
    var sample = Sample(nv12);
    try
    {
      var ready = new List<H264Frame>();
      if (Hardware)
      {
        if (lifetime.Failed) { Refused++; return ready; } // its event thread is gone: Stalled hands over at once
        if (!inputs.Wait(250)) { Refused++; refusedInARow++; return ready; }
        refusedInARow = 0;
        MediaFoundation.Check(transform.ProcessInput(0, sample, 0), "ProcessInput");
        // Its own picture usually follows within a few milliseconds; whatever else is ready comes too.
        if (outputs.TryTake(out var first, 60)) ready.Add(first);
        while (outputs.TryTake(out var more)) ready.Add(more);
        return ready;
      }
      MediaFoundation.Check(transform.ProcessInput(0, sample, 0), "ProcessInput");
      while (Drain() is { } next) ready.Add(next);
      return ready;
    }
    finally { Marshal.ReleaseComObject(sample); }
  }

  private IMFSample Sample(byte[] nv12)
  {
    MediaFoundation.Check(MediaFoundation.MFCreateSample(out var sample), "MFCreateSample");
    var length = Width * Height * 3 / 2;
    MediaFoundation.Check(MediaFoundation.MFCreateMemoryBuffer(length, out var buffer), "MFCreateMemoryBuffer");
    try
    {
      MediaFoundation.Check(buffer.Lock(out var data, out _, out _), "Lock");
      try { Marshal.Copy(nv12, 0, data, length); } finally { buffer.Unlock(); }
      MediaFoundation.Check(buffer.SetCurrentLength(length), "SetCurrentLength");
      MediaFoundation.Check(sample.AddBuffer(buffer), "AddBuffer");
    }
    finally { Marshal.ReleaseComObject(buffer); }
    var duration = 10_000_000L / Fps;
    sample.SetSampleTime(time); sample.SetSampleDuration(duration);
    time += duration;
    return sample;
  }

  // One ProcessOutput: a frame, or null when the encoder needs more input.
  private H264Frame? Drain()
  {
    IMFSample? mine = null;
    var buffers = new MediaFoundation.OutputDataBuffer[1];
    if (!providesSamples)
    {
      MediaFoundation.Check(MediaFoundation.MFCreateSample(out mine), "MFCreateSample");
      MediaFoundation.Check(MediaFoundation.MFCreateMemoryBuffer(outputSize, out var buffer), "MFCreateMemoryBuffer");
      mine.AddBuffer(buffer);
      Marshal.ReleaseComObject(buffer);
      buffers[0].Sample = Marshal.GetIUnknownForObject(mine);
    }
    try
    {
      var hr = transform.ProcessOutput(0, 1, buffers, out _);
      if (hr == MediaFoundation.NeedMoreInput) return null;
      if (hr == MediaFoundation.StreamChange)
      {
        // The encoder settled its output type (parameter sets may now be in it); ask again.
        if (transform.GetOutputAvailableType(0, 0, out var type) >= 0) { transform.SetOutputType(0, type, 0); Marshal.Release(type); }
        ReadSequenceHeader();
        return null;
      }
      MediaFoundation.Check(hr, "ProcessOutput");
      if (buffers[0].Events != IntPtr.Zero) Marshal.Release(buffers[0].Events);
      if (buffers[0].Sample == IntPtr.Zero) return null;
      var sample = (IMFSample)Marshal.GetObjectForIUnknown(buffers[0].Sample);
      try
      {
        MediaFoundation.Check(sample.ConvertToContiguousBuffer(out var contiguous), "ConvertToContiguousBuffer");
        try
        {
          MediaFoundation.Check(contiguous.Lock(out var data, out _, out var current), "Lock");
          byte[] bytes;
          try { bytes = new byte[current]; Marshal.Copy(data, bytes, 0, current); } finally { contiguous.Unlock(); }
          return Frame(bytes);
        }
        finally { Marshal.ReleaseComObject(contiguous); }
      }
      finally { Marshal.ReleaseComObject(sample); }
    }
    finally
    {
      if (buffers[0].Sample != IntPtr.Zero) Marshal.Release(buffers[0].Sample);
      if (mine is not null) Marshal.ReleaseComObject(mine);
    }
  }

  // Annex B → AVCC; the parameter sets go separately (and are remembered for keyframes that lack them in-band).
  private H264Frame Frame(byte[] annexB)
  {
    using var avcc = new MemoryStream(annexB.Length + 16);
    var key = false;
    Span<byte> length = stackalloc byte[4];
    foreach (var nal in AnnexB.Units(annexB))
    {
      switch (nal[0] & 0x1F)
      {
        case 7: sps = nal; continue;
        case 8: pps = nal; continue;
        case 9: continue; // access unit delimiter
        case 5: key = true; break;
      }
      System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(length, nal.Length);
      avcc.Write(length);
      avcc.Write(nal);
    }
    return new H264Frame(avcc.ToArray(), key, key ? sps : null, key ? pps : null);
  }

  // Asynchronous (GPU) encoders: input is allowed after each "need input", output is collected on "have output".
  // EncoderEventThread runs these: it re-checks Closed after every wait, ends on any exception, and lets the transform
  // go only after this thread has left (M4: a late event after a timed-out Dispose used to hit a released RCW).
  private uint? NextEvent(EncoderEventThread loop)
  {
    var failures = 0;
    while (!loop.Closed)
    {
      var hr = ((IMFMediaEventGenerator)transform).GetEvent(0, out var pointer);
      if (hr < 0)
      {
        if (hr == MediaFoundation.ShutdownError || ++failures >= 200) return null; // ~1 s of nothing but errors: stalled
        Thread.Sleep(5);
        continue;
      }
      try
      {
        var mediaEvent = (IMFMediaEvent)Marshal.GetObjectForIUnknown(pointer);
        try { mediaEvent.GetType(out var type); return type; } finally { Marshal.ReleaseComObject(mediaEvent); }
      }
      finally { Marshal.Release(pointer); }
    }
    return null;
  }

  private void OnEvent(uint type)
  {
    if (Interlocked.Increment(ref eventsSeen) <= 6) Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " video: encoder event " + type);
    if (type == MediaFoundation.EventNeedInput) inputs.Release();
    else if (type == MediaFoundation.EventHaveOutput && Drain() is { } frame) outputs.Add(frame);
  }

  // The last holder out: codec and the event generator are casts of the transform's one RCW, released once here.
  private void Release()
  {
    try { Marshal.ReleaseComObject(transform); }
    finally { if (activate is not null) Marshal.ReleaseComObject(activate); }
  }

  public void Dispose()
  {
    if (!lifetime.Close()) return;
    // A GPU driver can stop answering: the shutdown runs on its own thread and is given 3 s. Nothing in it throws.
    var shutdown = Task.Run(() =>
    {
      try { transform.ProcessMessage(MediaFoundation.MessageEndOfStream, IntPtr.Zero); transform.ProcessMessage(MediaFoundation.MessageEndStreaming, IntPtr.Zero); }
      catch (Exception ex) { Quiet("end of stream", ex); }
      try { if (transform is IMFShutdown down) down.Shutdown(); } catch (Exception ex) { Quiet("shutdown", ex); }
      try { activate?.ShutdownObject(); } catch (Exception ex) { Quiet("shutdown object", ex); }
      // Never let go while the event thread may still use it: if it is still inside the driver, it lets go on return.
      if (!lifetime.Leave(TimeSpan.FromSeconds(1)) && lifetime.Releases == 0)
        Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " video: " + Name + " event thread still inside the driver; it lets the encoder go when it returns");
    });
    if (!shutdown.Wait(3000)) Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " video: " + Name + " did not shut down within 3 s");
  }

  private void Quiet(string step, Exception ex) =>
    Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " video: " + Name + " " + step + " failed (" + ex.GetType().Name + ")");
}

/// H.264 Annex B helpers.
public static class AnnexB
{
  /// The NAL units between start codes (00 00 01 / 00 00 00 01).
  public static List<byte[]> Units(ReadOnlySpan<byte> stream)
  {
    var units = new List<byte[]>();
    var start = -1;
    for (var i = 0; i + 2 < stream.Length;)
    {
      if (stream[i] == 0 && stream[i + 1] == 0 && stream[i + 2] == 1)
      {
        if (start >= 0) Add(units, stream, start, i);
        i += 3; start = i;
        continue;
      }
      i++;
    }
    if (start >= 0 && start < stream.Length) Add(units, stream, start, stream.Length);
    return units;
  }

  // A unit ends before the next start code's leading zero (00 00 00 01) and any trailing zeros.
  private static void Add(List<byte[]> units, ReadOnlySpan<byte> stream, int start, int end)
  {
    while (end > start && stream[end - 1] == 0) end--;
    if (end > start) units.Add(stream[start..end].ToArray());
  }
}

/// BGRA (top-down, as GDI gives it) → NV12, BT.709 limited range (the matrix the encoder's output type names).
/// Brightness 32 pixels at a time (SIMD), colour per 2×2 block; rows split over up to 4 cores.
public static class Nv12
{
  public static byte[] FromBgra(byte[] bgra, int width, int height, byte[]? into = null)
  {
    var size = width * height * 3 / 2;
    var nv12 = into is { } given && given.Length >= size ? given : new byte[size];
    var stride = width * 4;
    Parallel.For(0, height / 2, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Math.Min(4, Environment.ProcessorCount / 2)) }, pair =>
    {
      var y0 = pair * 2;
      Luma(bgra.AsSpan(y0 * stride, stride), nv12.AsSpan(y0 * width, width));
      Luma(bgra.AsSpan((y0 + 1) * stride, stride), nv12.AsSpan((y0 + 1) * width, width));
      var uv = width * height + pair * width;
      var top = y0 * stride;
      var bottom = top + stride;
      for (var x = 0; x < width; x += 2)
      {
        var i = x * 4;
        int b = bgra[top + i] + bgra[top + i + 4] + bgra[bottom + i] + bgra[bottom + i + 4];
        int g = bgra[top + i + 1] + bgra[top + i + 5] + bgra[bottom + i + 1] + bgra[bottom + i + 5];
        int r = bgra[top + i + 2] + bgra[top + i + 6] + bgra[bottom + i + 2] + bgra[bottom + i + 6];
        nv12[uv + x] = (byte)Math.Clamp(((-26 * r - 87 * g + 112 * b + 512) >> 10) + 128, 0, 255);
        nv12[uv + x + 1] = (byte)Math.Clamp(((112 * r - 102 * g - 10 * b + 512) >> 10) + 128, 0, 255);
      }
    });
    return nv12;
  }

  private static readonly System.Numerics.Vector<uint> Mask = new(0xFF), Round = new(128), Sixteen = new(16);

  // Y = 16 + (47 R + 157 G + 16 B + 128) / 256 for one row.
  private static void Luma(ReadOnlySpan<byte> row, Span<byte> luma)
  {
    var pixels = System.Runtime.InteropServices.MemoryMarshal.Cast<byte, uint>(row);
    var n = System.Numerics.Vector<uint>.Count;
    var x = 0;
    if (System.Numerics.Vector.IsHardwareAccelerated)
    {
      for (; x + 4 * n <= pixels.Length; x += 4 * n)
      {
        var low = System.Numerics.Vector.Narrow(Y(pixels.Slice(x, n)), Y(pixels.Slice(x + n, n)));
        var high = System.Numerics.Vector.Narrow(Y(pixels.Slice(x + 2 * n, n)), Y(pixels.Slice(x + 3 * n, n)));
        System.Numerics.Vector.Narrow(low, high).CopyTo(luma.Slice(x));
      }
    }
    for (; x < pixels.Length; x++)
    {
      var p = pixels[x];
      uint b = p & 0xFF, g = (p >> 8) & 0xFF, r = (p >> 16) & 0xFF;
      luma[x] = (byte)(((47 * r + 157 * g + 16 * b + 128) >> 8) + 16);
    }
  }

  private static System.Numerics.Vector<uint> Y(ReadOnlySpan<uint> pixels)
  {
    var v = new System.Numerics.Vector<uint>(pixels);
    var b = v & Mask;
    var g = System.Numerics.Vector.ShiftRightLogical(v, 8) & Mask;
    var r = System.Numerics.Vector.ShiftRightLogical(v, 16) & Mask;
    return System.Numerics.Vector.ShiftRightLogical(r * 47u + g * 157u + b * 16u + Round, 8) + Sixteen;
  }
}
