#Requires -Version 5.1
<#
.SYNOPSIS
    Imports the course OVA on a student host and prepares networking.

.DESCRIPTION
    Creates NAT Network 'istio-lab' (10.0.2.0/24, DHCP off) and a
    Host-Only adapter (192.168.56.1/24, DHCP off), imports the OVA,
    reattaches VM NICs to these networks and regenerates MAC addresses.

.EXAMPLE
    pwsh -File scripts\import-stand.ps1 -Ova D:\istio-stand.ova
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Ova,
    [string]$NatNetwork = 'istio-lab',
    [string]$NatCidr = '10.0.2.0/24',
    [string]$HostOnlyIp = '192.168.56.1',
    [string]$VBoxManage = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-VBoxManage {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return $Path }
    $cmd = Get-Command 'VBoxManage' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "VBoxManage not found. Pass -VBoxManage 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'"
}

$script:VBox = Resolve-VBoxManage -Path $VBoxManage
if (-not (Test-Path -LiteralPath $Ova)) { throw "OVA not found: $Ova" }

# NAT Network
$natList = & $script:VBox natnetwork list 2>&1
if ($natList -notmatch [regex]::Escape($NatNetwork)) {
    Write-Host "[info] creating NAT Network $NatNetwork ($NatCidr)"
    & $script:VBox natnetwork add --netname $NatNetwork --network $NatCidr --enable --dhcp off
} else {
    Write-Host "[ ok ] NAT Network $NatNetwork exists"
}

# Host-Only adapter
$hostIfs = & $script:VBox list hostonlyifs 2>&1
if (-not $hostIfs) {
    Write-Host "[info] creating Host-Only adapter"
    & $script:VBox hostonlyif create | Out-Null
    $hostIfs = & $script:VBox list hostonlyifs 2>&1
}
$line = $hostIfs | Where-Object { $_ -match '^Name:\s+(.+)$' } | Select-Object -First 1
if (-not $line) { throw 'No Host-Only adapter found after creation.' }
$adapter = [regex]::Match($line, '^Name:\s+(.+)$').Groups[1].Value.Trim()
Write-Host "[ ok ] Host-Only adapter: $adapter"
& $script:VBox hostonlyif ipconfig $adapter --ip $HostOnlyIp --netmask 255.255.255.0
& $script:VBox dhcpserver modify --ifname $adapter --disable 2>$null

# Import
$before = @(& $script:VBox list vms 2>&1)
Write-Host "[info] importing $Ova ..."
& $script:VBox import $Ova
if ($LASTEXITCODE -ne 0) { throw "VBoxManage import failed with code $LASTEXITCODE" }
$after = @(& $script:VBox list vms 2>&1)

$newNames = @()
foreach ($entry in $after) {
    if ($before -contains $entry) { continue }
    if ($entry -match '^"(.+)"') { $newNames += $Matches[1] }
}

foreach ($vm in $newNames) {
    Write-Host "[info] attaching $vm to $NatNetwork and $adapter"
    & $script:VBox modifyvm $vm --nic1 natnetwork --nat-network1 $NatNetwork
    & $script:VBox modifyvm $vm --nic2 hostonly --hostonlyadapter2 $adapter
    & $script:VBox modifyvm $vm --macaddress1 auto --macaddress2 auto
}

Write-Host ""
Write-Host "[ ok ] imported VMs: $($newNames.Count)"
Write-Host "Start all VMs in VirtualBox, then from the host:"
Write-Host "  ssh engineer@10.0.2.5"
Write-Host "  source ~/istio-course/scripts/env.sh"
Write-Host "  less ~/istio-course/labs/lab-1.1_install.txt"
Write-Host "If Host-Only 192.168.56.0/24 conflicts with your LAN, change the adapter subnet before import."
