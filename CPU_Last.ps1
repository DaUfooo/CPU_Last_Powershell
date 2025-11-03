<#
.SYNOPSIS
    DaUfooo´s Live-CPU Überwachung mit nur GPU Gesamtauslastung und CSV-Logging.
#>

param(
    [string[]] $ProcessName = @(),
    [int] $Interval = 1,
    [int] $Samples = 0,
    [int] $Top = 20,
    [string] $CsvPath = ".\CpuGpuLog_Process.csv"
)

$cpuCount = [Environment]::ProcessorCount

function Read-ProcessSnapshot {
    $map = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $name = $_.ProcessName
            $cpu = if ($_.CPU) { [double]$_.CPU } else { 0.0 }
            $wsMB = [math]::Round($_.WorkingSet64 / 1MB, 2)
            if (-not $map.ContainsKey($name)) {
                $map[$name] = @{ Cpu = 0.0; Pids = @(); MemMB = 0.0; PrevCpuPercent=0.0 }
            }
            $map[$name].Cpu += $cpu
            $map[$name].Pids += $_.Id
            $map[$name].MemMB += $wsMB
        } catch {}
    }
    return $map
}

# CSV-Datei initialisieren
if (-not (Test-Path $CsvPath)) {
    "Timestamp,ProcessName,CPUPercent,DeltaCpuSec,PidCount,MemMB,GPUPercentTotal" | Out-File -FilePath $CsvPath -Encoding UTF8
}

$prev = Read-ProcessSnapshot
$sampleCount = 0
$prevGpuTotal = 0

# Hauptschleife
while ($true) {
    try {
        if ($Samples -ne 0 -and $sampleCount -ge $Samples) { break }
        Start-Sleep -Seconds $Interval
        $now = Get-Date
        $curr = Read-ProcessSnapshot

        # GPU Gesamtauslastung ermitteln
        $gpuTotal = 0.0

        # GPU-Auslastung mit Performance-Counter abfragen
        $gpuCounters = Get-Counter '\GPU Engine(*)\Utilization Percentage' | Select-Object -ExpandProperty CounterSamples

        if ($gpuCounters) {
            $gpuTotal = ($gpuCounters | Measure-Object -Property CookedValue -Maximum).Maximum
        }

        $results = New-Object System.Collections.Generic.List[PSObject]
        $names = ($prev.Keys + $curr.Keys) | Sort-Object -Unique

        foreach ($n in $names) {
            $prevCpu = if ($prev.ContainsKey($n)) { $prev[$n].Cpu } else { 0.0 }
            $currCpu = if ($curr.ContainsKey($n)) { $curr[$n].Cpu } else { 0.0 }
            $deltaCpu = [math]::Max(0, $currCpu - $prevCpu)

            $pidList = if ($curr.ContainsKey($n)) { ($curr[$n].Pids | Select-Object -Unique) } else { @() }
            $memMB = if ($curr.ContainsKey($n)) { [math]::Round($curr[$n].MemMB,2) } else { 0.0 }

            $cpuPercent = if ($Interval -gt 0) { ($deltaCpu / $Interval) * 100.0 / $cpuCount } else { 0 }

            # Trendindikator CPU
            $cpuTrend = " "
            if ($prev.ContainsKey($n)) {
                if ($cpuPercent -gt $prev[$n].PrevCpuPercent) { $cpuTrend = "▲" }
                elseif ($cpuPercent -lt $prev[$n].PrevCpuPercent) { $cpuTrend = "▼" }
            }

            $obj = [PSCustomObject]@{
                Timestamp         = $now
                ProcessName       = $n
                CPUPercent        = [math]::Round($cpuPercent,2)
                DeltaCpuSec       = [math]::Round($deltaCpu,3)
                PidCount          = $pidList.Count
                MemMB             = $memMB
                GPUPercentTotal   = [math]::Round($gpuTotal,2)
                CPUTrend          = $cpuTrend
            }
            $results.Add($obj)
        }

        # Filter nach Prozessnamen (optional)
        if ($ProcessName -and $ProcessName.Count -gt 0) {
            $pattern = ($ProcessName | ForEach-Object { [regex]::Escape($_) }) -join '|'
            $results = $results | Where-Object { $_.ProcessName -match $pattern }
        }

        # Sortieren und Top-N auswählen
        $display = $results | Sort-Object -Property CPUPercent -Descending
        if ($Top -gt 0) { $display = $display | Select-Object -First $Top }

        # Anzeige
        Clear-Host
        Write-Host "DaUfooo´s CPU/GPU Überwachung (Sample $($sampleCount+1)) - Intervall ${Interval}s - CPUs: $cpuCount" -ForegroundColor Cyan

        # Symbol je nach Delta-CPU
        foreach ($proc in $display) {
            $deltaSymbol = " "
            if ($proc.DeltaCpuSec -gt 0) {
                if ($proc.CPUPercent -ge 50) { $deltaSymbol = " ⚡ " }
                elseif ($proc.CPUTrend -eq "▲") { $deltaSymbol = " ▲ " }
                elseif ($proc.CPUTrend -eq "▼") { $deltaSymbol = " ▼ " }
            }

            # Farbcode nach CPUPercent
            $color = switch ($proc.CPUPercent) {
                {$_ -ge 50} { "Red"; break }
                {$_ -ge 20} { "Yellow"; break }
                default { "Green" }
            }

            Write-Host ("{0} {1,-25} CPU: {2,4}%{3} | CPU: {4,6}s | PIDs: {5,3} | Mem: {6,6}MB" -f 
                $proc.Timestamp.ToString("HH:mm:ss"),
                $proc.ProcessName,
                [math]::Round($proc.CPUPercent,2),
                $deltaSymbol,
                [math]::Round($proc.DeltaCpuSec,3),
                $proc.PidCount,
                $proc.MemMB) -ForegroundColor $color
        }

        # GPU Gesamtauslastung am Ende
        Write-Host ("GPU Gesamtauslastung: {0}%" -f [math]::Round($gpuTotal,2)) -ForegroundColor Magenta

        # CSV Logging
        $results | Select-Object Timestamp,ProcessName,CPUPercent,DeltaCpuSec,PidCount,MemMB,GPUPercentTotal |
                   Export-Csv -Path $CsvPath -Append -NoTypeInformation

        # Prev CPU Update für Trend
        foreach ($proc in $results) {
            if ($prev.ContainsKey($proc.ProcessName)) {
                $prev[$proc.ProcessName].PrevCpuPercent = $proc.CPUPercent
            }
        }

        $prev = $curr
        $prevGpuTotal = $gpuTotal
        $sampleCount++
    } catch [System.Exception] {
        Write-Host "Fehler oder Abbruch: $($_.Exception.Message)" -ForegroundColor Red
        break
    }
}
