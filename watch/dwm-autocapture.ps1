# Automatic evidence capture when dwm has degraded. Called by
# dwm-growth-sample.ps1 when a threshold trips; can also be run by hand.
#
# Needs admin (both the full dump and wpr do). A scheduled task registered at
# RunLevel Highest never raises a UAC prompt, which is what makes silent
# capture possible with the screen off or over a remote session.
#
# Everything lands in <DataDir>\dwm-capture\<timestamp>\
#   dwm-full.dmp   full memory dump -- lets someone actually count the visual tree
#   dwm.etl        30 s sampled profile -- open with wpa.exe (GUI, needs no profile)
#   stacks.txt     cdb symbolized stacks
#   summary.txt    measurements taken at the moment of capture
#
# The point of all this: do NOT restart dwm until capture has finished. A note
# is left on the desktop saying so, because the reflex to restart is exactly
# what destroyed the evidence the first time.
#
# Source is pure ASCII on purpose: PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

param(
  [string]$Reason  = 'manual',
  [string]$DataDir = $PSScriptRoot
)

$ErrorActionPreference = 'Continue'
$root  = Join-Path $DataDir 'dwm-capture'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dir   = Join-Path $root $stamp
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$log = New-Object System.Collections.Generic.List[string]
function L($m){ $log.Add([string]$m); ($log -join "`r`n") | Out-File "$dir\summary.txt" -Encoding utf8 }

$elevated = (New-Object Security.Principal.WindowsPrincipal(
              [Security.Principal.WindowsIdentity]::GetCurrent())
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

L "Captured at : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
L "Reason      : $Reason"
L "Elevated    : $elevated"

$d = Get-CimInstance Win32_Process -Filter "Name='dwm.exe'" | Select-Object -First 1
$dwmPid = [int]$d.ProcessId
L "dwm PID     : $dwmPid   alive $([math]::Round(((Get-Date)-$d.CreationDate).TotalHours,2)) h"
L "Private     : $([math]::Round($d.PrivatePageCount/1MB,0)) MB   Handles: $($d.HandleCount)   Threads: $($d.ThreadCount)"

# Chrome Remote Desktop's Desktop Duplication API render target adds its own
# dirty-region + occlusion pass, measured to exactly double per-frame
# occlusion work (0.55/frame at crd=0 vs 1.10/frame at crd=1). That is a
# constant cost, not something that accumulates -- but without recording
# whether it was active, a capture cannot be told apart from a genuinely
# worse degradation after the fact. See docs/dwm-investigation.md.
$crd = @(Get-Process -Name 'remoting_desktop' -ErrorAction SilentlyContinue)
L "CRD         : $(if($crd.Count){"connected (remoting_desktop.exe x$($crd.Count)) -- occlusion cost is roughly doubled"}else{'none'})"
L ""

if(-not $elevated){
  L "X  Not elevated -- cannot take a full dump and cannot run wpr."
  L "   Run from an Administrator window: powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`""
}

# ---------- 1. full memory dump ----------
if($elevated){
  L "=== Full memory dump ==="
  try {
    Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class DC {
  [DllImport("dbghelp.dll", SetLastError=true)]
  public static extern bool MiniDumpWriteDump(IntPtr hProc, int pid, IntPtr hFile,
      int type, IntPtr ex, IntPtr user, IntPtr cb);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
'@
    $dmp = "$dir\dwm-full.dmp"
    $hp = [DC]::OpenProcess(0x0400 -bor 0x0010, $false, $dwmPid)   # QUERY_INFORMATION | VM_READ
    if($hp -ne [IntPtr]::Zero){
      $fs = [System.IO.File]::Create($dmp)
      # WithFullMemory(0x2) | WithHandleData(0x4) | WithProcessThreadData(0x100) | WithThreadInfo(0x1000)
      $ok = [DC]::MiniDumpWriteDump($hp, $dwmPid, $fs.SafeFileHandle.DangerousGetHandle(),
              (0x2 -bor 0x4 -bor 0x100 -bor 0x1000), [IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero)
      $fs.Close(); [void][DC]::CloseHandle($hp)
      L "  result = $ok   size = $([math]::Round((Get-Item $dmp).Length/1MB,1)) MB"
    } else { L "  OpenProcess failed err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
  } catch { L "  exception: $($_.Exception.Message)" }
  L ""
}

# ---------- 2. cdb symbolized stacks ----------
# Reads the dump file. Deliberately NOT a live attach: cdb -p -pv suspends every
# thread in the target, and doing that to the compositor while symbols download
# is not something to risk.
L "=== cdb symbolized stacks ==="
try {
  $cdb = "$((Get-AppxPackage Microsoft.WinDbg).InstallLocation)\amd64\cdb.exe"
  if(Test-Path $cdb){
    $env:_NT_SYMBOL_PATH = 'srv*C:\symbols*https://msdl.microsoft.com/download/symbols'
    $target = if(Test-Path "$dir\dwm-full.dmp"){ "$dir\dwm-full.dmp" } else { $null }
    if($target){
      & $cdb -z $target -c ".symfix;.reload;~*k 30;q" 2>&1 | Out-File "$dir\stacks.txt" -Encoding utf8
      L "  wrote stacks.txt (from $(Split-Path $target -Leaf))"
      # Lift the compositor frames into the summary so the file is useful alone.
      $sel = Select-String -Path "$dir\stacks.txt" -Pattern 'dwmcore!' -Context 0,6 |
             Select-Object -First 3
      foreach($s in $sel){ L "    $($s.Line.Trim())" }
    } else { L "  no dump to analyse (not elevated)" }
  } else { L "  X  cdb.exe not found" }
} catch { L "  exception: $($_.Exception.Message)" }
L ""

# ---------- 3. wpr sampled profile ----------
if($elevated){
  L "=== wpr, 30 s ==="
  try {
    & wpr.exe -cancel 2>&1 | Out-Null
    # Try to include hardware PMC (InstructionRetired/TotalCycles/LLCMisses,
    # see dwm-pmc.wprp) alongside the usual providers. This is what tells
    # apart "pruning failure" (walk visits more nodes, IPC stays flat) from
    # "iterator slowdown" (same nodes, each one costs more, IPC collapses) --
    # see docs/dwm-investigation.md. Falls back cleanly if PMC cannot be
    # programmed; dwm-pmc-probe.ps1 already confirmed this combination starts
    # on the machine it was verified on, but PMC availability is
    # hardware/hypervisor-dependent and is not assumed here.
    $pmcWprp = Join-Path $PSScriptRoot 'dwm-pmc.wprp'
    $usedPmc = $false
    if(Test-Path $pmcWprp){
      $r = & wpr.exe -start CPU -start DesktopComposition -start GPU -start "$pmcWprp!DwmPmcFull" -filemode 2>&1 | Out-String
      if($LASTEXITCODE -eq 0){ $usedPmc = $true }
      else { L "  PMC combination failed to start, falling back: $($r.Trim())"; & wpr.exe -cancel 2>&1 | Out-Null }
    }
    if(-not $usedPmc){
      $r = & wpr.exe -start CPU -start DesktopComposition -start GPU -filemode 2>&1 | Out-String
    }
    if($LASTEXITCODE -ne 0){
      & wpr.exe -cancel 2>&1 | Out-Null
      $r = & wpr.exe -start CPU -filemode 2>&1 | Out-String
      L "  fell back to CPU only: exit=$LASTEXITCODE"
    }
    L "  PMC: $(if($usedPmc){'included'}else{'not included'})"
    if($LASTEXITCODE -eq 0){
      Start-Sleep 30
      & wpr.exe -stop "$dir\dwm.etl" 2>&1 | Out-Null
      if(Test-Path "$dir\dwm.etl"){
        L "  ETL = $([math]::Round((Get-Item "$dir\dwm.etl").Length/1MB,1)) MB  <- open with wpa.exe"
        if($usedPmc){
          $pv = Join-Path $PSScriptRoot 'dwm-pmc-verify.ps1'
          if(Test-Path $pv){
            try {
              # Route through Write-Output, not Console.WriteLine/Write-Host --
              # both of those bypass the success stream and this capture is
              # pulled through a pipeline (`| Out-String`), not watched
              # interactively. Learned by losing a real capture's IPC numbers
              # to exactly this; see dwm-pmc-verify.ps1's header.
              $vout = & $pv -EtlPath "$dir\dwm.etl" 2>&1 | Out-String
              $sel = ($vout -split "`r?`n") | Where-Object { $_ -match 'IPC|instructions|cycles|lost events|LLC miss' }
              foreach($s in $sel){ L "  $($s.Trim())" }
            } catch { L "  PMC verification exception: $($_.Exception.Message)" }
          }
        }
      }
      else { L "  X  no ETL produced" }
    } else { L "  X  could not start collection: $($r.Trim())" }
  } catch { L "  exception: $($_.Exception.Message)" }
  L ""
}

# ---------- 4. make sure the user cannot miss it ----------
$gotDump = Test-Path "$dir\dwm-full.dmp"
$gotEtl  = Test-Path "$dir\dwm.etl"
$title   = if($gotDump){ 'captured' } else { 'FAILED-manual-capture-needed' }
$note = "$env:USERPROFILE\Desktop\!! DWM degraded - $title !!.txt"
$head  = if($gotDump){ 'DWM has degraded again. Evidence was captured automatically -- it is safe to restart dwm now.' }
         else { "DWM has degraded again, but THE EVIDENCE WAS NOT CAPTURED. Before restarting dwm, capture it by hand:`r`n`r`n  From an Administrator window:`r`n  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"" }
@"
$head

  Triggered : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Reason    : $Reason
  Evidence  : $dir
  Full dump : $(if($gotDump){'yes'}else{'NO'})     ETL: $(if($gotEtl){'yes'}else{'NO'})

Restart command (needs Administrator):
  taskkill /f /im dwm.exe

Stacks:
  $dir\stacks.txt

Sampled profile (this is what shows where the time actually went):
  wpa.exe "$dir\dwm.etl"

Growth curve:
  $(Join-Path $DataDir 'dwm-growth.csv')

Delete this file once you have read it.
"@ | Out-File $note -Encoding utf8
L "Desktop note: $note"
L ""
L "Done $(Get-Date -Format 'HH:mm:ss')"
