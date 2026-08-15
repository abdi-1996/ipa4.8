@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$startup=[Environment]::GetFolderPath('Startup');" ^
  "$link=Join-Path $startup 'PC Remote Server.lnk';" ^
  "$target=(Resolve-Path '.\RUN.bat').Path;" ^
  "$ws=New-Object -ComObject WScript.Shell;" ^
  "$s=$ws.CreateShortcut($link);" ^
  "$s.TargetPath=$target;" ^
  "$s.WorkingDirectory=(Get-Location).Path;" ^
  "$s.WindowStyle=7;" ^
  "$s.Save();" ^
  "Write-Host 'Автозапуск включён:' $link"
pause
