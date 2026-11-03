using System.Runtime.InteropServices;

namespace TerminalDeck.Platform.Windows.Phone;

// The few Media Foundation pieces the H.264 screen encoder (and the tests' decoder) use. Interfaces list every vtable
// slot up to the last one called (unused slots are placeholders), because a COM interface's methods are found by
// position. An object that is also an IMFAttributes (a media type, a sample, an activate, an event) is read and
// written through the IMFAttributes cast (QueryInterface), so the derived interfaces only declare their own slots.
public static class MediaFoundation
{
  public const int Version = 0x00020070;
  public const uint EnumHardware = 0x4, EnumSortAndFilter = 0x40, EnumSyncMft = 0x1, EnumAsyncMft = 0x2;
  public const uint MessageFlush = 0x0, MessageBeginStreaming = 0x10000000, MessageEndStreaming = 0x10000001, MessageEndOfStream = 0x10000002, MessageStartOfStream = 0x10000003;
  public const int NeedMoreInput = unchecked((int)0xC00D6D72), StreamChange = unchecked((int)0xC00D6D61), NoEventsAvailable = unchecked((int)0xC00D3E80), ShutdownError = unchecked((int)0xC00D3E85);
  public const uint ProvidesSamples = 0x100, CanProvideSamples = 0x200;
  public const uint EventNeedInput = 601, EventHaveOutput = 602;

  public static readonly Guid VideoEncoderCategory = new("f79eac7d-e545-4387-bdee-d647d7bde42a");
  public static readonly Guid VideoDecoderCategory = new("d6c02d4b-6833-45b4-971a-05a4b04bab91");
  public static readonly Guid MediaTypeVideo = new("73646976-0000-0010-8000-00AA00389B71");
  public static readonly Guid FormatNv12 = new("3231564E-0000-0010-8000-00AA00389B71");
  public static readonly Guid FormatH264 = new("34363248-0000-0010-8000-00AA00389B71");
  public static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
  public static readonly Guid Subtype = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
  public static readonly Guid AverageBitrate = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
  public static readonly Guid InterlaceMode = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
  public static readonly Guid FrameSize = new("1652c33d-d6b2-4012-b834-72030849a37d");
  public static readonly Guid FrameRate = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
  public static readonly Guid PixelAspectRatio = new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
  public static readonly Guid Mpeg2Profile = new("ad76a80b-2d5c-4e0b-b375-64e520137036");
  public static readonly Guid SequenceHeader = new("3c036de7-3ad0-4c9e-9216-ee6d6ac21cb3");
  public static readonly Guid DefaultStride = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
  public static readonly Guid YuvMatrix = new("3e23d450-2c75-4d25-a00e-b91670d12327");
  public static readonly Guid VideoPrimaries = new("dbfbe4d7-0740-4ee0-8192-850ab0e21935");
  public static readonly Guid TransferFunction = new("5fb0fce9-be5c-4935-a811-ec838f8eed93");
  public static readonly Guid NominalRange = new("c21b8ee5-b956-4071-8daf-325edf5cab11");
  public static readonly Guid AsyncUnlock = new("e5666d6b-3422-4eb6-a421-da7db1f8e207");
  public static readonly Guid FriendlyName = new("314ffbae-5b41-4c95-9c19-4e7d586face3");
  public static readonly Guid LowLatency = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
  public static readonly Guid SoftwareH264Encoder = new("6ca50344-051a-4ded-9779-a43305165e35");
  public static readonly Guid SoftwareH264Decoder = new("62ce7e72-4c71-4d20-b15d-452831a87d9d");
  public static readonly Guid TransformInterface = new("bf94c121-5b05-4e6f-8000-ba598961414d");
  // Codec API settings (codecapi.h).
  public static readonly Guid CodecLowLatency = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
  public static readonly Guid CodecRateControl = new("1c0608e9-370c-4710-8a58-cb6181c42423");
  public static readonly Guid CodecMeanBitrate = new("f7222374-2144-4815-b550-a37f8e12ee52");
  public static readonly Guid CodecBPictures = new("8d390aac-dc5c-4200-b57f-814d04babab2");
  public static readonly Guid CodecGopSize = new("95f31b26-95a4-41aa-9303-246a7fc6eef1");
  public static readonly Guid CodecForceKeyFrame = new("398c1b98-8353-475a-9ef2-8f265d260345");
  public static readonly Guid CodecBufferSize = new("0db96574-b6a4-4c8b-8106-3773de0310cd");

  [DllImport("mfplat.dll")] public static extern int MFStartup(int version, int flags);
  [DllImport("mfplat.dll")] public static extern int MFCreateMediaType(out IntPtr type);
  [DllImport("mfplat.dll")] public static extern int MFCreateSample(out IMFSample sample);
  [DllImport("mfplat.dll")] public static extern int MFCreateMemoryBuffer(int maxLength, out IMFMediaBuffer buffer);
  [DllImport("mfplat.dll")] public static extern int MFTEnumEx(Guid category, uint flags, ref TypeInfo input, ref TypeInfo output, out IntPtr activates, out uint count);

  [StructLayout(LayoutKind.Sequential)] public struct TypeInfo { public Guid Major; public Guid Sub; }
  [StructLayout(LayoutKind.Sequential)] public struct OutputStreamInfo { public uint Flags; public uint Size; public uint Alignment; }
  [StructLayout(LayoutKind.Sequential)] public struct OutputDataBuffer { public uint StreamId; public IntPtr Sample; public uint Status; public IntPtr Events; }
  // A VARIANT (24 bytes on 64-bit Windows): the type at 0, the value at 8.
  [StructLayout(LayoutKind.Explicit, Size = 24)] public struct Variant { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public long Value; }
  public static Variant UInt32(uint value) => new() { Type = 19, Value = value };       // VT_UI4
  public static Variant Bool(bool value) => new() { Type = 11, Value = value ? 0xFFFF : 0 }; // VT_BOOL

  private static int started;
  public static void Start()
  {
    if (Interlocked.Exchange(ref started, 1) != 0) return;
    Check(MFStartup(Version, 0), "MFStartup");
  }

  public static void Check(int hr, string what)
  {
    if (hr < 0) throw new COMException("Media Foundation " + what + " failed (0x" + hr.ToString("X8") + ").", hr);
  }

  public static IntPtr NewType(params (Guid Key, object Value)[] values)
  {
    Check(MFCreateMediaType(out var type), "MFCreateMediaType");
    var attributes = (IMFAttributes)Marshal.GetObjectForIUnknown(type);
    try
    {
      foreach (var (key, value) in values)
      {
        var k = key;
        Check(value switch
        {
          Guid g => attributes.SetGUID(ref k, ref g),
          uint u => attributes.SetUINT32(ref k, u),
          ulong l => attributes.SetUINT64(ref k, l),
          _ => throw new ArgumentException("unsupported attribute")
        }, "set attribute");
      }
    }
    finally { Marshal.ReleaseComObject(attributes); }
    return type;
  }

  public static ulong Pair(int high, int low) => ((ulong)(uint)high << 32) | (uint)low;

  public static IMFAttributes Attributes(IntPtr unknown) => (IMFAttributes)Marshal.GetObjectForIUnknown(unknown);
}

[ComImport, Guid("2cd2d921-c447-44a7-a13c-4adabfc247e3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMFAttributes
{
  void GetItem(); void GetItemType(); void CompareItem(); void Compare();
  [PreserveSig] int GetUINT32(ref Guid key, out uint value);
  [PreserveSig] int GetUINT64(ref Guid key, out ulong value);
  void GetDouble();
  [PreserveSig] int GetGUID(ref Guid key, out Guid value);
  void GetStringLength(); void GetString();
  [PreserveSig] int GetAllocatedString(ref Guid key, out IntPtr value, out uint length);
  [PreserveSig] int GetBlobSize(ref Guid key, out uint size);
  // COM interop passes arrays as SAFEARRAYs unless told otherwise: these are C arrays.
  [PreserveSig] int GetBlob(ref Guid key, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 2)] byte[] buffer, uint size, out uint written);
  void GetAllocatedBlob(); void GetUnknown(); void SetItem(); void DeleteItem(); void DeleteAllItems();
  [PreserveSig] int SetUINT32(ref Guid key, uint value);
  [PreserveSig] int SetUINT64(ref Guid key, ulong value);
  void SetDouble();
  [PreserveSig] int SetGUID(ref Guid key, ref Guid value);
}

[ComImport, Guid("bf94c121-5b05-4e6f-8000-ba598961414d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMFTransform
{
  void GetStreamLimits(); void GetStreamCount(); void GetStreamIDs(); void GetInputStreamInfo();
  [PreserveSig] int GetOutputStreamInfo(uint stream, out MediaFoundation.OutputStreamInfo info);
  [PreserveSig] int GetAttributes(out IntPtr attributes);
  void GetInputStreamAttributes(); void GetOutputStreamAttributes(); void DeleteInputStream(); void AddInputStreams();
  [PreserveSig] int GetInputAvailableType(uint stream, uint index, out IntPtr type);
  [PreserveSig] int GetOutputAvailableType(uint stream, uint index, out IntPtr type);
  [PreserveSig] int SetInputType(uint stream, IntPtr type, uint flags);
  [PreserveSig] int SetOutputType(uint stream, IntPtr type, uint flags);
  [PreserveSig] int GetInputCurrentType(uint stream, out IntPtr type);
  [PreserveSig] int GetOutputCurrentType(uint stream, out IntPtr type);
  void GetInputStatus(); void GetOutputStatus(); void SetOutputBounds(); void ProcessEvent();
  [PreserveSig] int ProcessMessage(uint message, IntPtr parameter);
  [PreserveSig] int ProcessInput(uint stream, IMFSample sample, uint flags);
  [PreserveSig] int ProcessOutput(uint flags, uint count, [In, Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] MediaFoundation.OutputDataBuffer[] buffers, out uint status);
}

[ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMFSample
{
  // IMFAttributes (30 slots), then IMFSample's own.
  void A01(); void A02(); void A03(); void A04(); void A05(); void A06(); void A07(); void A08(); void A09(); void A10();
  void A11(); void A12(); void A13(); void A14(); void A15(); void A16(); void A17(); void A18(); void A19(); void A20();
  void A21(); void A22(); void A23(); void A24(); void A25(); void A26(); void A27(); void A28(); void A29(); void A30();
  void GetSampleFlags(); void SetSampleFlags();
  [PreserveSig] int GetSampleTime(out long time);
  [PreserveSig] int SetSampleTime(long time);
  void GetSampleDuration();
  [PreserveSig] int SetSampleDuration(long duration);
  void GetBufferCount(); void GetBufferByIndex();
  [PreserveSig] int ConvertToContiguousBuffer(out IMFMediaBuffer buffer);
  [PreserveSig] int AddBuffer(IMFMediaBuffer buffer);
}

[ComImport, Guid("045fa593-8799-42b8-bc8d-8968c6453507"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMFMediaBuffer
{
  [PreserveSig] int Lock(out IntPtr data, out int maxLength, out int currentLength);
  [PreserveSig] int Unlock();
  [PreserveSig] int GetCurrentLength(out int length);
  [PreserveSig] int SetCurrentLength(int length);
}

[ComImport, Guid("7fee9e9a-4a89-47a6-899c-b6a53a70fb67"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMFActivate
{
  void A01(); void A02(); void A03(); void A04(); void A05(); void A06(); void A07(); void A08(); void A09(); void A10();
  void A11(); void A12(); void A13(); void A14(); void A15(); void A16(); void A17(); void A18(); void A19(); void A20();
  void A21(); void A22(); void A23(); void A24(); void A25(); void A26(); void A27(); void A28(); void A29(); void A30();
  [PreserveSig] int ActivateObject(ref Guid riid, out IntPtr instance);
  [PreserveSig] int ShutdownObject();
}

[ComImport, Guid("2cd0bd52-bcd5-4b89-b62c-eadc0c031e7d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMFMediaEventGenerator
{
  [PreserveSig] int GetEvent(uint flags, out IntPtr mediaEvent);
}

[ComImport, Guid("df598932-f10c-4e39-bba2-c308f101daa3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMFMediaEvent
{
  void A01(); void A02(); void A03(); void A04(); void A05(); void A06(); void A07(); void A08(); void A09(); void A10();
  void A11(); void A12(); void A13(); void A14(); void A15(); void A16(); void A17(); void A18(); void A19(); void A20();
  void A21(); void A22(); void A23(); void A24(); void A25(); void A26(); void A27(); void A28(); void A29(); void A30();
  [PreserveSig] int GetType(out uint type);
}

[ComImport, Guid("97ec2ea4-0e42-4937-97ac-9d6d328824e1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMFShutdown
{
  [PreserveSig] int Shutdown();
}

[ComImport, Guid("901db4c7-31ce-41a2-85dc-8fa0bf41b8da"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ICodecAPI
{
  [PreserveSig] int IsSupported(ref Guid api);
  [PreserveSig] int IsModifiable(ref Guid api);
  void GetParameterRange(); void GetParameterValues(); void GetDefaultValue(); void GetValue();
  [PreserveSig] int SetValue(ref Guid api, ref MediaFoundation.Variant value);
}
