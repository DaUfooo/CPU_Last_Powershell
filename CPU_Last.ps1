<#
.SYNOPSIS
  DaUfooo´s Live-CPU-Überwachung nach Prozessname mit CSV-Logging.

.PARAMETER ProcessName
  Array von Prozessnamen (ohne .exe). Wenn leer, zeigt Top-Prozesse.

.PARAMETER Interval
  Abtastintervall in Sekunden (Standard 1).

.PARAMETER Samples
  Anzahl Samples; 0 = unbegrenzt (bis Strg+C).

.PARAMETER CsvPath
  Pfad zur CSV-Datei. Falls die Datei nicht existiert, wird sie neu angelegt.
#>

param(
    [string[]] $ProcessName = @(),
    [int] $Interval = 1,
    [int] $Samples = 0,
    [int] $Top = 20,
    [string] $CsvPath = ".\CpuLog_Process.csv"
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
                $map[$name] = @{ Cpu = 0.0; Pids = @(); MemMB = 0.0 }
            }
            $map[$name].Cpu   += $cpu
            $map[$name].Pids  += $_.Id
            $map[$name].MemMB += $wsMB
        } catch {}
    }
    return $map
}

$prev = Read-ProcessSnapshot
$sampleCount = 0

# CSV-Datei initialisieren (falls neu)
if (-not (Test-Path $CsvPath)) {
    "Timestamp,ProcessName,CPUPercent,DeltaCpuSec,PidCount,MemMB" | Out-File -FilePath $CsvPath -Encoding UTF8
}

while ($true) {
    if ($Samples -ne 0 -and $sampleCount -ge $Samples) { break }
    Start-Sleep -Seconds $Interval
    $now = Get-Date
    $curr = Read-ProcessSnapshot

    $results = @()
    $names = ($prev.Keys + $curr.Keys) | Sort-Object -Unique
    foreach ($n in $names) {
        $prevCpu = if ($prev.ContainsKey($n)) { $prev[$n].Cpu } else { 0.0 }
        $currCpu = if ($curr.ContainsKey($n)) { $curr[$n].Cpu } else { 0.0 }
        $deltaCpu = $currCpu - $prevCpu
        if ($deltaCpu -lt 0) { $deltaCpu = 0 }

        $cpuPercent = if ($Interval -gt 0) { ($deltaCpu / $Interval) * 100.0 / $cpuCount } else { 0 }
        $pidCount = if ($curr.ContainsKey($n)) { ($curr[$n].Pids | Select-Object -Unique).Count } else { 0 }
        $memMB = if ($curr.ContainsKey($n)) { [math]::Round($curr[$n].MemMB,2) } else { 0.0 }

        $obj = [PSCustomObject]@{
            Timestamp   = $now
            ProcessName = $n
            CPUPercent  = [math]::Round($cpuPercent,2)
            DeltaCpuSec = [math]::Round($deltaCpu,3)
            PidCount    = $pidCount
            MemMB       = $memMB
        }
        $results += $obj
    }

    if ($ProcessName -and $ProcessName.Count -gt 0) {
        $filterLower = $ProcessName | ForEach-Object { $_.ToLower() }
        $results = $results | Where-Object { $filterLower -contains $_.ProcessName.ToLower() }
    }

    $display = $results | Sort-Object -Property CPUPercent -Descending
    if ($Top -gt 0) { $display = $display | Select-Object -First $Top }

    Clear-Host
    Write-Host "DaUfooo´s Prozess-CPU-Überwachung (Sample $($sampleCount+1)) - Intervall ${Interval}s - CPUs: $cpuCount" -ForegroundColor Cyan
    $display | Format-Table @{Label="Time";Expression={$_.Timestamp.ToString("HH:mm:ss")};Width=8},
                          ProcessName,
                          CPUPercent,
                          DeltaCpuSec,
                          PidCount,
                          MemMB -AutoSize

    # ---- CSV Logging ----
    $results | ForEach-Object {
        "$($_.Timestamp),$($_.ProcessName),$($_.CPUPercent),$($_.DeltaCpuSec),$($_.PidCount),$($_.MemMB)" |
          Out-File -FilePath $CsvPath -Append -Encoding UTF8
    }

    $prev = $curr
    $sampleCount++
}
