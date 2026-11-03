using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Platform.Windows.Phone;

// One Activity reading in the phone's activity.sample shape (the same fields the Mac sends).
// CPU, network and per-process CPU are deltas between calls, so the first reading has none.
public sealed class WindowsSystemActivity(Func<IReadOnlyList<ActivitySessionRoot>> sessionRoots, string diskPath) : ISystemActivityReader
{
  private const int TopCount = 6;
  private const double BusyPercent = 80;
  private const int ProcessorInfoSize = 48; // SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION on x64 and x86
  private readonly Lock gate = new();
  private (long Busy, long Total)[]? previousCores;
  private (long In, long Out, long At)? previousNet;
  private Dictionary<(int Pid, long Created), long> previousProcessTimes = [];
  private long previousTopAt;
  private int coreCount = Environment.ProcessorCount;

  public JsonObject Sample(bool top)
  {
    lock (gate)
    {
      var reading = new JsonObject { ["at"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() };
      double? cpuTotal = null;
      try { reading["cpu"] = Cpu(out cpuTotal); }
      catch (Exception) { reading["cpu"] = new JsonObject { ["total"] = null, ["cores"] = new JsonArray(), ["count"] = coreCount }; }

      string? pressure = null;
      try { reading["memory"] = Memory(out pressure) ?? new JsonObject(); }
      catch (Exception) { reading["memory"] = new JsonObject(); }

      reading["load"] = null;

      try { reading["disk"] = Disk(); }
      catch (Exception) { reading["disk"] = new JsonObject { ["free"] = null, ["total"] = null }; }

      try { reading["net"] = Net(); }
      catch (Exception) { reading["net"] = new JsonObject { ["in"] = null, ["out"] = null }; }

      reading["busy"] = (cpuTotal ?? 0) >= BusyPercent || (pressure is not null && pressure != "normal");

      if (top)
      {
        List<Group> groups;
        try { groups = Groups(); }
        catch (Exception) { groups = []; }
        reading["topCPU"] = Rows(groups.OrderByDescending(g => g.Cpu));
        reading["topMemory"] = Rows(groups.OrderByDescending(g => g.Memory));
      }
      return reading;
    }
  }

  private static double Round1(double value) => Math.Round(value * 10, MidpointRounding.AwayFromZero) / 10;

  // CPU: per-core busy share since the last reading.
  private JsonObject Cpu(out double? total)
  {
    total = null;
    var current = ReadCores();
    if (current is not null && current.Length > 0) coreCount = current.Length;
    var cores = new JsonArray();
    if (current is not null && previousCores is not null && previousCores.Length == current.Length)
    {
      var sum = 0.0;
      for (var i = 0; i < current.Length; i++)
      {
        long busy = current[i].Busy - previousCores[i].Busy, all = current[i].Total - previousCores[i].Total;
        var percent = all > 0 ? Math.Clamp(busy * 100.0 / all, 0, 100) : 0;
        sum += percent;
        cores.Add(Round1(percent));
      }
      total = Round1(sum / current.Length);
    }
    if (current is not null) previousCores = current;
    return new JsonObject { ["total"] = total, ["cores"] = cores, ["count"] = coreCount };
  }

  private static (long Busy, long Total)[]? ReadCores()
  {
    const int MaxCores = 1024;
    var buffer = Marshal.AllocHGlobal(ProcessorInfoSize * MaxCores);
    try
    {
      if (NtQuerySystemInformation(8, buffer, ProcessorInfoSize * MaxCores, out var returned) != 0) return null;
      var count = returned / ProcessorInfoSize;
      var cores = new (long Busy, long Total)[count];
      for (var i = 0; i < count; i++)
      {
        var at = i * ProcessorInfoSize;
        long idle = Marshal.ReadInt64(buffer, at), kernel = Marshal.ReadInt64(buffer, at + 8), user = Marshal.ReadInt64(buffer, at + 16);
        var all = kernel + user; // kernel time includes idle time
        cores[i] = (all - idle, all);
      }
      return cores;
    }
    finally { Marshal.FreeHGlobal(buffer); }
  }

  // Memory: physical use, Windows' memory load as pressure, and the page file beyond RAM as swap.
  private static JsonObject? Memory(out string? pressure)
  {
    pressure = null;
    var status = new MemoryStatusEx { Length = (uint)Marshal.SizeOf<MemoryStatusEx>() };
    if (!GlobalMemoryStatusEx(ref status)) return null;
    var used = status.TotalPhys >= status.AvailPhys ? status.TotalPhys - status.AvailPhys : 0;
    pressure = status.MemoryLoad >= 95 ? "critical" : status.MemoryLoad >= 85 ? "warn" : "normal";
    var swapTotal = status.TotalPageFile > status.TotalPhys ? status.TotalPageFile - status.TotalPhys : 0;
    var committed = status.TotalPageFile >= status.AvailPageFile ? (double)(status.TotalPageFile - status.AvailPageFile) : 0;
    var swapUsed = (ulong)Math.Clamp(committed - used, 0, swapTotal);
    return new JsonObject { ["used"] = used, ["total"] = status.TotalPhys, ["pressure"] = pressure, ["swapUsed"] = swapUsed, ["swapTotal"] = swapTotal };
  }

  private JsonObject Disk()
  {
    var root = Path.GetPathRoot(Path.GetFullPath(diskPath));
    if (string.IsNullOrEmpty(root)) return new JsonObject { ["free"] = null, ["total"] = null };
    var drive = new DriveInfo(root);
    return new JsonObject { ["free"] = drive.AvailableFreeSpace, ["total"] = drive.TotalSize };
  }

  // Network: bytes a second across the connected interfaces (not loopback or tunnels).
  private JsonObject Net()
  {
    long received = 0, sent = 0;
    foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
    {
      try
      {
        if (adapter.OperationalStatus != OperationalStatus.Up || adapter.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
        var stats = adapter.GetIPStatistics();
        received += stats.BytesReceived;
        sent += stats.BytesSent;
      }
      catch (Exception e) when (e is NetworkInformationException or PlatformNotSupportedException or InvalidOperationException) { }
    }
    var now = Stopwatch.GetTimestamp();
    JsonNode? rateIn = null, rateOut = null;
    if (previousNet is { } before && now > before.At)
    {
      var seconds = Stopwatch.GetElapsedTime(before.At, now).TotalSeconds;
      if (seconds > 0)
      {
        rateIn = Math.Round(Math.Max(0, received - before.In) / seconds);
        rateOut = Math.Round(Math.Max(0, sent - before.Out) / seconds);
      }
    }
    previousNet = (received, sent, now);
    return new JsonObject { ["in"] = rateIn, ["out"] = rateOut };
  }

  private sealed class Group(string name, string kind)
  {
    public string Name { get; } = name;
    public string Kind { get; set; } = kind;
    public double Cpu { get; set; }
    public ulong Memory { get; set; }
    public int Processes { get; set; }
  }

  private sealed record ProcessRow(int Pid, int ParentPid, string Exe, long Created, double Cpu, ulong Memory);

  private static JsonArray Rows(IEnumerable<Group> groups)
  {
    var rows = new JsonArray();
    foreach (var group in groups.Take(TopCount))
      rows.Add(new JsonObject
      {
        ["name"] = group.Name.Length > 80 ? group.Name[..80] : group.Name,
        ["kind"] = group.Kind,
        ["cpu"] = Round1(group.Cpu),
        ["memory"] = group.Memory,
        ["processes"] = group.Processes,
      });
    return rows;
  }

  // Processes grouped by Terminal Deck session (everything under a session's worker), else by program.
  private List<Group> Groups()
  {
    var now = Stopwatch.GetTimestamp();
    var elapsed100ns = previousTopAt == 0 ? 0 : Stopwatch.GetElapsedTime(previousTopAt, now).TotalSeconds * 10_000_000;
    var capacity = elapsed100ns * Math.Max(1, coreCount);
    var times = new Dictionary<(int Pid, long Created), long>();
    var parents = new Dictionary<int, int>();
    var created = new Dictionary<int, long>();
    var rows = new List<ProcessRow>();

    foreach (var (pid, parentPid, exe) in Snapshot())
    {
      if (pid == 0) continue;
      parents[pid] = parentPid;
      var process = OpenProcess(ProcessQueryLimitedInformation, false, pid);
      if (process == IntPtr.Zero) continue;
      try
      {
        if (!GetProcessTimes(process, out var creation, out _, out var kernel, out var user)) continue;
        created[pid] = creation;
        var cpuTime = kernel + user;
        times[(pid, creation)] = cpuTime;
        var cpu = 0.0;
        if (capacity > 0 && previousProcessTimes.TryGetValue((pid, creation), out var before) && cpuTime >= before)
          cpu = (cpuTime - before) * 100.0 / capacity;
        var counters = new ProcessMemoryCountersEx { Size = (uint)Marshal.SizeOf<ProcessMemoryCountersEx>() };
        ulong memory = GetProcessMemoryInfo(process, ref counters, counters.Size) ? counters.PrivateUsage : 0;
        rows.Add(new ProcessRow(pid, parentPid, exe, creation, cpu, memory));
      }
      finally { CloseHandle(process); }
    }
    previousProcessTimes = times;
    previousTopAt = now;

    var roots = new Dictionary<int, ActivitySessionRoot>();
    try
    {
      foreach (var root in sessionRoots())
        if (created.TryGetValue(root.ProcessId, out var rootCreated) && Math.Abs(DateTime.FromFileTimeUtc(rootCreated).Ticks - root.StartedUtcTicks) <= TimeSpan.TicksPerSecond)
          roots[root.ProcessId] = root;
    }
    catch (Exception) { roots.Clear(); }

    var sessionGroups = new Dictionary<int, Group>();
    var programGroups = new Dictionary<string, Group>(StringComparer.OrdinalIgnoreCase);
    foreach (var row in rows)
    {
      Group group;
      var root = SessionRoot(row, roots, parents, created);
      if (root is not null)
      {
        if (!sessionGroups.TryGetValue(root.ProcessId, out var session)) sessionGroups[root.ProcessId] = session = new Group(root.Label, "session");
        group = session;
      }
      else
      {
        var name = row.Exe.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? row.Exe[..^4] : row.Exe;
        if (name.Length == 0) name = "pid " + row.Pid;
        if (programGroups.TryGetValue(name, out var program)) program.Kind = "app";
        else programGroups[name] = program = new Group(name, "process");
        group = program;
      }
      group.Cpu += row.Cpu;
      group.Memory += row.Memory;
      group.Processes++;
    }
    return [.. sessionGroups.Values, .. programGroups.Values];
  }

  // Walks up the parent chain; a parent must be older than its child so a reused pid breaks the chain.
  private static ActivitySessionRoot? SessionRoot(ProcessRow row, Dictionary<int, ActivitySessionRoot> roots, Dictionary<int, int> parents, Dictionary<int, long> created)
  {
    if (roots.Count == 0) return null;
    var current = row.Pid;
    var currentCreated = row.Created;
    for (var hop = 0; hop < 64; hop++)
    {
      if (roots.TryGetValue(current, out var root)) return root;
      if (!parents.TryGetValue(current, out var parent) || parent == 0 || parent == current) return null;
      if (created.TryGetValue(parent, out var parentCreated))
      {
        if (parentCreated > currentCreated) return null;
        currentCreated = parentCreated;
      }
      current = parent;
    }
    return null;
  }

  private static List<(int Pid, int ParentPid, string Exe)> Snapshot()
  {
    var list = new List<(int, int, string)>();
    var snapshot = CreateToolhelp32Snapshot(SnapProcess, 0);
    if (snapshot == IntPtr.Zero || snapshot == new IntPtr(-1)) return list;
    try
    {
      var entry = new ProcessEntry32 { Size = (uint)Marshal.SizeOf<ProcessEntry32>() };
      if (!Process32First(snapshot, ref entry)) return list;
      do
      {
        list.Add(((int)entry.ProcessId, (int)entry.ParentProcessId, entry.ExeFile ?? ""));
        entry.Size = (uint)Marshal.SizeOf<ProcessEntry32>();
      } while (Process32Next(snapshot, ref entry));
    }
    finally { CloseHandle(snapshot); }
    return list;
  }

  private const uint SnapProcess = 0x00000002;
  private const uint ProcessQueryLimitedInformation = 0x1000;

  [StructLayout(LayoutKind.Sequential)]
  private struct MemoryStatusEx
  {
    public uint Length;
    public uint MemoryLoad;
    public ulong TotalPhys;
    public ulong AvailPhys;
    public ulong TotalPageFile;
    public ulong AvailPageFile;
    public ulong TotalVirtual;
    public ulong AvailVirtual;
    public ulong AvailExtendedVirtual;
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct ProcessEntry32
  {
    public uint Size;
    public uint Usage;
    public uint ProcessId;
    public IntPtr DefaultHeapId;
    public uint ModuleId;
    public uint Threads;
    public uint ParentProcessId;
    public int PriorityClassBase;
    public uint Flags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string ExeFile;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct ProcessMemoryCountersEx
  {
    public uint Size;
    public uint PageFaultCount;
    public nuint PeakWorkingSetSize;
    public nuint WorkingSetSize;
    public nuint QuotaPeakPagedPoolUsage;
    public nuint QuotaPagedPoolUsage;
    public nuint QuotaPeakNonPagedPoolUsage;
    public nuint QuotaNonPagedPoolUsage;
    public nuint PagefileUsage;
    public nuint PeakPagefileUsage;
    public nuint PrivateUsage;
  }

  [DllImport("ntdll.dll")] private static extern int NtQuerySystemInformation(int informationClass, IntPtr buffer, int length, out int returned);
  [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx status);
  [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
  [DllImport("kernel32.dll", EntryPoint = "Process32FirstW", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Process32First(IntPtr snapshot, ref ProcessEntry32 entry);
  [DllImport("kernel32.dll", EntryPoint = "Process32NextW", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry32 entry);
  [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, int processId);
  [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
  [DllImport("kernel32.dll", EntryPoint = "K32GetProcessMemoryInfo", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetProcessMemoryInfo(IntPtr process, ref ProcessMemoryCountersEx counters, uint size);
  [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
}
