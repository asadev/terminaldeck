namespace TerminalDeck.Core.Servers;

public sealed record ServerHealth(double CpuPercent, long MemoryUsed, long MemoryTotal, long DiskUsed, long DiskTotal,
  double Load1, double Load5, double Load15, int Cpus, DateTimeOffset CheckedAt);

public static class ServerHealthRead
{
  public static ServerCommand Command => new("python3 -c " + ServerValidation.Quote(Script));
  private const string Script = """
import os,time,json,shutil
from datetime import datetime,timezone

def cpu():
 with open('/proc/stat') as f: values=[int(v) for v in f.readline().split()[1:9]]
 return sum(values),values[3]+values[4]
a=cpu(); time.sleep(0.2); b=cpu()
cpu_percent=100*(1-(b[1]-a[1])/max(1,b[0]-a[0]))
with open('/proc/meminfo') as f: memory={line.split(':')[0]:int(line.split()[1])*1024 for line in f}
total=memory['MemTotal']; available=memory.get('MemAvailable',memory.get('MemFree',0))
disk=shutil.disk_usage('/'); load=os.getloadavg()
print(json.dumps(dict(cpuPercent=cpu_percent,memoryUsed=total-available,memoryTotal=total,diskUsed=disk.used,diskTotal=disk.total,load1=load[0],load5=load[1],load15=load[2],cpus=os.cpu_count() or 1,checkedAt=datetime.now(timezone.utc).isoformat())))
""";
}
