$Port = 8765
Write-Host "=== PC Remote network diagnostics ===" -ForegroundColor Cyan
Write-Host "Listening on $Port:" -ForegroundColor Yellow
Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Format-Table -AutoSize
Write-Host "`nAddresses:" -ForegroundColor Yellow
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
  Format-Table InterfaceAlias,IPAddress,PrefixLength -AutoSize
Write-Host "`nFirewall rules:" -ForegroundColor Yellow
Get-NetFirewallRule -DisplayName 'PC Remote*' -ErrorAction SilentlyContinue | Format-Table DisplayName,Enabled,Direction,Action,Profile -AutoSize
