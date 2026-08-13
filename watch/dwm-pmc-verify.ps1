# Reads an ETL captured with dwm-pmc.wprp and reports instructions / cycles /
# IPC per dwm.exe thread. Does not need elevation -- only capturing does.
#
# THE PRIMARY DISCRIMINATOR IS IPC, NOT INSTRUCTIONS-PER-FRAME.
#   Pruning failure  (the walk visits more nodes) -> IPC stays roughly flat
#   Iterator slowdown (same nodes, each one costs more, stalling on memory)
#     -> IPC collapses
#
# Why not instructions-per-frame: that ratio's numerator would be a CSwitch
# delta (a complete count) and its denominator a PreRender leaf-sample count
# from a separate profile export (a sampling proxy) -- two different
# availability bases. That mismatch is the same failure mode documented in
# this repo's "short-window transient" lessons wearing a different coat: a
# ratio's scale drifts with trace length and event loss whenever numerator
# and denominator are not drawn from the same source. IPC's numerator and
# denominator both come from the same CSwitch deltas, the same thread, the
# same trace -- no cross-export division, immune to that failure mode.
# Instructions-per-frame is corroborating evidence at most, never the
# primary claim.
#
# MUST check lost-event count before trusting the numbers. CSwitch volume is
# far larger than SampledProfile, and traces already need AllowLostEvents.
# Lost CSwitch events silently subtract from the instruction count -- and the
# busier trace (the degraded one) loses more of them. That bias runs exactly
# the wrong way: it manufactures "instruction count did not rise", which
# would falsely support "iterator slowdown". This is the one bias direction
# that can produce a wrong confirmation, which is why it is printed first.

param(
    [Parameter(Mandatory = $true)][string]$EtlPath,
    [string]$TraceProcessorLibDir = (Join-Path $PSScriptRoot 'lib'),
    [string]$Tag = 'probe'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $EtlPath)) { throw "ETL not found: $EtlPath" }
if (-not (Test-Path $TraceProcessorLibDir)) {
    throw "TraceProcessor library directory not found: $TraceProcessorLibDir`r`n" +
          "Get it from the Microsoft.Windows.EventTracing.Processing.All NuGet " +
          "package (lib\netstandard2.0\*.dll) and point -TraceProcessorLibDir at " +
          "it, or drop the DLLs in a 'lib' folder next to this script. See README."
}

Get-ChildItem $TraceProcessorLibDir -Filter *.dll | ForEach-Object {
    try { [void][System.Reflection.Assembly]::LoadFrom($_.FullName) } catch { }
}

$src = @'
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Microsoft.Windows.EventTracing;
using Microsoft.Windows.EventTracing.Cpu;

public class PmcCheck {
    class Acc {
        public string Name; public int Tid;
        public ulong Instr, Cycles; public double CpuMs; public long N;
        public Dictionary<string, ulong> Raw = new Dictionary<string, ulong>();
    }

    // Returns a string instead of writing directly, so the caller gets the
    // same content whether it is run interactively, captured through a
    // pipeline, or redirected to a file. See README for why that distinction
    // matters here: Console.WriteLine / Write-Host both bypass PowerShell's
    // success output stream, which looks fine interactively and silently
    // drops the payload the moment a caller pipes or redirects it.
    public static string Run(string etl) {
        var sb = new StringBuilder();
        var s = new TraceProcessorSettings { AllowLostEvents = true, AllowTimeInversion = true };
        using (var trace = TraceProcessor.Create(etl, s)) {
            var pend = trace.UseProcessorCounters();
            var meta = trace.UseMetadata();
            trace.Process();

            double durSec = (double)meta.AnalyzerDisplayedDuration.TotalSeconds;
            sb.AppendLine("trace length: " + durSec.ToString("F1") + " s");

            // Lost events must be checked first -- see file header for why the
            // bias runs the wrong way for this comparison.
            sb.AppendLine("lost events: " + meta.LostEventCount.ToString("N0")
                              + "   lost buffers: " + meta.LostBufferCount.ToString("N0"));
            if (meta.LostEventCount > 0)
                sb.AppendLine("  caution: loss present -- discount instructions/frame, IPC is comparatively safe");

            IProcessorCounterDataSource ds;
            try { ds = pend.Result; }
            catch (Exception e) {
                sb.AppendLine("!! could not get the processor-counter data source: " + e.Message);
                sb.AppendLine("!! this ETL has no PMC data.");
                return sb.ToString();
            }

            sb.AppendLine("counters: " + string.Join(", ", ds.CounterNames));
            sb.AppendLine("HasInstructionCount=" + ds.HasInstructionCount
                              + "  HasCycleCount=" + ds.HasCycleCount);
            var deltas = ds.ContextSwitchCounterDeltas;
            sb.AppendLine("context-switch delta rows: " + deltas.Count.ToString("N0"));
            if (deltas.Count == 0) {
                sb.AppendLine("!! no deltas at all -- PMC was not received.");
                return sb.ToString();
            }

            var byThread = new Dictionary<int, Acc>();
            long dwmRows = 0;
            foreach (var d in deltas) {
                var p = d.Process;
                if (p == null || !string.Equals(p.ImageName, "dwm.exe",
                        StringComparison.OrdinalIgnoreCase)) continue;
                dwmRows++;
                Acc a;
                if (!byThread.TryGetValue(d.ThreadId, out a)) {
                    a = new Acc { Tid = d.ThreadId, Name = d.Thread != null ? d.Thread.Name : null };
                    byThread[d.ThreadId] = a;
                }
                if (a.Name == null && d.Thread != null) a.Name = d.Thread.Name;
                a.N++;
                if (d.InstructionCount.HasValue) a.Instr += d.InstructionCount.Value;
                if (d.CycleCount.HasValue) a.Cycles += d.CycleCount.Value;
                a.CpuMs += (double)(d.StopTime.RelativeTimestamp - d.StartTime.RelativeTimestamp).TotalMilliseconds;
                if (d.RawCounterDeltas != null)
                    foreach (var kv in d.RawCounterDeltas) {
                        ulong cur; a.Raw.TryGetValue(kv.Key, out cur);
                        a.Raw[kv.Key] = cur + kv.Value;
                    }
            }
            sb.AppendLine("of which dwm.exe: " + dwmRows.ToString("N0"));
            sb.AppendLine();

            if (dwmRows == 0) { sb.AppendLine("!! no dwm context switches in this trace."); return sb.ToString(); }

            sb.AppendLine(string.Format("{0,-34}{1,8}{2,10}{3,16}{4,16}{5,7}",
                "thread", "tid", "CPU ms", "instructions", "cycles", "IPC"));
            foreach (var a in byThread.Values.OrderByDescending(x => x.Cycles).Take(12)) {
                double ipc = a.Cycles > 0 ? (double)a.Instr / a.Cycles : 0;
                sb.AppendLine(string.Format("{0,-34}{1,8}{2,10:F1}{3,16:N0}{4,16:N0}{5,7:F2}",
                    (a.Name ?? "(unnamed)").PadRight(34).Substring(0, 34), a.Tid, a.CpuMs, a.Instr, a.Cycles, ipc));
            }
            sb.AppendLine();

            // Pull the compositor thread out on its own -- this is the row a
            // healthy-vs-degraded comparison is actually about.
            var comp = byThread.Values.FirstOrDefault(
                x => x.Name != null && x.Name.IndexOf("Compositor", StringComparison.OrdinalIgnoreCase) >= 0);
            if (comp == null) {
                sb.AppendLine("(no thread named Compositor; falling back to the highest-cycles row above)");
                comp = byThread.Values.OrderByDescending(x => x.Cycles).First();
                sb.AppendLine("using tid=" + comp.Tid + " instead");
            }
            sb.AppendLine("=== compositor thread ===");
            sb.AppendLine("  tid          : " + comp.Tid + "  (" + (comp.Name ?? "unnamed") + ")");
            sb.AppendLine("  switches     : " + comp.N.ToString("N0"));
            sb.AppendLine("  CPU time     : " + comp.CpuMs.ToString("F1") + " ms  ("
                + (100 * comp.CpuMs / 1000.0 / durSec).ToString("F1") + "% of one core)");
            sb.AppendLine("  instructions : " + comp.Instr.ToString("N0"));
            sb.AppendLine("  cycles       : " + comp.Cycles.ToString("N0"));
            sb.AppendLine("  IPC          : " + (comp.Cycles > 0 ? ((double)comp.Instr / comp.Cycles).ToString("F3") : "n/a"));
            foreach (var kv in comp.Raw.OrderBy(k => k.Key))
                sb.AppendLine("  raw " + kv.Key.PadRight(26) + " : " + kv.Value.ToString("N0"));
            if (comp.Raw.ContainsKey("LLCMisses") && comp.Instr > 0)
                sb.AppendLine("  LLC misses / 1000 instr : "
                    + (1000.0 * comp.Raw["LLCMisses"] / comp.Instr).ToString("F3"));
        }
        return sb.ToString();
    }
}
'@

$refs = Get-ChildItem $TraceProcessorLibDir -Filter 'Microsoft.Windows.EventTracing*.dll' |
Select-Object -Expand FullName
Add-Type -TypeDefinition $src -ReferencedAssemblies ($refs +
    @('System.Collections', 'System.Linq', 'System.Runtime', 'System.Console', 'netstandard'))

$header = "ETL: $EtlPath`r`n" + ("size: {0:N1} MB" -f ((Get-Item $EtlPath).Length / 1MB)) + "`r`n"
$body = [PmcCheck]::Run($EtlPath)
Write-Output ($header + "`r`n" + $body)
