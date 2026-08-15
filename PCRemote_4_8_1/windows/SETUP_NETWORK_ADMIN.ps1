# PC Remote 4.8.1 - LAN / Tailscale / ZeroTier setup
# Run as Administrator. Safe to run more than once.
$ErrorActionPreference = 'Continue'
$Port = 8765

Write-Host "PC Remote network setup" -ForegroundColor Cyan
Write-Host "Port: $Port"

# Virtual VPN adapters work more predictably as Private profiles.
Get-NetConnectionProfile | Where-Object { $_.InterfaceAlias -match 'ZeroTier|Tailscale' } |
    Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue

$ruleNames = @(
    "PC Remote LAN $Port",
    "PC Remote Tailscale $Port",
    "PC Remote ZeroTier $Port"
)
foreach ($name in $ruleNames) {
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

New-NetFirewallRule -DisplayName "PC Remote LAN $Port" `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
    -RemoteAddress LocalSubnet -Profile Any | Out-Null

New-NetFirewallRule -DisplayName "PC Remote Tailscale $Port" `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
    -RemoteAddress 100.64.0.0/10 -Profile Any | Out-Null

$zt = Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'ZeroTier' -or $_.InterfaceDescription -match 'ZeroTier' }
if ($zt) {
    foreach ($adapter in $zt) {
        New-NetFirewallRule -DisplayName "PC Remote ZeroTier $Port" `
            -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
            -InterfaceAlias $adapter.Name -Profile Any -ErrorAction SilentlyContinue | Out-Null
    }
}

Write-Host "" 
Write-Host "Listening sockets on port $Port:" -ForegroundColor Yellow
Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Format-Table LocalAddress,LocalPort,OwningProcess -AutoSize

Write-Host "" 
Write-Host "ZeroTier / Tailscale adapters:" -ForegroundColor Yellow
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceAlias -match 'ZeroTier|Tailscale' } |
    Format-Table InterfaceAlias,IPAddress,PrefixLength -AutoSize

Write-Host "Done. Start PCRemoteServer.exe and keep it running." -ForegroundColor Green
Read-Host "Press Enter to close"
