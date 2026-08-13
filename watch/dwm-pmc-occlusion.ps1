# Bridges occlusion-specific call-path classification onto PMC/IPC data.
#
# dwm-pmc-verify.ps1's IPC is a whole-thread aggregate: it mixes whatever the
# compositor thread was doing during each context switch (occlusion walk,
# drawing, everything else DWM does on that thread) into one number. This
# script narrows it to occlusion specifically.
#
# HOW: dwm-pmc.wprp already collects CSwitch (with PMC deltas) and
# SampledProfile (with call stacks) in the same session, so both are
# available from a single trace -- no second, differently-sampled export is
# needed, which avoids the cross-export sample-availability mismatch class of
# bug described in dwm-pmc-verify.ps1's header. For each PMC interval
# (a CSwitch delta's [StartTime, StopTime] on the compositor thread), this
# counts how many CPU samples fall inside it and how many of those have a
# leaf stack frame matching the occlusion-walk marker list (the same list
# used elsewhere in this investigation for call-path classification), then
# apportions that interval's instruction/cycle counts between "occlusion" and
# "everything else" by that fraction. Summing across intervals gives an
# occlusion-specific IPC.
#
# KNOWN LIMITATIONS, stated up front rather than discovered later:
#   - Apportioning by sample *count* is itself a sampling proxy -- an
#     interval with zero samples inside it is skipped entirely (its
#     instructions/cycles go to neither bucket). The skipped fraction is
#     printed; do not silently ignore it.
#   - Classification looks only at the leaf frame, same simplification as the
#     rest of this investigation's call-path tooling: a sample mid-way
#     through an occlusion call chain but leaf-deep in something unrelated
#     (e.g. an allocator) is counted as non-occlusion.
#   - Symbol resolution on a multi-GB ETL has historically taken minutes; see
#     README for background-run guidance if this hangs.

param(
    [Parameter(Mandatory = $true)][string]$EtlPath,
    [string]$TraceProcessorLibDir = (Join-Path $PSScriptRoot 'lib'),
    [string]$Tag = 'occlusion'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $EtlPath)) { throw "ETL not found: $EtlPath" }
if (-not (Test-Path $TraceProcessorLibDir)) {
    throw "TraceProcessor library directory not found: $TraceProcessorLibDir`r`n" +
          "See dwm-pmc-verify.ps1 / README for how to obtain it."
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
using Microsoft.Windows.EventTracing.Symbols;

public class PmcOcclusion {
    // Same list used by this investigation's other call-path classifiers.
    // Changing it changes what "occlusion" means across every tool that uses
    // it, so keep it identical rather than tuning it here in isolation.
    static readonly string[] Interest = new[] {
        "WalkSubtree<COcclusionContext", "GetOcclusionInfo", "RequiresExternalLayer",
        "Has3DContent", "GetEffectAlpha", "CleanTrees", "WalkSubtree<CPreComputeContext",
        "WalkSubtree<CDrawingContext"
    };

    class Interval { public long Start, Stop; public ulong Instr, Cycles; }
    class Samp { public long T; public bool Occ; }

    public static string Run(string etl) {
        var sb = new StringBuilder();
        var settings = new TraceProcessorSettings { AllowLostEvents = true, AllowTimeInversion = true };
        using (var trace = TraceProcessor.Create(etl, settings)) {
            var pmcPend = trace.UseProcessorCounters();
            var cpuPend = trace.UseCpuSamplingData();
            var symPend = trace.UseSymbols();
            var meta = trace.UseMetadata();
            trace.Process();

            double durSec = (double)meta.AnalyzerDisplayedDuration.TotalSeconds;
            sb.AppendLine("trace length: " + durSec.ToString("F1") + " s");
            sb.AppendLine("lost events: " + meta.LostEventCount.ToString("N0")
                + "   lost buffers: " + meta.LostBufferCount.ToString("N0"));
            if (meta.LostEventCount > 0)
                sb.AppendLine("  caution: loss present -- the apportioning below may be skewed, IPC itself is comparatively safe");

            IProcessorCounterDataSource pds;
            try { pds = pmcPend.Result; }
            catch (Exception e) { sb.AppendLine("!! no PMC data: " + e.Message); return sb.ToString(); }

            sb.AppendLine("loading symbols (can take several minutes on a large trace)...");
            symPend.Result.LoadSymbolsAsync(SymCachePath.Automatic, SymbolPath.Automatic)
                     .GetAwaiter().GetResult();
            sb.AppendLine("symbols loaded.");
            sb.AppendLine();

            // Find the compositor thread: prefer a thread named "Compositor";
            // fall back to the highest-cycles dwm.exe thread.
            int compTid = 0; string compName = null;
            var byTidCycles = new Dictionary<int, ulong>();
            foreach (var d in pds.ContextSwitchCounterDeltas) {
                var p = d.Process;
                if (p == null || !string.Equals(p.ImageName, "dwm.exe", StringComparison.OrdinalIgnoreCase)) continue;
                if (compTid == 0 && d.Thread != null && d.Thread.Name != null &&
                    d.Thread.Name.IndexOf("Compositor", StringComparison.OrdinalIgnoreCase) >= 0) {
                    compTid = d.ThreadId; compName = d.Thread.Name;
                }
                if (d.CycleCount.HasValue) {
                    ulong c; byTidCycles.TryGetValue(d.ThreadId, out c);
                    byTidCycles[d.ThreadId] = c + d.CycleCount.Value;
                }
            }
            if (compTid == 0) {
                if (byTidCycles.Count == 0) { sb.AppendLine("!! no dwm PMC data at all."); return sb.ToString(); }
                compTid = byTidCycles.OrderByDescending(k => k.Value).First().Key;
                sb.AppendLine("(no thread named Compositor; using highest-cycles tid=" + compTid + ")");
            } else {
                sb.AppendLine("compositor thread tid=" + compTid + " (" + compName + ")");
            }

            var intervals = new List<Interval>();
            foreach (var d in pds.ContextSwitchCounterDeltas) {
                var p = d.Process;
                if (p == null || !string.Equals(p.ImageName, "dwm.exe", StringComparison.OrdinalIgnoreCase)) continue;
                if (d.ThreadId != compTid) continue;
                if (!d.InstructionCount.HasValue || !d.CycleCount.HasValue) continue;
                intervals.Add(new Interval {
                    Start = d.StartTime.Nanoseconds, Stop = d.StopTime.Nanoseconds,
                    Instr = d.InstructionCount.Value, Cycles = d.CycleCount.Value
                });
            }
            intervals.Sort((a, b) => a.Start.CompareTo(b.Start));
            sb.AppendLine("compositor thread PMC intervals: " + intervals.Count.ToString("N0"));

            var samples = new List<Samp>();
            int total = 0, comp = 0, stacked = 0, occCount0 = 0;
            foreach (var s in cpuPend.Result.Samples) {
                total++;
                var p = s.Process;
                if (p == null || !string.Equals(p.ImageName, "dwm.exe", StringComparison.OrdinalIgnoreCase)) continue;
                var th = s.Thread;
                if (th == null || th.Id != compTid) continue;
                comp++;
                var st = s.Stack;
                if (st == null || st.Frames == null || st.Frames.Count == 0) continue;
                stacked++;
                var f = st.Frames;
                // Stack direction is not fixed: check whether frames[0] is a
                // thread-start thunk; the leaf is at the other end if so.
                // Assuming frames[Count-1] is always the leaf silently zeroes
                // out an entire export.
                string s0 = Sym(f[0]);
                bool rootFirst = s0.Contains("RtlUserThreadStart") || s0.Contains("BaseThreadInitThunk");
                int leafIdx = rootFirst ? f.Count - 1 : 0;
                string leaf = Sym(f[leafIdx]);
                bool occ = Interest.Any(k => leaf.Contains(k));
                if (occ) occCount0++;
                samples.Add(new Samp { T = s.Timestamp.Nanoseconds, Occ = occ });
            }
            samples.Sort((a, b) => a.T.CompareTo(b.T));
            sb.AppendLine("compositor thread samples: total=" + total + " comp=" + comp + " stacked=" + stacked
                + " classified occlusion=" + occCount0);
            sb.AppendLine();

            // Both lists are already time-sorted, so a single two-pointer
            // sweep suffices -- no need for an O(n*m) scan.
            int si = 0;
            ulong occInstr = 0, occCycles = 0, nonInstr = 0, nonCycles = 0;
            long emptyIntervals = 0, coveredIntervals = 0;
            foreach (var iv in intervals) {
                while (si < samples.Count && samples[si].T < iv.Start) si++;
                int k = si, occN = 0, totN = 0;
                while (k < samples.Count && samples[k].T <= iv.Stop) {
                    totN++;
                    if (samples[k].Occ) occN++;
                    k++;
                }
                if (totN == 0) { emptyIntervals++; continue; }
                coveredIntervals++;
                double frac = (double)occN / totN;
                occInstr += (ulong)Math.Round(iv.Instr * frac);
                occCycles += (ulong)Math.Round(iv.Cycles * frac);
                nonInstr += (ulong)Math.Round(iv.Instr * (1 - frac));
                nonCycles += (ulong)Math.Round(iv.Cycles * (1 - frac));
            }

            double emptyPct = intervals.Count > 0 ? 100.0 * emptyIntervals / intervals.Count : 0;
            sb.AppendLine("intervals with at least one sample: " + coveredIntervals.ToString("N0")
                + "   intervals with none (skipped, not apportioned): " + emptyIntervals.ToString("N0")
                + " (" + emptyPct.ToString("F1") + "%)");
            sb.AppendLine();

            sb.AppendLine("=== occlusion (leaf frame matches the interest list) ===");
            sb.AppendLine("  instructions: " + occInstr.ToString("N0") + "   cycles: " + occCycles.ToString("N0")
                + "   IPC: " + (occCycles > 0 ? ((double)occInstr / occCycles).ToString("F3") : "n/a"));
            sb.AppendLine("=== non-occlusion (compositor thread's other work) ===");
            sb.AppendLine("  instructions: " + nonInstr.ToString("N0") + "   cycles: " + nonCycles.ToString("N0")
                + "   IPC: " + (nonCycles > 0 ? ((double)nonInstr / nonCycles).ToString("F3") : "n/a"));
            sb.AppendLine();
            ulong allInstr = occInstr + nonInstr, allCycles = occCycles + nonCycles;
            sb.AppendLine("=== combined (cross-check against dwm-pmc-verify.ps1's whole-thread IPC -- confirms apportioning did not drop too much) ===");
            sb.AppendLine("  instructions: " + allInstr.ToString("N0") + "   cycles: " + allCycles.ToString("N0")
                + "   IPC: " + (allCycles > 0 ? ((double)allInstr / allCycles).ToString("F3") : "n/a"));
        }
        return sb.ToString();
    }

    static string Sym(StackFrame fr) {
        var sym = fr.Symbol;
        if (sym == null) return fr.Image == null ? "?" : (fr.Image.FileName + "!?");
        return (sym.Image == null ? "?" : sym.Image.FileName) + "!" + sym.FunctionName;
    }
}
'@

$refs = Get-ChildItem $TraceProcessorLibDir -Filter 'Microsoft.Windows.EventTracing*.dll' |
Select-Object -Expand FullName
Add-Type -TypeDefinition $src -ReferencedAssemblies ($refs +
    @('System.Collections', 'System.Linq', 'System.Runtime', 'System.Console', 'netstandard'))

$header = "ETL: $EtlPath`r`n" + ("size: {0:N1} MB" -f ((Get-Item $EtlPath).Length / 1MB)) + "`r`n"
$body = [PmcOcclusion]::Run($EtlPath)
Write-Output ($header + "`r`n" + $body)
