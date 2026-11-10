<#
.SYNOPSIS
    Read-only readiness report for planning VMware-to-Azure/AWS migration waves.

.DESCRIPTION
    Queries Windows servers over CIM (no agents, no changes) and produces a CSV
    and a self-contained HTML report. Each server gets a readiness score, flags
    that explain the score, and a suggested migration wave.

    The scoring is a first-pass heuristic for wave planning. Confirm sizing and
    dependencies with Azure Migrate or AWS Application Discovery Service before
    cutover, and confirm support dates against the Microsoft Lifecycle site.

.PARAMETER ComputerName
    Servers to inspect. Defaults to the local computer.

.PARAMETER OutputPath
    Folder for the report files. Created if missing.

.PARAMETER Credential
    Optional credential for remote CIM sessions.

.PARAMETER Demo
    Generates the report from fictional sample servers. Touches no real system.

.EXAMPLE
    .\Get-MigrationReadiness.ps1 -ComputerName srv01,srv02 -OutputPath .\report

.EXAMPLE
    .\Get-MigrationReadiness.ps1 -Demo
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,
    [string]$OutputPath = (Join-Path (Get-Location) 'MigrationReadiness'),
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$Demo
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$now = Get-Date

# Microsoft extended-support end dates by Windows Server build (verify against the lifecycle site).
function Get-OsSupport {
    param([string]$Version)
    $build = 0
    $parts = $Version.Split('.')
    $major = [int]$parts[0]; $minor = [int]$parts[1]
    if ($parts.Count -ge 3) { $build = [int]$parts[2] }
    if ($major -eq 6 -and $minor -le 1) { return @{ Name = 'Server 2008 / 2008 R2'; End = [datetime]'2020-01-14' } }
    if ($major -eq 6)                   { return @{ Name = 'Server 2012 / 2012 R2'; End = [datetime]'2023-10-10' } }
    if ($build -ge 20348)               { return @{ Name = 'Server 2022 or later';  End = [datetime]'2031-10-14' } }
    if ($build -ge 17763)               { return @{ Name = 'Server 2019';           End = [datetime]'2029-01-09' } }
    if ($build -ge 14393)               { return @{ Name = 'Server 2016';           End = [datetime]'2027-01-12' } }
    return @{ Name = 'Unrecognized'; End = $null }
}

function Get-Platform {
    param([string]$Manufacturer, [string]$Model)
    if ($Model -match 'VMware')                          { return 'VMware VM' }
    if ($Manufacturer -match 'Microsoft' -and $Model -match 'Virtual') { return 'Hyper-V VM' }
    if ($Model -match 'Virtual|KVM|HVM')                 { return 'Other VM' }
    return 'Physical'
}

function New-Result {
    param($Name, $OsCaption, $OsVersion, $Platform, $Cpu, $RamGb, $DiskGb, $LastPatch, $UptimeDays, $Domain)

    $support = Get-OsSupport -Version $OsVersion
    $flags = New-Object System.Collections.Generic.List[string]
    $score = 100

    if ($support.End) {
        $monthsLeft = ($support.End - $now).TotalDays / 30.4
        if ($monthsLeft -lt 0)       { $score -= 40; $flags.Add('OS past end of support') }
        elseif ($monthsLeft -lt 12)  { $score -= 20; $flags.Add('OS support ends within 12 months') }
    } else { $score -= 10; $flags.Add('OS version not recognized') }

    if ($null -eq $LastPatch)               { $score -= 10; $flags.Add('Patch date unknown') }
    elseif (($now - $LastPatch).Days -gt 90) { $score -= 15; $flags.Add('No patch in 90+ days') }

    if ($Platform -eq 'Physical') { $score -= 15; $flags.Add('Physical: needs P2V first') }
    if ($UptimeDays -gt 180)      { $score -= 5;  $flags.Add('Up 180+ days: reboot pending-update risk') }
    if ($DiskGb -gt 2048)         { $score -= 10; $flags.Add('Over 2 TB of disk: plan seeding time') }

    if ($score -lt 0) { $score = 0 }
    if     ($score -ge 80) { $wave = 'Wave 1 - ready' }
    elseif ($score -ge 50) { $wave = 'Wave 2 - remediate first' }
    else                   { $wave = 'Wave 3 - plan carefully' }

    if     ($Cpu -le 2 -and $RamGb -le 8)   { $size = 'Small' }
    elseif ($Cpu -le 8 -and $RamGb -le 32)  { $size = 'Medium' }
    else                                    { $size = 'Large' }

    [pscustomobject]@{
        Server        = $Name
        OS            = $OsCaption
        Platform      = $Platform
        vCPU          = $Cpu
        RamGB         = $RamGb
        DiskGB        = $DiskGb
        SizeBucket    = $size
        LastPatch     = if ($LastPatch) { $LastPatch.ToString('yyyy-MM-dd') } else { 'unknown' }
        UptimeDays    = $UptimeDays
        Domain        = $Domain
        Score         = $score
        Wave          = $wave
        Flags         = ($flags -join '; ')
    }
}

function Get-ServerFacts {
    param([string]$Name)
    $isLocal = @('.', 'localhost', $env:COMPUTERNAME) -contains $Name
    $session = $null
    try {
        # Local machine: query directly, so WinRM is not required. Remote: one CIM session per server.
        $cim = @{}
        if (-not $isLocal) {
            $params = @{ ComputerName = $Name; ErrorAction = 'Stop' }
            if ($Credential) { $params.Credential = $Credential }
            $session = New-CimSession @params
            $cim.CimSession = $session
        }
        $os   = Get-CimInstance @cim -ClassName Win32_OperatingSystem
        $cs   = Get-CimInstance @cim -ClassName Win32_ComputerSystem
        $disk = Get-CimInstance @cim -ClassName Win32_LogicalDisk -Filter 'DriveType=3'
        $fix  = Get-CimInstance @cim -ClassName Win32_QuickFixEngineering -ErrorAction SilentlyContinue |
                Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1

        $diskGb = [math]::Round((($disk | Measure-Object -Property Size -Sum).Sum) / 1GB, 0)
        $ramGb  = [math]::Round($cs.TotalPhysicalMemory / 1GB, 0)
        $uptime = [math]::Floor(($now - $os.LastBootUpTime).TotalDays)
        $patch  = if ($fix) { [datetime]$fix.InstalledOn } else { $null }

        $facts = @{
            Name       = $Name
            OsCaption  = $os.Caption
            OsVersion  = $os.Version
            Platform   = Get-Platform -Manufacturer $cs.Manufacturer -Model $cs.Model
            Cpu        = $cs.NumberOfLogicalProcessors
            RamGb      = $ramGb
            DiskGb     = $diskGb
            LastPatch  = $patch
            UptimeDays = $uptime
            Domain     = $cs.Domain
        }
        New-Result @facts
    }
    catch {
        Write-Warning ("{0}: {1}" -f $Name, $_.Exception.Message)
    }
    finally {
        if ($session) { Remove-CimSession $session }
    }
}

function Get-DemoResults {
    $d = $now.Date
    @(
        New-Result 'app-web-01'  'Windows Server 2019 Standard'   '10.0.17763' 'VMware VM'  4  16  120  $d.AddDays(-21)  34  'corp.example'
        New-Result 'app-web-02'  'Windows Server 2019 Standard'   '10.0.17763' 'VMware VM'  4  16  120  $d.AddDays(-21)  34  'corp.example'
        New-Result 'sql-prod-01' 'Windows Server 2022 Datacenter' '10.0.20348' 'VMware VM'  16 128 1800 $d.AddDays(-12)  58  'corp.example'
        New-Result 'file-01'     'Windows Server 2016 Standard'   '10.0.14393' 'VMware VM'  4  16  3200 $d.AddDays(-75)  140 'corp.example'
        New-Result 'legacy-erp'  'Windows Server 2012 R2 Standard' '6.3.9600'  'Physical'   8  32  600  $d.AddDays(-400) 410 'corp.example'
        New-Result 'print-01'    'Windows Server 2012 R2 Standard' '6.3.9600'  'VMware VM'  2  8   100  $d.AddDays(-250) 220 'corp.example'
        New-Result 'dc-02'       'Windows Server 2019 Standard'   '10.0.17763' 'VMware VM'  2  8   80   $d.AddDays(-9)   17  'corp.example'
        New-Result 'old-intranet' 'Windows Server 2008 R2 Enterprise' '6.1.7601' 'Physical' 2  4  250  $null            900 'corp.example'
    )
}

# ---- run ----
if ($Demo) { $results = Get-DemoResults }
else {
    $results = foreach ($n in $ComputerName) { Get-ServerFacts -Name $n }
}
$results = @($results | Where-Object { $_ })
if ($results.Count -eq 0) { Write-Warning 'No servers returned data.'; return }

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$stamp   = $now.ToString('yyyyMMdd-HHmm')
$csvPath = Join-Path $OutputPath ("readiness-{0}.csv" -f $stamp)
$htmPath = Join-Path $OutputPath ("readiness-{0}.html" -f $stamp)
$results | Sort-Object Score | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

$enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
$w1 = @($results | Where-Object { $_.Wave -like 'Wave 1*' }).Count
$w2 = @($results | Where-Object { $_.Wave -like 'Wave 2*' }).Count
$w3 = @($results | Where-Object { $_.Wave -like 'Wave 3*' }).Count

$rows = foreach ($r in ($results | Sort-Object Score)) {
    $cls = if ($r.Score -ge 80) { 'ok' } elseif ($r.Score -ge 50) { 'warn' } else { 'bad' }
    $cells = @(
        (& $enc $r.Server), (& $enc $r.OS), (& $enc $r.Platform), $r.vCPU, $r.RamGB, $r.DiskGB,
        $r.SizeBucket, $cls, $r.Score, (& $enc $r.Wave), (& $enc $r.Flags)
    )
    $rowTemplate = '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3} vCPU / {4} GB / {5} GB disk ({6})</td><td><span class="pill {7}">{8}</span></td><td>{9}</td><td>{10}</td></tr>'
    $rowTemplate -f $cells
}

$css = @'
body{font-family:Segoe UI,system-ui,sans-serif;margin:32px;color:#14202b;background:#f6f8fa}
h1{margin:0 0 4px}p.sub{color:#5a6b7b;margin:0 0 24px}
.cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:24px}
.card{background:#fff;border:1px solid #d8e0e8;border-radius:10px;padding:14px 18px;min-width:150px}
.card b{display:block;font-size:28px}
table{border-collapse:collapse;width:100%;background:#fff;border:1px solid #d8e0e8}
th,td{padding:9px 12px;border-bottom:1px solid #e6ecf1;text-align:left;font-size:14px;vertical-align:top}
th{background:#eef2f6}
.pill{display:inline-block;min-width:38px;text-align:center;border-radius:999px;padding:2px 10px;font-weight:600;color:#fff}
.ok{background:#1a7f4b}.warn{background:#b8740a}.bad{background:#c0392b}
.note{color:#5a6b7b;font-size:13px;margin-top:16px}
'@

$html = @(
    '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Migration readiness report</title><style>' + $css + '</style></head><body>'
    '<h1>Migration readiness report</h1>'
    ('<p class="sub">Generated {0}{1}. {2} servers.</p>' -f $now.ToString('yyyy-MM-dd HH:mm'), $(if ($Demo) { ' from fictional demo data' } else { '' }), $results.Count)
    ('<div class="cards"><div class="card"><b>{0}</b>Wave 1 - ready</div><div class="card"><b>{1}</b>Wave 2 - remediate first</div><div class="card"><b>{2}</b>Wave 3 - plan carefully</div></div>' -f $w1, $w2, $w3)
    '<table><thead><tr><th>Server</th><th>OS</th><th>Platform</th><th>Size</th><th>Score</th><th>Wave</th><th>Flags</th></tr></thead><tbody>'
    ($rows -join [Environment]::NewLine)
    '</tbody></table>'
    '<p class="note">Scores are a first-pass heuristic. Confirm sizing and dependencies with Azure Migrate or AWS Application Discovery Service, and verify support dates against the Microsoft Lifecycle site.</p>'
    '</body></html>'
) -join [Environment]::NewLine
Set-Content -Path $htmPath -Value $html -Encoding UTF8

$results | Sort-Object Score | Format-Table Server, Platform, Score, Wave -AutoSize
Write-Host "CSV : $csvPath"
Write-Host "HTML: $htmPath"
