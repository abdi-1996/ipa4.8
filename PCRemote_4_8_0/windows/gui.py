import os
import subprocess
import sys
import threading
import tempfile
import tkinter as tk
from pathlib import Path
import server

server_thread = None


def copy(text):
    root.clipboard_clear()
    root.clipboard_append(text)
    root.update()


def refresh_labels():
    ip_value.config(text=server.get_local_ip())
    tail_ip, tail_dns, tail_online = server._tailscale_identity()
    tail_text = tail_ip or tail_dns or "не подключён"
    if tail_online and tail_text != "не подключён":
        tail_text += "  ✓"
    tailscale_value.config(text=tail_text)
    zero_ip, zero_online = server._zerotier_identity()
    zero_text = zero_ip or "не подключён"
    if zero_online and zero_text != "не подключён":
        zero_text += "  ✓"
    zerotier_value.config(text=zero_text)
    port_value.config(text=str(server.CONFIG["port"]))
    password_state.config(
        text="Пароль задан ✓" if server.password_is_set() else "Пароль ещё не задан",
        fg="#16803c" if server.password_is_set() else "#b15a00",
    )


def save_password():
    value = password_entry.get()
    confirm = password_confirm_entry.get()
    if value != confirm:
        password_message.config(text="Пароли не совпадают", fg="#b3261e")
        return
    try:
        server.set_connection_password(value)
    except Exception as exc:
        password_message.config(text=str(exc), fg="#b3261e")
        return
    password_entry.delete(0, "end")
    password_confirm_entry.delete(0, "end")
    password_message.config(text="Пароль сохранён. Старые сессии отключены.", fg="#16803c")
    refresh_labels()


def startup_link_path():
    appdata = os.environ.get("APPDATA", "")
    return Path(appdata) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup" / "PC Remote Server.lnk"


def autostart_target():
    if getattr(sys, "frozen", False):
        return Path(sys.executable)
    return Path(__file__).resolve().parent / "RUN.bat"


def refresh_autostart():
    enabled = startup_link_path().exists()
    autostart_var.set("Автозапуск: включён" if enabled else "Автозапуск: выключен")
    autostart_btn.config(text="Выключить автозапуск" if enabled else "Включить автозапуск")


def toggle_autostart():
    link = startup_link_path()
    try:
        if link.exists():
            link.unlink()
        else:
            target = autostart_target()
            link.parent.mkdir(parents=True, exist_ok=True)
            ps = (
                '$ws = New-Object -ComObject WScript.Shell; '
                + f'$s = $ws.CreateShortcut("{str(link).replace(chr(34), chr(39))}"); '
                + f'$s.TargetPath = "{str(target).replace(chr(34), chr(39))}"; '
                + f'$s.WorkingDirectory = "{str(target.parent).replace(chr(34), chr(39))}"; '
                + '$s.WindowStyle = 7; $s.Save()'
            )
            subprocess.run(
                ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps],
                check=True,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
    except Exception as exc:
        autostart_var.set(f"Ошибка автозапуска: {exc}")
        return
    refresh_autostart()


def configure_network():
    """Open an elevated PowerShell helper for LAN, Tailscale and ZeroTier."""
    port = int(server.CONFIG.get("port", 8765))
    script = f"""$ErrorActionPreference = 'Continue' 
Get-NetConnectionProfile | Where-Object {{ $_.InterfaceAlias -match 'ZeroTier|Tailscale' }} | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
$names = @('PC Remote LAN {port}', 'PC Remote Tailscale {port}', 'PC Remote ZeroTier {port}')
foreach ($n in $names) {{ Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue }}
New-NetFirewallRule -DisplayName 'PC Remote LAN {port}' -Direction Inbound -Action Allow -Protocol TCP -LocalPort {port} -RemoteAddress LocalSubnet -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'PC Remote Tailscale {port}' -Direction Inbound -Action Allow -Protocol TCP -LocalPort {port} -RemoteAddress 100.64.0.0/10 -Profile Any | Out-Null
$zt = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {{ $_.Name -match 'ZeroTier' -or $_.InterfaceDescription -match 'ZeroTier' }}
if ($zt) {{
  foreach ($a in $zt) {{
    New-NetFirewallRule -DisplayName 'PC Remote ZeroTier {port}' -Direction Inbound -Action Allow -Protocol TCP -LocalPort {port} -InterfaceAlias $a.Name -Profile Any -ErrorAction SilentlyContinue | Out-Null
  }}
}}
Write-Host 'PC Remote network configuration completed.'
Write-Host 'Allowed TCP port {port} for LAN, Tailscale and ZeroTier.'
Read-Host 'Press Enter to close'
"""
    try:
        ps1 = Path(tempfile.gettempdir()) / "PCRemote_Network_Setup.ps1"
        ps1.write_text(script, encoding="utf-8-sig")
        arg = f'-NoProfile -ExecutionPolicy Bypass -File "{ps1}"'
        command = f"Start-Process powershell.exe -Verb RunAs -ArgumentList '{arg}'"
        subprocess.Popen(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command], creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        network_message.config(text="Подтвердите запрос администратора Windows. После настройки нажмите «Обновить адреса».", fg="#2450a6")
    except Exception as exc:
        network_message.config(text=f"Не удалось открыть настройку сети: {exc}", fg="#b3261e")

def start():
    global server_thread
    if server_thread and server_thread.is_alive():
        return
    server_thread = threading.Thread(target=server.run_server, daemon=True)
    server_thread.start()
    status_var.set("Сервер запущен")
    start_btn.config(state="disabled")


root = tk.Tk()
root.title("PC Remote Server 4.8.0")
root.geometry("660x690")
root.resizable(False, False)
root.configure(bg="#eef5ff")

card = tk.Frame(root, bg="white", highlightthickness=1, highlightbackground="#d5e5ff")
card.place(x=22, y=18, width=616, height=654)

tk.Label(card, text="PC Remote Server", bg="white", fg="#173569", font=("Segoe UI", 22, "bold")).pack(pady=(18, 3))
tk.Label(card, text="Задайте свой пароль — на iPhone для входа нужен только он.", bg="white", fg="#617493", font=("Segoe UI", 10)).pack()

info = tk.Frame(card, bg="white")
info.pack(fill="x", padx=30, pady=(16, 8))
for row, label in enumerate(("LAN", "Порт", "Tailscale", "ZeroTier")):
    tk.Label(info, text=label, bg="white", fg="#31445f", font=("Segoe UI", 10, "bold")).grid(row=row, column=0, sticky="w", pady=5)
ip_value = tk.Label(info, text="", bg="white", fg="#31445f", font=("Consolas", 11))
ip_value.grid(row=0, column=1, sticky="w", padx=18)
port_value = tk.Label(info, text="", bg="white", fg="#31445f", font=("Consolas", 11))
port_value.grid(row=1, column=1, sticky="w", padx=18)
tailscale_value = tk.Label(info, text="", bg="white", fg="#31445f", font=("Consolas", 11))
tailscale_value.grid(row=2, column=1, sticky="w", padx=18)
zerotier_value = tk.Label(info, text="", bg="white", fg="#31445f", font=("Consolas", 11))
zerotier_value.grid(row=3, column=1, sticky="w", padx=18)

password_card = tk.Frame(card, bg="#f4f8ff", highlightthickness=1, highlightbackground="#c8dbff")
password_card.pack(fill="x", padx=30, pady=(8, 8))

tk.Label(password_card, text="Пароль подключения", bg="#f4f8ff", fg="#173569", font=("Segoe UI", 11, "bold")).grid(row=0, column=0, sticky="w", padx=14, pady=(12, 4))
password_state = tk.Label(password_card, text="", bg="#f4f8ff", fg="#617493", font=("Segoe UI", 9, "bold"))
password_state.grid(row=0, column=1, sticky="e", padx=14, pady=(12, 4))

tk.Label(password_card, text="Новый пароль", bg="#f4f8ff", fg="#516780", font=("Segoe UI", 9)).grid(row=1, column=0, sticky="w", padx=14, pady=4)
password_entry = tk.Entry(password_card, show="•", width=30, font=("Segoe UI", 11))
password_entry.grid(row=1, column=1, sticky="ew", padx=14, pady=4)

tk.Label(password_card, text="Повторите", bg="#f4f8ff", fg="#516780", font=("Segoe UI", 9)).grid(row=2, column=0, sticky="w", padx=14, pady=4)
password_confirm_entry = tk.Entry(password_card, show="•", width=30, font=("Segoe UI", 11))
password_confirm_entry.grid(row=2, column=1, sticky="ew", padx=14, pady=4)

save_password_btn = tk.Button(password_card, text="Сохранить пароль", command=save_password, font=("Segoe UI", 10, "bold"))
save_password_btn.grid(row=3, column=1, sticky="e", padx=14, pady=(6, 8))
password_message = tk.Label(password_card, text="", bg="#f4f8ff", fg="#617493", font=("Segoe UI", 9), wraplength=500, justify="left")
password_message.grid(row=4, column=0, columnspan=2, sticky="w", padx=14, pady=(0, 10))
password_card.columnconfigure(1, weight=1)

buttons = tk.Frame(card, bg="white")
buttons.pack(pady=(8, 8))
start_btn = tk.Button(buttons, text="Запустить сервер", width=20, font=("Segoe UI", 10, "bold"), command=start)
start_btn.grid(row=0, column=0, padx=7)
tk.Button(buttons, text="Обновить адреса", width=20, command=refresh_labels).grid(row=0, column=1, padx=7)

network_frame = tk.Frame(card, bg="white")
network_frame.pack(pady=(2, 6))
tk.Button(network_frame, text="Настроить LAN / Tailscale / ZeroTier", width=36, command=configure_network).pack()
network_message = tk.Label(card, text="", bg="white", fg="#617493", font=("Segoe UI", 9), wraplength=540, justify="center")
network_message.pack(pady=(0, 5))

status_var = tk.StringVar(value="Сервер ещё не запущен")
tk.Label(card, textvariable=status_var, bg="white", fg="#2450a6", font=("Segoe UI", 10, "bold")).pack()

auto_frame = tk.Frame(card, bg="white")
auto_frame.pack(pady=(10, 2))
autostart_var = tk.StringVar(value="Автозапуск: проверка...")
tk.Label(auto_frame, textvariable=autostart_var, bg="white", fg="#506783", font=("Segoe UI", 9, "bold")).grid(row=0, column=0, padx=8)
autostart_btn = tk.Button(auto_frame, text="Включить автозапуск", command=toggle_autostart)
autostart_btn.grid(row=0, column=1, padx=8)

tk.Label(
    card,
    text="После смены пароля старые подключения автоматически перестают работать. Для доступа вне дома используйте ZeroTier или Tailscale; сервер должен оставаться запущенным.",
    bg="white",
    fg="#6a7d9b",
    font=("Segoe UI", 9),
    wraplength=520,
    justify="center",
).pack(pady=12)

refresh_labels()
refresh_autostart()
start()
root.mainloop()
