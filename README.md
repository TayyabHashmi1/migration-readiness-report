# Migration Readiness Report

A read-only PowerShell tool that inspects Windows servers and scores each one for cloud-migration readiness. It groups servers into migration waves so the first cutover goes to the machines that are easiest to move.

I built it from the planning work involved in moving on-prem VMware servers to Azure and AWS. It is a standalone project and uses fictional data in the sample report.

## What it does

- Queries each server over CIM. It installs nothing and changes nothing.
- Collects OS and version, platform (VMware VM, Hyper-V VM, other VM, or physical), vCPU, RAM, total disk, latest patch date and uptime.
- Scores each server out of 100 and lists the reasons, so the score can be argued with.
- Suggests a wave: Wave 1 ready, Wave 2 remediate first, Wave 3 plan carefully.
- Writes a CSV and a self-contained HTML report.

## Run it

```powershell
# Try it with fictional servers. Touches no real system.
.\Get-MigrationReadiness.ps1 -Demo

# This computer
.\Get-MigrationReadiness.ps1

# A list of servers, with a credential for remote CIM sessions
.\Get-MigrationReadiness.ps1 -ComputerName srv01,srv02 -Credential (Get-Credential) -OutputPath .\report
```

Requires Windows PowerShell 5.1 or later. Remote servers need WinRM reachable from where you run it. The local computer is queried directly and needs no WinRM.

## How the score works

Every server starts at 100.

| Check | Points |
| --- | --- |
| OS past end of extended support | -40 |
| OS support ends within 12 months | -20 |
| OS version not recognized | -10 |
| No patch in 90+ days | -15 |
| Patch date unknown | -10 |
| Physical server (needs P2V first) | -15 |
| Up 180+ days | -5 |
| Over 2 TB of disk | -10 |

Waves: 80 and above is Wave 1, 50 to 79 is Wave 2, below 50 is Wave 3. The size bucket (Small, Medium, Large) is a rough guide from vCPU and RAM, not a VM size recommendation.

## Limits

- The scoring is a first-pass heuristic for wave planning. It does not map application dependencies.
- Confirm sizing and dependencies with Azure Migrate or AWS Application Discovery Service before cutover.
- OS support dates are built in. Verify them against the Microsoft Lifecycle site.
- Windows Server only. Linux hosts are out of scope.

## Files

- `Get-MigrationReadiness.ps1`: the tool
- `sample-report.html`: output from `-Demo`

MIT licensed. Use it and change it.
