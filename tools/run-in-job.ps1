# run-in-job.ps1 - run one bash script inside a Windows Job Object, so every
# process it starts (including servers a model leaves running in the
# background) is killed when the script ends - and nothing else is.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-in-job.ps1 -Bash <bash.exe> -Script <file.sh>
#
# How: this PowerShell process joins a new job with
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, then starts bash. Children inherit the
# job, even when they detach from their parent. When this process exits, the
# last handle to the job closes and Windows terminates whatever is still in it.
# A process that was never started from here is never in the job, so it can
# never be killed by it. The exit code is the script's.
param(
  [Parameter(Mandatory = $true)][string]$Bash,
  [Parameter(Mandatory = $true)][string]$Script
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class FactoryJob {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern IntPtr CreateJobObject(IntPtr attributes, string name);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll")]
  static extern IntPtr GetCurrentProcess();

  [StructLayout(LayoutKind.Sequential)]
  struct BasicLimit {
    public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
    public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct IoCounters { public ulong R, W, O, RB, WB, OB; }
  [StructLayout(LayoutKind.Sequential)]
  struct ExtendedLimit {
    public BasicLimit Basic; public IoCounters Io;
    public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
  }

  const uint KILL_ON_JOB_CLOSE = 0x2000;
  const int ExtendedLimitInformation = 9;

  // Kept in a static so the handle lives exactly as long as this process.
  public static IntPtr Job;

  public static void Enter() {
    Job = CreateJobObject(IntPtr.Zero, null);
    if (Job == IntPtr.Zero) throw new Exception("CreateJobObject failed: " + Marshal.GetLastWin32Error());
    var info = new ExtendedLimit();
    info.Basic.LimitFlags = KILL_ON_JOB_CLOSE;
    int size = Marshal.SizeOf(typeof(ExtendedLimit));
    IntPtr ptr = Marshal.AllocHGlobal(size);
    try {
      Marshal.StructureToPtr(info, ptr, false);
      if (!SetInformationJobObject(Job, ExtendedLimitInformation, ptr, (uint)size))
        throw new Exception("SetInformationJobObject failed: " + Marshal.GetLastWin32Error());
    } finally { Marshal.FreeHGlobal(ptr); }
    if (!AssignProcessToJobObject(Job, GetCurrentProcess()))
      throw new Exception("AssignProcessToJobObject failed: " + Marshal.GetLastWin32Error());
  }
}
'@

try {
  [FactoryJob]::Enter()
} catch {
  # Never fall back to killing by name or age: without a job, nothing is reaped.
  [Console]::Error.WriteLine("[run-in-job] WARNING: no job object ($($_.Exception.Message)); leftover processes will not be cleaned up")
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Bash
$psi.Arguments = '"' + $Script + '"'
$psi.UseShellExecute = $false   # inherit stdin/stdout/stderr, so output streams straight through
$child = [System.Diagnostics.Process]::Start($psi)
$child.WaitForExit()
exit $child.ExitCode
