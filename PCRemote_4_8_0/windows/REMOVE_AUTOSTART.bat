@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$link=Join-Path ([Environment]::GetFolderPath('Startup')) 'PC Remote Server.lnk';" ^
  "if(Test-Path $link){Remove-Item $link -Force};" ^
  "Write-Host 'Автозапуск выключен'"
pause
