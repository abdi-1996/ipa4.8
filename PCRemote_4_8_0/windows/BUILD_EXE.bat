@echo off
chcp 65001 >nul
cd /d "%~dp0"

where py >nul 2>nul
if not errorlevel 1 (
  set "PY=py -3"
) else (
  set "PY=python"
)

%PY% -m venv .venv
call .venv\Scripts\activate.bat
python -m pip install --upgrade pip
python -m pip install -r requirements.txt

pyinstaller --noconfirm --clean --onefile --windowed ^
  --collect-all mss ^
  --collect-all pyautogui ^
  --collect-all comtypes ^
  --hidden-import comtypes.client ^
  --hidden-import corel_bridge ^
  --hidden-import pyperclip ^
  --hidden-import psutil ^
  --hidden-import websocket ^
  --name PCRemoteServer ^
  gui.py

echo.
echo Готово: dist\PCRemoteServer.exe
pause
