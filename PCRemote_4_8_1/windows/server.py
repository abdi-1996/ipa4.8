import base64
import copy
import ctypes
import hashlib
import io
import ipaddress
import json
import os
import secrets
import shutil
import socket
import string
import subprocess
import sys
import time
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
from ctypes import wintypes
from pathlib import Path

from flask import Flask, jsonify, request, abort, send_file, Response
from waitress import serve

import mss
import psutil
from PIL import Image
import pyautogui
import pyperclip

from corel_bridge import COREL, CorelBridgeError

try:
    import websocket
except Exception:
    websocket = None

pyautogui.FAILSAFE = False
pyautogui.PAUSE = 0.01

APP_DIR = Path(sys.executable).resolve().parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent
PCREMOTE_VERSION = "4.8.1"
CONFIG_PATH = APP_DIR / "config.json"
ICON_CACHE_DIR = APP_DIR / "icon_cache"
ICON_CACHE_DIR.mkdir(parents=True, exist_ok=True)

app = Flask(__name__)
CACHE = {"desktop_time": 0.0, "desktop": [], "all_time": 0.0, "all": []}
RECENTS_PATH = APP_DIR / "recent_apps.json"
REMOTE_LOCK = threading.Lock()
INPUT_LOCK = threading.Lock()
REMOTE_PRESETS = {
    "quality": {"jpeg": 88, "max_width": 1920, "fps": 8},
    "balanced": {"jpeg": 70, "max_width": 1440, "fps": 12},
    "latency": {"jpeg": 48, "max_width": 960, "fps": 20},
}

COMFY_WORKFLOW_DIR = APP_DIR / "comfy_workflows"
COMFY_WORKFLOW_DIR.mkdir(parents=True, exist_ok=True)
COMFY_EDITOR_STATE_PATH = APP_DIR / "comfy_editor_state.json"
COMFY_EDITOR_STATE_LOCK = threading.Lock()
COMFY_OBJECT_INFO_CACHE = {"time": 0.0, "value": {}}
COMFY_CATALOG_CACHE = {"time": 0.0, "value": []}
COMFY_CLIENT_ID = str(uuid.uuid4())
COMFY_STATE_LOCK = threading.Lock()
COMFY_STATE = {
    "connected": False,
    "running": False,
    "progress": 0.0,
    "queue_remaining": 0,
    "current_node": None,
    "prompt_id": None,
    "error": None,
    "updated": 0.0,
}
COMFY_WS_THREAD = None
TAILSCALE_CACHE = {"time": 0.0, "value": (None, None, False)}
TAILSCALE_CACHE_LOCK = threading.Lock()
ZEROTIER_CACHE = {"time": 0.0, "value": (None, False)}
ZEROTIER_CACHE_LOCK = threading.Lock()


def load_config():
    cfg = {
        "port": 8765,
        "token": secrets.token_urlsafe(24),
        "comfy_url": "http://127.0.0.1:8188",
        "password_salt": "",
        "password_hash": "",
    }
    if CONFIG_PATH.exists():
        try:
            cfg.update(json.loads(CONFIG_PATH.read_text(encoding="utf-8")))
        except Exception:
            pass
    if not cfg.get("token"):
        cfg["token"] = secrets.token_urlsafe(24)
    cfg["port"] = int(cfg.get("port", 8765))
    cfg["comfy_url"] = str(cfg.get("comfy_url", "http://127.0.0.1:8188")).rstrip("/")
    cfg["password_salt"] = str(cfg.get("password_salt", ""))
    cfg["password_hash"] = str(cfg.get("password_hash", ""))
    CONFIG_PATH.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
    return cfg


CONFIG = load_config()


def save_config():
    CONFIG_PATH.write_text(json.dumps(CONFIG, ensure_ascii=False, indent=2), encoding="utf-8")


def password_is_set():
    return bool(CONFIG.get("password_salt") and CONFIG.get("password_hash"))


def _password_digest(password, salt_hex):
    salt = bytes.fromhex(salt_hex)
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 160_000).hex()


def set_connection_password(password):
    """Store only a salted verifier and rotate the API token to revoke old sessions."""
    password = str(password or "")
    if len(password) < 4:
        raise ValueError("Пароль должен содержать минимум 4 символа")
    salt_hex = secrets.token_hex(16)
    CONFIG["password_salt"] = salt_hex
    CONFIG["password_hash"] = _password_digest(password, salt_hex)
    CONFIG["token"] = secrets.token_urlsafe(24)
    save_config()


def verify_connection_password(password):
    if not password_is_set():
        return False
    try:
        digest = _password_digest(str(password or ""), CONFIG["password_salt"])
    except Exception:
        return False
    return secrets.compare_digest(digest, CONFIG.get("password_hash", ""))


def get_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except Exception:
        try:
            return socket.gethostbyname(socket.gethostname())
        except Exception:
            return "127.0.0.1"
    finally:
        s.close()


def _network_identity():
    ip = get_local_ip()
    mac = None
    broadcast = None
    try:
        for name, addrs in psutil.net_if_addrs().items():
            ipv4 = next((a for a in addrs if a.family == socket.AF_INET and a.address == ip), None)
            if not ipv4:
                continue
            mac_addr = next((a.address for a in addrs if getattr(a, "family", None) == psutil.AF_LINK and a.address), None)
            if mac_addr:
                mac = mac_addr.replace("-", ":").upper()
            if ipv4.netmask:
                network = ipaddress.IPv4Network(f"{ipv4.address}/{ipv4.netmask}", strict=False)
                broadcast = str(network.broadcast_address)
            break
    except Exception:
        pass
    return ip, mac, broadcast


def _tailscale_executable():
    candidates = [
        shutil.which("tailscale"),
        shutil.which("tailscale.exe"),
        str(Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Tailscale" / "tailscale.exe"),
        str(Path(os.environ.get("LOCALAPPDATA", "")) / "Tailscale" / "tailscale.exe") if os.environ.get("LOCALAPPDATA") else None,
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return candidate
    return None


def _tailscale_identity(force=False):
    """Return (IPv4, MagicDNS/FQDN, online) without making Tailscale mandatory."""
    now = time.time()
    with TAILSCALE_CACHE_LOCK:
        if not force and now - float(TAILSCALE_CACHE.get("time", 0.0)) < 10.0:
            return TAILSCALE_CACHE.get("value", (None, None, False))

    exe = _tailscale_executable()
    if not exe:
        value = (None, None, False)
        with TAILSCALE_CACHE_LOCK:
            TAILSCALE_CACHE["time"] = now
            TAILSCALE_CACHE["value"] = value
        return value

    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" and hasattr(subprocess, "CREATE_NO_WINDOW") else 0
    try:
        result = subprocess.run(
            [exe, "status", "--json"],
            capture_output=True,
            text=True,
            timeout=2.5,
            creationflags=flags,
            check=False,
        )
        if result.returncode == 0 and result.stdout.strip():
            value = json.loads(result.stdout)
            self_info = value.get("Self") or {}
            ips = self_info.get("TailscaleIPs") or []
            ipv4 = next((str(ip) for ip in ips if ":" not in str(ip)), None)
            dns = str(self_info.get("DNSName") or "").strip().rstrip(".") or None
            online = bool(self_info.get("Online", True))
            if ipv4 or dns:
                value = (ipv4, dns, online)
                with TAILSCALE_CACHE_LOCK:
                    TAILSCALE_CACHE["time"] = now
                    TAILSCALE_CACHE["value"] = value
                return value
    except Exception:
        pass

    try:
        result = subprocess.run(
            [exe, "ip", "-4"],
            capture_output=True,
            text=True,
            timeout=2.0,
            creationflags=flags,
            check=False,
        )
        ipv4 = result.stdout.strip().splitlines()[0].strip() if result.returncode == 0 and result.stdout.strip() else None
        value = (ipv4, None, bool(ipv4))
        with TAILSCALE_CACHE_LOCK:
            TAILSCALE_CACHE["time"] = now
            TAILSCALE_CACHE["value"] = value
        return value
    except Exception:
        value = (None, None, False)
        with TAILSCALE_CACHE_LOCK:
            TAILSCALE_CACHE["time"] = now
            TAILSCALE_CACHE["value"] = value
        return value



def _zerotier_identity(force=False):
    """Return (IPv4, online) for a ZeroTier virtual adapter, if installed."""
    now = time.time()
    with ZEROTIER_CACHE_LOCK:
        if not force and now - float(ZEROTIER_CACHE.get("time", 0.0)) < 10.0:
            return ZEROTIER_CACHE.get("value", (None, False))

    ipv4 = None
    try:
        stats = psutil.net_if_stats()
        for name, addrs in psutil.net_if_addrs().items():
            if "zerotier" not in name.lower():
                continue
            for addr in addrs:
                if addr.family == socket.AF_INET and addr.address and not addr.address.startswith("169.254."):
                    ipv4 = addr.address
                    break
            if ipv4:
                online = bool(stats.get(name).isup) if stats.get(name) else True
                value = (ipv4, online)
                with ZEROTIER_CACHE_LOCK:
                    ZEROTIER_CACHE["time"] = now
                    ZEROTIER_CACHE["value"] = value
                return value
    except Exception:
        pass

    value = (None, False)
    with ZEROTIER_CACHE_LOCK:
        ZEROTIER_CACHE["time"] = now
        ZEROTIER_CACHE["value"] = value
    return value


def _zerotier_networks():
    networks = []
    try:
        for name, addrs in psutil.net_if_addrs().items():
            if "zerotier" not in name.lower():
                continue
            for addr in addrs:
                if addr.family == socket.AF_INET and addr.address and addr.netmask:
                    try:
                        networks.append(ipaddress.ip_network(f"{addr.address}/{addr.netmask}", strict=False))
                    except Exception:
                        pass
    except Exception:
        pass
    return networks

def _request_transport():
    remote = (request.remote_addr or "").strip()
    try:
        address = ipaddress.ip_address(remote)
        if isinstance(address, ipaddress.IPv4Address) and address in ipaddress.ip_network("100.64.0.0/10"):
            return "tailscale"
        if isinstance(address, ipaddress.IPv6Address) and address in ipaddress.ip_network("fd7a:115c:a1e0::/48"):
            return "tailscale"
    except Exception:
        pass
    try:
        address = ipaddress.ip_address(remote)
        if isinstance(address, ipaddress.IPv4Address):
            for network in _zerotier_networks():
                if address in network:
                    return "zerotier"
    except Exception:
        pass
    return "lan"


def connection_id():
    ip, mac, broadcast = _network_identity()
    tail_ip, tail_dns, _ = _tailscale_identity()
    zero_ip, _ = _zerotier_identity()
    payload = {"h": ip, "p": int(CONFIG["port"]), "t": CONFIG["token"]}
    if mac:
        payload["m"] = mac
    if broadcast:
        payload["b"] = broadcast
    if tail_ip:
        payload["th"] = tail_ip
    if tail_dns:
        payload["td"] = tail_dns
    if zero_ip:
        payload["zh"] = zero_ip
    raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    encoded = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
    return "PCR1-" + encoded


def require_auth():
    expected = f"Bearer {CONFIG['token']}"
    if not secrets.compare_digest(request.headers.get("Authorization", ""), expected):
        abort(401)


@app.before_request
def auth_guard():
    # Login and the small connectivity probe are intentionally public.
    # /api/ping contains no token, password, file or application data; it exists
    # only so the iPhone can verify LAN / ZeroTier / Tailscale before login.
    if request.path in {"/api/auth/login", "/api/ping"}:
        return None
    if request.path.startswith("/api/"):
        require_auth()


def desktop_roots():
    roots = []
    user_desktop = Path.home() / "Desktop"
    if user_desktop.exists():
        roots.append(user_desktop)
    public = os.environ.get("PUBLIC")
    if public:
        p = Path(public) / "Desktop"
        if p.exists():
            roots.append(p)
    if not roots:
        roots.append(Path.home())
    return roots


def desktop():
    return desktop_roots()[0]


def downloads():
    p = Path.home() / "Downloads"
    return p if p.exists() else Path.home()


def drives():
    if os.name != "nt":
        return [Path("/")]
    result = []
    for letter in string.ascii_uppercase:
        p = Path(f"{letter}:\\")
        if p.exists():
            result.append(p)
    return result


def start_menu_roots():
    roots = []
    for env_name in ("PROGRAMDATA", "APPDATA"):
        value = os.environ.get(env_name)
        if value:
            p = Path(value) / "Microsoft" / "Windows" / "Start Menu" / "Programs"
            if p.exists():
                roots.append(p)
    return roots


def icon_for(name):
    n = name.lower()
    groups = [
        (("comfyui", "comfy ui"), "comfyui"),
        (("coreldraw", "corel draw", "corel"), "design"),
        (("chrome", "edge", "firefox", "opera", "browser"), "browser"),
        (("steam", "epic", "battle.net", "gog", "game"), "game"),
        (("discord", "telegram", "whatsapp", "signal", "skype"), "chat"),
        (("spotify", "music", "vlc", "media"), "music"),
        (("word", "writer", "notepad"), "doc"),
        (("excel", "calc"), "sheet"),
        (("powerpoint", "impress"), "slides"),
        (("photoshop", "gimp", "paint"), "design"),
        (("visual studio", "code", "pycharm", "idea", "sublime"), "dev"),
        (("settings", "control panel"), "settings"),
        (("explorer", "проводник"), "folder"),
    ]
    for keys, icon in groups:
        if any(k in n for k in keys):
            return icon
    return "app"


ALLOWED_APP_EXT = {".lnk", ".url", ".exe", ".bat", ".cmd"}
START_APP_EXT = {".lnk", ".url"}

JUNK_NAME_PARTS = (
    "uninstall", "unins", "деинстал", "readme", "help", "справк", "website",
    "documentation", "manual", "license", "release notes", "support", "repair",
    "setup", "installer", "install ", "check for updates", "update service",
    "crash reporter", "diagnostic", "telemetry",
)
SYSTEM_SHORTCUT_NAMES = {
    "command prompt", "командная строка", "windows powershell", "powershell",
    "windows tools", "инструменты windows", "administrative tools",
    "средства администрирования windows", "control panel", "панель управления",
    "run", "выполнить", "task manager", "диспетчер задач",
    "remote desktop connection", "подключение к удаленному рабочему столу",
    "character map", "таблица символов", "system information", "сведения о системе",
    "registry editor", "редактор реестра", "windows memory diagnostic",
    "windows defender firewall with advanced security", "services", "службы",
    "computer management", "управление компьютером", "event viewer", "просмотр событий",
    "disk cleanup", "очистка диска", "defragment and optimize drives",
}
SYSTEM_NAME_PREFIXES = (
    "windows ", "система ", "служебные ", "средства администрирования",
    "администрирование", "windows administrative",
)

SYSTEM_FOLDER_PARTS = {
    "windows system", "система — windows", "windows tools", "инструменты windows",
    "administrative tools", "средства администрирования windows",
    "accessibility", "специальные возможности", "maintenance", "обслуживание",
    "system tools", "служебные — windows", "windows powershell", "powershell",
    "windows ease of access", "windows accessories", "стандартные — windows",
}


def _detect_app_integration(path, display_name):
    low_name = display_name.lower()
    low_path = str(path).lower()
    if "comfyui" in low_name or "comfyui" in low_path or "comfy ui" in low_name:
        return "comfyui"

    if "coreldraw" in low_name or "corel draw" in low_name or "coreldraw" in low_path:
        return "coreldraw"

    comfy_launcher_hints = (
        "run_nvidia_gpu", "fast_fp16_accumulation", "comfy_launcher",
        "comfy-start", "comfy_start",
    )
    if any(hint in low_name or hint in low_path for hint in comfy_launcher_hints):
        return "comfyui"

    if path.suffix.lower() in {".bat", ".cmd", ".ps1"}:
        try:
            content = path.read_text(encoding="utf-8", errors="ignore")[:262144].lower()
            python_portable = "python_embeded" in content or "python_embedded" in content
            comfy_main = "comfyui\\main.py" in content or "comfyui/main.py" in content
            if "comfyui" in content or comfy_main or ("main.py" in content and python_portable):
                return "comfyui"
        except Exception:
            pass
    return None


def app_item(p, start_menu=False, root=None):
    name = p.stem.strip()
    if not name:
        return None
    low = name.lower()
    if any(x in low for x in JUNK_NAME_PARTS):
        return None
    if start_menu:
        if p.suffix.lower() not in START_APP_EXT:
            return None
        if low in SYSTEM_SHORTCUT_NAMES:
            return None
        if any(low.startswith(prefix) for prefix in SYSTEM_NAME_PREFIXES):
            return None
        if root is not None:
            try:
                relative_parts = [part.lower() for part in p.relative_to(root).parts[:-1]]
                if any(part in SYSTEM_FOLDER_PARTS for part in relative_parts):
                    return None
            except Exception:
                pass
    integration = _detect_app_integration(p, name)
    if integration == "comfyui":
        name = "ComfyUI"
    elif integration == "coreldraw":
        name = "CorelDRAW"
    aliases = []
    low_path = str(p).lower()
    if integration == "comfyui":
        aliases.extend(["comfyui", "comfy ui", "comfy", "run_nvidia_gpu", "генерация", "workflow"])
    if integration == "coreldraw":
        aliases.extend(["corel", "coreldraw", "corel draw", "вектор", "дизайн", "cdr"])
    if "telegram" in low or "telegram" in low_path:
        aliases.extend(["telegram", "телеграм", "tg"])
    if "chrome" in low or "chrome" in low_path:
        aliases.extend(["chrome", "google chrome", "хром", "browser"])
    if "corel" in low or "corel" in low_path:
        aliases.extend(["corel", "coreldraw"])

    item = {"id": str(p), "name": name, "icon": icon_for(name)}
    if aliases:
        item["aliases"] = sorted(set(aliases))
    if integration:
        item["integration"] = integration
    return item


def scan_desktop_apps_uncached():
    found = {}
    for root in desktop_roots():
        try:
            for p in root.iterdir():
                try:
                    if not p.is_file() or p.suffix.lower() not in ALLOWED_APP_EXT:
                        continue
                except OSError:
                    continue
                item = app_item(p)
                if item:
                    found.setdefault(item["name"].lower(), item)
        except (OSError, PermissionError):
            continue
    return sorted(found.values(), key=lambda x: x["name"].lower())


def _registered_app_paths():
    """Return EXE paths registered in Windows App Paths."""
    if os.name != "nt":
        return []
    try:
        import winreg
    except Exception:
        return []

    results = []
    seen = set()
    base = r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths"
    roots = [winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE]
    views = [0]
    for flag_name in ("KEY_WOW64_64KEY", "KEY_WOW64_32KEY"):
        flag = getattr(winreg, flag_name, 0)
        if flag not in views:
            views.append(flag)

    for hive in roots:
        for view in views:
            try:
                with winreg.OpenKey(hive, base, 0, winreg.KEY_READ | view) as key:
                    index = 0
                    while True:
                        try:
                            subname = winreg.EnumKey(key, index)
                            index += 1
                        except OSError:
                            break
                        try:
                            with winreg.OpenKey(key, subname) as subkey:
                                raw, _ = winreg.QueryValueEx(subkey, None)
                        except OSError:
                            continue
                        raw = os.path.expandvars(str(raw or "").strip().strip('"'))
                        if not raw:
                            continue
                        p = Path(raw)
                        try:
                            if not p.is_file() or p.suffix.lower() != ".exe":
                                continue
                        except OSError:
                            continue
                        key_id = str(p).lower()
                        if key_id in seen:
                            continue
                        seen.add(key_id)
                        results.append(p)
            except OSError:
                continue
    return results


def _known_user_app_paths():
    if os.name != "nt":
        return []
    candidates = []
    env = os.environ
    roaming = env.get("APPDATA")
    local = env.get("LOCALAPPDATA")
    program_files = env.get("PROGRAMFILES")
    program_files_x86 = env.get("PROGRAMFILES(X86)")
    if roaming:
        candidates.append(Path(roaming) / "Telegram Desktop" / "Telegram.exe")
    if local:
        candidates.extend([
            Path(local) / "Google" / "Chrome" / "Application" / "chrome.exe",
            Path(local) / "Programs" / "Telegram Desktop" / "Telegram.exe",
        ])
    if program_files:
        candidates.append(Path(program_files) / "Google" / "Chrome" / "Application" / "chrome.exe")
    if program_files_x86:
        candidates.append(Path(program_files_x86) / "Google" / "Chrome" / "Application" / "chrome.exe")
    return [p for p in candidates if p.is_file()]


def scan_all_apps_uncached():
    found = {}
    for item in scan_desktop_apps_uncached():
        found[item["name"].lower()] = item

    for root in start_menu_roots():
        try:
            for p in root.rglob("*"):
                try:
                    if not p.is_file() or p.suffix.lower() not in ALLOWED_APP_EXT:
                        continue
                except OSError:
                    continue
                item = app_item(p, start_menu=True, root=root)
                if item:
                    found.setdefault(item["name"].lower(), item)
        except (OSError, PermissionError):
            continue

    for p in _registered_app_paths() + _known_user_app_paths():
        item = app_item(p)
        if item:
            found.setdefault(item["name"].lower(), item)

    return sorted(found.values(), key=lambda x: x["name"].lower())[:400]


def cached_scan(kind, force=False):
    now = time.monotonic()
    time_key = f"{kind}_time"
    if not force and CACHE[kind] and now - CACHE[time_key] < 15:
        return CACHE[kind]
    items = scan_desktop_apps_uncached() if kind == "desktop" else scan_all_apps_uncached()
    CACHE[kind] = items
    CACHE[time_key] = now
    return items


def all_known_apps():
    return cached_scan("all")




def _load_recents():
    try:
        data = json.loads(RECENTS_PATH.read_text(encoding="utf-8"))
        return [str(x) for x in data if isinstance(x, str)]
    except Exception:
        return []


def _save_recents(items):
    try:
        RECENTS_PATH.write_text(json.dumps(items[:18], ensure_ascii=False, indent=2), encoding="utf-8")
    except Exception:
        pass


def record_recent(app_id):
    items = [x for x in _load_recents() if x != app_id]
    items.insert(0, app_id)
    _save_recents(items)


def recent_apps():
    app_map = {item["id"]: item for item in all_known_apps()}
    result = []
    for app_id in _load_recents():
        if app_id in app_map:
            result.append(app_map[app_id])
    return result[:12]


def is_windows_locked():
    if os.name != "nt":
        return False
    try:
        names = {p.info.get("name", "").lower() for p in psutil.process_iter(["name"]) if p.info.get("name")}
        return "logonui.exe" in names
    except Exception:
        return False


def safe_path(raw):
    if not raw:
        return None
    try:
        p = Path(raw).expanduser()
        return p if p.exists() else None
    except Exception:
        return None


def start_item(path):
    if os.name == "nt":
        os.startfile(str(path))
    else:
        subprocess.Popen(["xdg-open", str(path)])


def cached_icon_path(app_id):
    digest = hashlib.sha256(app_id.encode("utf-8", errors="ignore")).hexdigest()
    return ICON_CACHE_DIR / f"{digest}.png"


def extract_windows_icon(source_path, output_path):
    if os.name != "nt":
        return False
    powershell = r'''
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$source = $env:PCREMOTE_ICON_SOURCE
$output = $env:PCREMOTE_ICON_OUTPUT
$iconSource = $source
try {
    if ([System.IO.Path]::GetExtension($source).ToLowerInvariant() -eq ".lnk") {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($source)
        $target = [Environment]::ExpandEnvironmentVariables($shortcut.TargetPath)
        $rawIcon = [Environment]::ExpandEnvironmentVariables($shortcut.IconLocation)
        if ($rawIcon) {
            $candidate = $rawIcon -replace ',\s*-?\d+\s*$', ''
            $candidate = $candidate.Trim('"')
            if ([System.IO.Path]::GetExtension($candidate).ToLowerInvariant() -eq ".ico" -and (Test-Path -LiteralPath $candidate)) {
                $iconSource = $candidate
            } elseif ($target -and (Test-Path -LiteralPath $target)) {
                $iconSource = $target
            } elseif (Test-Path -LiteralPath $candidate) {
                $iconSource = $candidate
            }
        } elseif ($target -and (Test-Path -LiteralPath $target)) {
            $iconSource = $target
        }
    }
    if (-not (Test-Path -LiteralPath $iconSource)) { exit 3 }
    $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconSource)
    if ($null -eq $icon) { exit 4 }
    $bitmap = $icon.ToBitmap()
    $bitmap.Save($output, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $icon.Dispose()
    exit 0
} catch { exit 5 }
'''
    env = os.environ.copy()
    env["PCREMOTE_ICON_SOURCE"] = str(source_path)
    env["PCREMOTE_ICON_OUTPUT"] = str(output_path)
    try:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", powershell],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=12,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        return result.returncode == 0 and output_path.exists() and output_path.stat().st_size > 0
    except Exception:
        return False


# ---------------------------------------------------------------------------
# ComfyUI local integration (ComfyUI is expected on the same Windows PC).
# The iPhone never talks to port 8188 directly: PC Remote Server proxies it.


def _comfy_base():
    return str(CONFIG.get("comfy_url", "http://127.0.0.1:8188")).rstrip("/")


def _comfy_http_url(path, query=None):
    path = path if path.startswith("/") else "/" + path
    url = _comfy_base() + path
    if query:
        url += "?" + urllib.parse.urlencode(query, doseq=True)
    return url


def _comfy_json(path, method="GET", payload=None, timeout=4):
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(_comfy_http_url(path), data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        raw = response.read()
    if not raw:
        return {}
    return json.loads(raw.decode("utf-8"))


def _comfy_available():
    try:
        _comfy_json("/system_stats", timeout=1.5)
        return True
    except Exception:
        return False


def _set_comfy_state(**kwargs):
    with COMFY_STATE_LOCK:
        COMFY_STATE.update(kwargs)
        COMFY_STATE["updated"] = time.time()


def _comfy_state_copy():
    with COMFY_STATE_LOCK:
        return dict(COMFY_STATE)


def _comfy_ws_url():
    parsed = urllib.parse.urlparse(_comfy_base())
    scheme = "wss" if parsed.scheme == "https" else "ws"
    root = parsed.path.rstrip("/")
    return f"{scheme}://{parsed.netloc}{root}/ws?clientId={urllib.parse.quote(COMFY_CLIENT_ID)}"


def _comfy_ws_loop():
    if websocket is None:
        return
    while True:
        ws = None
        try:
            ws = websocket.WebSocket()
            ws.settimeout(20)
            ws.connect(_comfy_ws_url(), timeout=5)
            _set_comfy_state(connected=True, error=None)
            while True:
                message = ws.recv()
                if not isinstance(message, str):
                    # ComfyUI may send binary preview frames; result thumbnails are
                    # retrieved through /history + /view, so they can be ignored here.
                    continue
                event = json.loads(message)
                event_type = str(event.get("type", ""))
                data = event.get("data") or {}
                if event_type == "status":
                    exec_info = data.get("status", {}).get("exec_info", {}) if isinstance(data.get("status"), dict) else data.get("exec_info", {})
                    remaining = exec_info.get("queue_remaining", 0)
                    try:
                        remaining = int(remaining)
                    except Exception:
                        remaining = 0
                    _set_comfy_state(connected=True, queue_remaining=remaining, error=None)
                elif event_type == "execution_start":
                    _set_comfy_state(
                        connected=True,
                        running=True,
                        progress=0.0,
                        prompt_id=data.get("prompt_id"),
                        current_node=None,
                        error=None,
                    )
                elif event_type == "progress":
                    value = float(data.get("value", 0) or 0)
                    maximum = float(data.get("max", 0) or 0)
                    fraction = value / maximum if maximum > 0 else 0.0
                    _set_comfy_state(
                        connected=True,
                        running=True,
                        progress=max(0.0, min(1.0, fraction)),
                        prompt_id=data.get("prompt_id") or _comfy_state_copy().get("prompt_id"),
                        current_node=str(data.get("node")) if data.get("node") is not None else None,
                        error=None,
                    )
                elif event_type == "executing":
                    node = data.get("node")
                    prompt_id = data.get("prompt_id")
                    if node is None:
                        _set_comfy_state(
                            connected=True,
                            running=False,
                            progress=1.0,
                            prompt_id=prompt_id,
                            current_node=None,
                            error=None,
                        )
                    else:
                        _set_comfy_state(
                            connected=True,
                            running=True,
                            prompt_id=prompt_id,
                            current_node=str(node),
                            error=None,
                        )
                elif event_type == "execution_error":
                    _set_comfy_state(
                        connected=True,
                        running=False,
                        prompt_id=data.get("prompt_id"),
                        error=str(data.get("exception_message") or data.get("exception_type") or "Ошибка ComfyUI"),
                    )
                elif event_type == "execution_interrupted":
                    _set_comfy_state(
                        connected=True,
                        running=False,
                        prompt_id=data.get("prompt_id"),
                        error="Генерация остановлена",
                    )
        except Exception:
            _set_comfy_state(connected=False, running=False, current_node=None)
            time.sleep(2.5)
        finally:
            try:
                if ws is not None:
                    ws.close()
            except Exception:
                pass


def ensure_comfy_ws_thread():
    global COMFY_WS_THREAD
    if websocket is None:
        return
    if COMFY_WS_THREAD and COMFY_WS_THREAD.is_alive():
        return
    COMFY_WS_THREAD = threading.Thread(target=_comfy_ws_loop, name="PCRemote-ComfyUI-WS", daemon=True)
    COMFY_WS_THREAD.start()


def _is_api_workflow(value):
    if not isinstance(value, dict) or not value:
        return False
    checked = 0
    for node in value.values():
        if not isinstance(node, dict):
            return False
        if "class_type" not in node or "inputs" not in node:
            return False
        checked += 1
        if checked >= 3:
            break
    return checked > 0



def _is_ui_workflow(value):
    return (
        isinstance(value, dict)
        and isinstance(value.get("nodes"), list)
        and isinstance(value.get("links"), list)
    )


def _load_comfy_editor_state():
    with COMFY_EDITOR_STATE_LOCK:
        if not COMFY_EDITOR_STATE_PATH.exists():
            return {}
        try:
            value = json.loads(COMFY_EDITOR_STATE_PATH.read_text(encoding="utf-8"))
            return value if isinstance(value, dict) else {}
        except Exception:
            return {}


def _write_comfy_editor_state(value):
    with COMFY_EDITOR_STATE_LOCK:
        tmp = COMFY_EDITOR_STATE_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(COMFY_EDITOR_STATE_PATH)


def _workflow_editor_state(workflow_id):
    all_state = _load_comfy_editor_state()
    value = all_state.get(workflow_id)
    return value if isinstance(value, dict) else {}


def _update_workflow_editor_state(workflow_id, mutate):
    all_state = _load_comfy_editor_state()
    state = all_state.get(workflow_id)
    if not isinstance(state, dict):
        state = {}
    mutate(state)
    all_state[workflow_id] = state
    _write_comfy_editor_state(all_state)
    return state


def _comfy_object_info():
    now = time.time()
    cached = COMFY_OBJECT_INFO_CACHE.get("value") or {}
    if cached and now - float(COMFY_OBJECT_INFO_CACHE.get("time") or 0.0) < 60:
        return cached
    try:
        value = _comfy_json("/object_info", timeout=8)
        if isinstance(value, dict):
            COMFY_OBJECT_INFO_CACHE["value"] = value
            COMFY_OBJECT_INFO_CACHE["time"] = now
            return value
    except Exception:
        pass
    return cached


def _comfy_userdata_list():
    # Current ComfyUI exposes workflows through user-data routes. We accept
    # several response shapes because the v1 and v2 endpoints differ.
    candidates = [
        ("/v2/userdata", {"dir": "workflows", "recurse": "true"}),
        ("/userdata", {"dir": "workflows", "recurse": "true"}),
        ("/userdata", {"dir": "workflows"}),
    ]
    paths = []
    for route, query in candidates:
        try:
            value = _comfy_json(route + "?" + urllib.parse.urlencode(query), timeout=5)
        except Exception:
            continue

        def walk(obj, prefix=""):
            if isinstance(obj, str):
                p = obj.replace("\\\\", "/")
                if p.lower().endswith(".json"):
                    if not p.startswith("workflows/"):
                        p = "workflows/" + p.lstrip("/")
                    paths.append(p)
            elif isinstance(obj, list):
                for item in obj:
                    walk(item, prefix)
            elif isinstance(obj, dict):
                # v2 commonly returns structured entries containing path/name.
                for key in ("path", "file", "filename"):
                    val = obj.get(key)
                    if isinstance(val, str) and val.lower().endswith(".json"):
                        p = val.replace("\\\\", "/")
                        if not p.startswith("workflows/"):
                            p = "workflows/" + p.lstrip("/")
                        paths.append(p)
                name = obj.get("name")
                is_dir = bool(obj.get("is_dir") or obj.get("directory") or obj.get("type") == "directory")
                if isinstance(name, str) and name.lower().endswith(".json") and not is_dir:
                    p = (prefix.rstrip("/") + "/" + name).strip("/")
                    if not p.startswith("workflows/"):
                        p = "workflows/" + p
                    paths.append(p)
                for key in ("items", "files", "children", "data"):
                    if key in obj:
                        walk(obj.get(key), prefix)
                # v1 can return {"file.json": {...}} or simple dictionaries.
                for k, v in obj.items():
                    if isinstance(k, str) and k.lower().endswith(".json"):
                        p = (prefix.rstrip("/") + "/" + k).strip("/")
                        if not p.startswith("workflows/"):
                            p = "workflows/" + p
                        paths.append(p)
                    elif isinstance(v, (dict, list)):
                        next_prefix = prefix
                        if isinstance(k, str) and k not in {"items", "files", "children", "data"}:
                            next_prefix = (prefix.rstrip("/") + "/" + k).strip("/")
                        walk(v, next_prefix)

        walk(value, "workflows")
        if paths:
            break
    result = []
    seen = set()
    for p in paths:
        p = p.replace("//", "/")
        if p not in seen:
            seen.add(p)
            result.append(p)
    return result[:200]


def _comfy_userdata_file(path):
    clean = str(path).replace("\\\\", "/").lstrip("/")
    attempts = [
        "/userdata/" + urllib.parse.quote(clean, safe=""),
        "/userdata/" + urllib.parse.quote(clean, safe="/"),
    ]
    for route in attempts:
        try:
            req = urllib.request.Request(_comfy_base() + route, headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=5) as response:
                raw = response.read()
            return json.loads(raw.decode("utf-8"))
        except Exception:
            continue
    return None


def _safe_workflow_filename(name):
    base = Path(str(name or "workflow.json")).name
    if not base.lower().endswith(".json"):
        base += ".json"
    safe = "".join(ch for ch in base if ch not in '<>:"/\\\\|?*').strip(" .")
    return (safe or "workflow.json")[:180]


def _try_upload_comfy_userdata(filename, raw):
    # Best effort: imported workflows also become visible in ComfyUI's workflow
    # library when the local server supports userdata writes.
    rel = "workflows/" + _safe_workflow_filename(filename)
    for encoded in (urllib.parse.quote(rel, safe=""), urllib.parse.quote(rel, safe="/")):
        try:
            req = urllib.request.Request(
                _comfy_base() + "/userdata/" + encoded,
                data=raw,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=5) as response:
                response.read()
            return True
        except Exception:
            continue
    return False


def _workflow_format(value):
    if _is_api_workflow(value):
        return "api"
    if _is_ui_workflow(value):
        return "ui"
    return "unknown"


def _workflow_name_from_ui(value, fallback):
    if isinstance(value, dict):
        for key in ("name", "title", "workflow_name"):
            candidate = value.get(key)
            if isinstance(candidate, str) and candidate.strip():
                return candidate.strip()
        extra = value.get("extra")
        if isinstance(extra, dict):
            for key in ("name", "title", "workflow_name"):
                candidate = extra.get(key)
                if isinstance(candidate, str) and candidate.strip():
                    return candidate.strip()
    return fallback


def _history_prompt(entry):
    if not isinstance(entry, dict):
        return None
    value = entry.get("prompt")
    if _is_api_workflow(value):
        return value
    if isinstance(value, list) and len(value) >= 3 and _is_api_workflow(value[2]):
        return value[2]
    return None


def _history_sequence(entry):
    if not isinstance(entry, dict):
        return -1.0
    value = entry.get("prompt")
    if isinstance(value, list) and value:
        try:
            return float(value[0])
        except Exception:
            pass
    return -1.0


def _history_entries(limit=12):
    try:
        history = _comfy_json("/history", timeout=4)
    except Exception:
        return []
    if not isinstance(history, dict):
        return []
    items = [(str(prompt_id), entry) for prompt_id, entry in history.items() if isinstance(entry, dict)]
    items.sort(key=lambda pair: _history_sequence(pair[1]), reverse=True)
    return items[:limit]


def _workflow_title(prompt, fallback):
    # API-format workflow files do not have a required workflow-level title.
    # Keep the filename/history label rather than accidentally using a node title.
    return fallback


def _history_workflow_name(entry, fallback):
    value = entry.get("prompt") if isinstance(entry, dict) else None
    extra = value[3] if isinstance(value, list) and len(value) > 3 and isinstance(value[3], dict) else {}

    def walk(obj, depth=0):
        if depth > 7:
            return None
        if isinstance(obj, dict):
            # Prefer explicit workflow-name keys.
            for key in ("workflow_name", "workflowName", "title"):
                candidate = obj.get(key)
                if isinstance(candidate, str) and candidate.strip():
                    return candidate.strip()
            for key, child in obj.items():
                if str(key).lower() in {"workflow", "extra_pnginfo", "extra", "metadata"}:
                    found = walk(child, depth + 1)
                    if found:
                        return found
        return None

    return walk(extra) or fallback


def _workflow_catalog(force=False):
    now = time.time()
    cached = COMFY_CATALOG_CACHE.get("value") or []
    if not force and cached and now - float(COMFY_CATALOG_CACHE.get("time") or 0.0) < 6.0:
        return copy.deepcopy(cached)
    result = []
    seen_ids = set()

    # 1) PC Remote imported workflows. They may be API-format or normal ComfyUI
    # graph JSON; both are visible/editable, API-format ones are executable.
    for file_path in sorted(COMFY_WORKFLOW_DIR.glob("*.json"), key=lambda p: p.name.lower()):
        try:
            value = json.loads(file_path.read_text(encoding="utf-8"))
        except Exception:
            continue
        fmt = _workflow_format(value)
        if fmt == "unknown":
            continue
        item_id = "file:" + file_path.name
        result.append({
            "id": item_id,
            "name": _workflow_name_from_ui(value, _workflow_title(value, file_path.stem)),
            "source": "Импортировано в PC Remote",
            "node_count": len(value) if fmt == "api" else len(value.get("nodes") or []),
            "category": "all",
            "editable": True,
            "executable": fmt == "api",
            "format": fmt,
        })
        seen_ids.add(item_id)

    # 2) Workflows saved in ComfyUI itself (the library used by the frontend).
    for rel_path in _comfy_userdata_list():
        item_id = "userdata:" + rel_path
        if item_id in seen_ids:
            continue
        value = _comfy_userdata_file(rel_path)
        fmt = _workflow_format(value)
        if fmt == "unknown":
            continue
        fallback = Path(rel_path).stem
        result.append({
            "id": item_id,
            "name": _workflow_name_from_ui(value, fallback),
            "source": "ComfyUI • сохранённый workflow",
            "node_count": len(value) if fmt == "api" else len(value.get("nodes") or []),
            "category": "all",
            "editable": True,
            "executable": fmt == "api",
            "format": fmt,
        })
        seen_ids.add(item_id)

    # 3) Recent executed workflows. This source is always API-format and can run.
    seen_hashes = set()
    for index, (prompt_id, entry) in enumerate(_history_entries(limit=14)):
        prompt = _history_prompt(entry)
        if not prompt:
            continue
        digest = hashlib.sha1(json.dumps(prompt, sort_keys=True, ensure_ascii=True).encode("utf-8")).hexdigest()
        if digest in seen_hashes:
            continue
        seen_hashes.add(digest)
        fallback = "Последняя генерация" if index == 0 else f"Недавний workflow {len(seen_hashes)}"
        result.append({
            "id": "history:" + prompt_id,
            "name": _history_workflow_name(entry, fallback),
            "source": "История ComfyUI",
            "node_count": len(prompt),
            "category": "recent",
            "editable": True,
            "executable": True,
            "format": "api",
        })
        if len(seen_hashes) >= 8:
            break

    COMFY_CATALOG_CACHE["time"] = now
    COMFY_CATALOG_CACHE["value"] = copy.deepcopy(result)
    return result


def _load_workflow(workflow_id):
    if not workflow_id:
        catalog = _workflow_catalog()
        if not catalog:
            return None, None
        # Prefer executable workflows for the main generator.
        preferred = next((x for x in catalog if x.get("executable")), catalog[0])
        workflow_id = preferred["id"]

    if workflow_id.startswith("file:"):
        name = workflow_id[5:]
        candidates = {p.name: p for p in COMFY_WORKFLOW_DIR.glob("*.json")}
        path = candidates.get(name)
        if path is None:
            return None, None
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return None, None
        return (workflow_id, value) if _workflow_format(value) != "unknown" else (None, None)

    if workflow_id.startswith("userdata:"):
        rel = workflow_id[len("userdata:"):]
        value = _comfy_userdata_file(rel)
        return (workflow_id, value) if _workflow_format(value) != "unknown" else (None, None)

    if workflow_id.startswith("history:"):
        prompt_id = workflow_id[8:]
        try:
            history = _comfy_json("/history/" + urllib.parse.quote(prompt_id, safe=""), timeout=4)
        except Exception:
            return None, None
        if isinstance(history, dict):
            entry = history.get(prompt_id)
            prompt = _history_prompt(entry)
            if prompt:
                return workflow_id, prompt
    return None, None


def _node_inputs(prompt, node_id):
    node = prompt.get(str(node_id)) if isinstance(prompt, dict) else None
    inputs = node.get("inputs") if isinstance(node, dict) else None
    return inputs if isinstance(inputs, dict) else None


def _find_node(prompt, class_contains):
    class_contains = tuple(x.lower() for x in class_contains)
    for node_id, node in prompt.items():
        if not isinstance(node, dict):
            continue
        class_type = str(node.get("class_type", "")).lower()
        if any(value in class_type for value in class_contains):
            return str(node_id), node
    return None, None


def _extract_workflow_parameters(prompt):
    params = {
        "positive": "",
        "negative": "",
        "steps": 20,
        "cfg": 7.0,
        "seed": 0,
        "sampler": "",
        "scheduler": "",
        "width": 512,
        "height": 512,
        "checkpoint": "",
        "lora": "",
        "vae": "",
    }

    sampler_id, sampler = _find_node(prompt, ("ksampler",))
    sampler_inputs = sampler.get("inputs", {}) if isinstance(sampler, dict) else {}
    if isinstance(sampler_inputs, dict):
        for key, target in (("steps", "steps"), ("cfg", "cfg"), ("seed", "seed"), ("sampler_name", "sampler"), ("scheduler", "scheduler")):
            value = sampler_inputs.get(key)
            if isinstance(value, (str, int, float)):
                params[target] = value

        for source_name, target_name in (("positive", "positive"), ("negative", "negative")):
            ref = sampler_inputs.get(source_name)
            if isinstance(ref, list) and ref:
                text_inputs = _node_inputs(prompt, ref[0])
                if text_inputs and isinstance(text_inputs.get("text"), str):
                    params[target_name] = text_inputs["text"]

    # Fallback for workflows where sampler links are wrapped by conditioning nodes.
    if not params["positive"] or not params["negative"]:
        for _, node in prompt.items():
            if not isinstance(node, dict) or "cliptextencode" not in str(node.get("class_type", "")).lower():
                continue
            inputs = node.get("inputs", {})
            if not isinstance(inputs, dict) or not isinstance(inputs.get("text"), str):
                continue
            title = str((node.get("_meta") or {}).get("title", "")).lower() if isinstance(node.get("_meta"), dict) else ""
            if "negative" in title and not params["negative"]:
                params["negative"] = inputs["text"]
            elif not params["positive"]:
                params["positive"] = inputs["text"]

    _, latent = _find_node(prompt, ("emptylatentimage", "emptyimage"))
    latent_inputs = latent.get("inputs", {}) if isinstance(latent, dict) else {}
    if isinstance(latent_inputs, dict):
        if isinstance(latent_inputs.get("width"), (int, float)):
            params["width"] = int(latent_inputs["width"])
        if isinstance(latent_inputs.get("height"), (int, float)):
            params["height"] = int(latent_inputs["height"])

    _, checkpoint = _find_node(prompt, ("checkpointloader",))
    ckpt_inputs = checkpoint.get("inputs", {}) if isinstance(checkpoint, dict) else {}
    if isinstance(ckpt_inputs, dict) and isinstance(ckpt_inputs.get("ckpt_name"), str):
        params["checkpoint"] = ckpt_inputs["ckpt_name"]

    _, lora = _find_node(prompt, ("loraloader",))
    lora_inputs = lora.get("inputs", {}) if isinstance(lora, dict) else {}
    if isinstance(lora_inputs, dict) and isinstance(lora_inputs.get("lora_name"), str):
        params["lora"] = lora_inputs["lora_name"]

    _, vae = _find_node(prompt, ("vaeloader",))
    vae_inputs = vae.get("inputs", {}) if isinstance(vae, dict) else {}
    if isinstance(vae_inputs, dict) and isinstance(vae_inputs.get("vae_name"), str):
        params["vae"] = vae_inputs["vae_name"]

    params["steps"] = int(params["steps"] or 20)
    params["cfg"] = float(params["cfg"] or 7.0)
    try:
        params["seed"] = int(params["seed"] or 0)
    except Exception:
        params["seed"] = 0
    params["width"] = int(params["width"] or 512)
    params["height"] = int(params["height"] or 512)
    return params


def _apply_workflow_parameters(prompt, params):
    prompt = copy.deepcopy(prompt)
    _, sampler = _find_node(prompt, ("ksampler",))
    sampler_inputs = sampler.get("inputs", {}) if isinstance(sampler, dict) else {}
    if isinstance(sampler_inputs, dict):
        mapping = {
            "steps": "steps", "cfg": "cfg", "seed": "seed",
            "sampler": "sampler_name", "scheduler": "scheduler",
        }
        for source, target in mapping.items():
            value = params.get(source)
            if value is not None and target in sampler_inputs:
                sampler_inputs[target] = value
        for source_name in ("positive", "negative"):
            value = params.get(source_name)
            ref = sampler_inputs.get(source_name)
            if isinstance(value, str) and isinstance(ref, list) and ref:
                target_inputs = _node_inputs(prompt, ref[0])
                if target_inputs is not None and "text" in target_inputs:
                    target_inputs["text"] = value

    # Apply text fallback by titles when direct sampler references were not enough.
    for _, node in prompt.items():
        if not isinstance(node, dict) or "cliptextencode" not in str(node.get("class_type", "")).lower():
            continue
        inputs = node.get("inputs", {})
        if not isinstance(inputs, dict) or "text" not in inputs:
            continue
        title = str((node.get("_meta") or {}).get("title", "")).lower() if isinstance(node.get("_meta"), dict) else ""
        if "negative" in title and isinstance(params.get("negative"), str):
            inputs["text"] = params["negative"]
        elif "positive" in title and isinstance(params.get("positive"), str):
            inputs["text"] = params["positive"]

    _, latent = _find_node(prompt, ("emptylatentimage", "emptyimage"))
    latent_inputs = latent.get("inputs", {}) if isinstance(latent, dict) else {}
    if isinstance(latent_inputs, dict):
        if "width" in latent_inputs and params.get("width") is not None:
            latent_inputs["width"] = int(params["width"])
        if "height" in latent_inputs and params.get("height") is not None:
            latent_inputs["height"] = int(params["height"])

    _, checkpoint = _find_node(prompt, ("checkpointloader",))
    ckpt_inputs = checkpoint.get("inputs", {}) if isinstance(checkpoint, dict) else {}
    if isinstance(ckpt_inputs, dict) and "ckpt_name" in ckpt_inputs and params.get("checkpoint"):
        ckpt_inputs["ckpt_name"] = str(params["checkpoint"])

    _, lora = _find_node(prompt, ("loraloader",))
    lora_inputs = lora.get("inputs", {}) if isinstance(lora, dict) else {}
    if isinstance(lora_inputs, dict) and "lora_name" in lora_inputs and params.get("lora"):
        lora_inputs["lora_name"] = str(params["lora"])

    _, vae = _find_node(prompt, ("vaeloader",))
    vae_inputs = vae.get("inputs", {}) if isinstance(vae, dict) else {}
    if isinstance(vae_inputs, dict) and "vae_name" in vae_inputs and params.get("vae"):
        vae_inputs["vae_name"] = str(params["vae"])
    return prompt



def _default_node_color(class_type):
    low = str(class_type or "").lower()
    if "checkpoint" in low or "model" in low:
        return "#6D5DFB"
    if "lora" in low:
        return "#32C48D"
    if "vae" in low:
        return "#2DA8FF"
    if "clip" in low or "text" in low:
        return "#F5A623"
    if "sampler" in low:
        return "#3D7BFF"
    if "save" in low or "preview" in low:
        return "#9B59B6"
    return "#607D8B"


def _scalar_to_text(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return ""
    if isinstance(value, (str, int, float)):
        return str(value)
    try:
        return json.dumps(value, ensure_ascii=False)
    except Exception:
        return str(value)


def _input_options(class_type, input_name, object_info=None):
    object_info = object_info if isinstance(object_info, dict) else _comfy_object_info()
    info = object_info.get(str(class_type), {}) if isinstance(object_info, dict) else {}
    input_info = info.get("input") if isinstance(info, dict) else None
    if not isinstance(input_info, dict):
        return []
    for section in ("required", "optional"):
        values = input_info.get(section)
        if not isinstance(values, dict) or input_name not in values:
            continue
        spec = values.get(input_name)
        if isinstance(spec, list) and spec:
            first = spec[0]
            if isinstance(first, list):
                return [str(x) for x in first][:500]
    return []


def _object_input_specs(class_type, object_info=None):
    object_info = object_info if isinstance(object_info, dict) else _comfy_object_info()
    info = object_info.get(str(class_type), {}) if isinstance(object_info, dict) else {}
    input_info = info.get("input") if isinstance(info, dict) else {}
    result = []
    slot = 0
    if not isinstance(input_info, dict):
        return result
    for section in ("required", "optional"):
        values = input_info.get(section)
        if not isinstance(values, dict):
            continue
        for name, spec in values.items():
            first = spec[0] if isinstance(spec, list) and spec else None
            meta = spec[1] if isinstance(spec, list) and len(spec) > 1 and isinstance(spec[1], dict) else {}
            if isinstance(first, list):
                input_type = "COMBO"
                options = [str(x) for x in first][:500]
                default = meta.get("default", options[0] if options else "")
                scalar = True
            else:
                input_type = str(first or "*")
                options = []
                scalar = input_type.upper() in {"INT", "FLOAT", "STRING", "BOOLEAN"}
                if "default" in meta:
                    default = meta.get("default")
                elif input_type.upper() == "INT":
                    default = 0
                elif input_type.upper() == "FLOAT":
                    default = 0.0
                elif input_type.upper() == "BOOLEAN":
                    default = False
                elif input_type.upper() == "STRING":
                    default = ""
                else:
                    default = None
            result.append({
                "name": str(name),
                "type": input_type,
                "options": options,
                "default": default,
                "scalar": scalar,
                "slot": slot,
                "required": section == "required",
            })
            slot += 1
    return result


def _object_outputs(class_type, object_info=None):
    object_info = object_info if isinstance(object_info, dict) else _comfy_object_info()
    info = object_info.get(str(class_type), {}) if isinstance(object_info, dict) else {}
    raw = info.get("output") if isinstance(info, dict) and isinstance(info.get("output"), list) else []
    names = info.get("output_name") if isinstance(info, dict) and isinstance(info.get("output_name"), list) else []
    result = []
    for idx, out_type in enumerate(raw):
        name = str(names[idx]) if idx < len(names) and names[idx] else str(out_type or f"Output {idx + 1}")
        result.append({"name": name, "type": str(out_type or "*"), "slot": idx})
    return result


def _node_position(saved, raw_node, index):
    x = saved.get("position_x")
    y = saved.get("position_y")
    width = saved.get("node_width")
    height = saved.get("node_height")
    if isinstance(raw_node, dict):
        pos = raw_node.get("pos")
        size = raw_node.get("size")
        if x is None and isinstance(pos, list) and len(pos) >= 2:
            x = pos[0]
            y = pos[1]
        if width is None and isinstance(size, list) and len(size) >= 2:
            width = size[0]
            height = size[1]
    if x is None:
        x = 180 + (index % 3) * 330
    if y is None:
        y = 150 + (index // 3) * 260
    try: x = float(x)
    except Exception: x = 180.0
    try: y = float(y)
    except Exception: y = 150.0
    try: width = float(width or 235)
    except Exception: width = 235.0
    try: height = float(height or 175)
    except Exception: height = 175.0
    return x, y, max(160.0, width), max(120.0, height)


def _workflow_details(workflow_id):
    selected_id, value = _load_workflow(workflow_id)
    if value is None:
        return None
    fmt = _workflow_format(value)
    state = _workflow_editor_state(selected_id)
    node_state = state.get("nodes") if isinstance(state.get("nodes"), dict) else {}
    order = state.get("order") if isinstance(state.get("order"), list) else []
    object_info = _comfy_object_info()

    nodes = []
    connections = []

    if fmt == "api":
        for index, (node_id, raw_node) in enumerate(value.items()):
            if not isinstance(raw_node, dict):
                continue
            node_id = str(node_id)
            class_type = str(raw_node.get("class_type") or "Node")
            meta = raw_node.get("_meta") if isinstance(raw_node.get("_meta"), dict) else {}
            saved = node_state.get(node_id) if isinstance(node_state.get(node_id), dict) else {}
            title = str(saved.get("title") or meta.get("title") or class_type)
            color = str(saved.get("color") or _default_node_color(class_type))
            placement = str(saved.get("placement") or "free")
            width_mode = str(saved.get("width_mode") or "free")
            muted = bool(saved.get("muted", False))
            input_overrides = saved.get("inputs") if isinstance(saved.get("inputs"), dict) else {}
            specs = _object_input_specs(class_type, object_info)
            spec_map = {x["name"]: x for x in specs}
            x, y, node_width, node_height = _node_position(saved, None, index)

            inputs = []
            raw_inputs = raw_node.get("inputs") if isinstance(raw_node.get("inputs"), dict) else {}
            all_names = list(raw_inputs.keys())
            for spec in specs:
                if spec["name"] not in all_names:
                    all_names.append(spec["name"])
            for slot, name in enumerate(all_names):
                raw_value = raw_inputs.get(name, spec_map.get(name, {}).get("default"))
                spec = spec_map.get(name, {})
                connected_from = None
                if (
                    isinstance(raw_value, list)
                    and len(raw_value) >= 2
                    and isinstance(raw_value[0], (str, int))
                    and isinstance(raw_value[1], int)
                ):
                    connected_from = str(raw_value[0])
                    from_slot = int(raw_value[1])
                    connections.append({
                        "from": connected_from,
                        "to": node_id,
                        "label": str(name),
                        "from_slot": from_slot,
                        "to_slot": slot,
                        "input_name": str(name),
                        "type": str(spec.get("type") or "*"),
                    })
                    display_value = f"← {connected_from}"
                    value_type = "connection"
                else:
                    if spec and not spec.get("scalar"):
                        display_value = "Not connected"
                        value_type = "connection"
                    else:
                        display_value = _scalar_to_text(input_overrides.get(name, raw_value))
                        if isinstance(raw_value, bool): value_type = "bool"
                        elif isinstance(raw_value, int) and not isinstance(raw_value, bool): value_type = "int"
                        elif isinstance(raw_value, float): value_type = "float"
                        elif isinstance(raw_value, str): value_type = "string"
                        else: value_type = "json"
                inputs.append({
                    "name": str(name),
                    "value": display_value,
                    "value_type": value_type,
                    "options": spec.get("options", []) if value_type != "connection" else [],
                    "connected_from": connected_from,
                    "input_type": str(spec.get("type") or "*"),
                    "slot": slot,
                })

            nodes.append({
                "id": node_id,
                "title": title,
                "class_type": class_type,
                "color": color,
                "placement": placement,
                "width_mode": width_mode,
                "muted": muted,
                "inputs": inputs,
                "outputs": _object_outputs(class_type, object_info),
                "position_x": x,
                "position_y": y,
                "node_width": node_width,
                "node_height": node_height,
            })

    elif fmt == "ui":
        raw_nodes = value.get("nodes") if isinstance(value.get("nodes"), list) else []
        link_origin = {}
        raw_links = value.get("links") if isinstance(value.get("links"), list) else []
        for link in raw_links:
            if isinstance(link, list) and len(link) >= 5:
                link_origin[str(link[0])] = link

        for index, raw_node in enumerate(raw_nodes):
            if not isinstance(raw_node, dict):
                continue
            node_id = str(raw_node.get("id"))
            class_type = str(raw_node.get("type") or raw_node.get("class_type") or "Node")
            saved = node_state.get(node_id) if isinstance(node_state.get(node_id), dict) else {}
            title = str(saved.get("title") or raw_node.get("title") or class_type)
            color = str(saved.get("color") or raw_node.get("color") or raw_node.get("bgcolor") or _default_node_color(class_type))
            placement = str(saved.get("placement") or "free")
            width_mode = str(saved.get("width_mode") or "free")
            muted = bool(saved.get("muted", bool(raw_node.get("mode") not in (None, 0))))
            input_overrides = saved.get("inputs") if isinstance(saved.get("inputs"), dict) else {}
            specs = _object_input_specs(class_type, object_info)
            spec_map = {x["name"]: x for x in specs}
            x, y, node_width, node_height = _node_position(saved, raw_node, index)

            inputs = []
            raw_input_defs = raw_node.get("inputs") if isinstance(raw_node.get("inputs"), list) else []
            for slot, entry in enumerate(raw_input_defs):
                if not isinstance(entry, dict):
                    continue
                name = str(entry.get("name") or "input")
                link_id = entry.get("link")
                spec = spec_map.get(name, {})
                connected_from = None
                if link_id is not None:
                    link = link_origin.get(str(link_id))
                    if isinstance(link, list) and len(link) >= 5:
                        connected_from = str(link[1])
                    display_value = "Connected"
                    value_type = "connection"
                else:
                    display_value = _scalar_to_text(input_overrides.get(name, ""))
                    value_type = "string"
                inputs.append({
                    "name": name,
                    "value": display_value,
                    "value_type": value_type,
                    "options": spec.get("options", []) if value_type != "connection" else [],
                    "connected_from": connected_from,
                    "input_type": str(entry.get("type") or spec.get("type") or "*"),
                    "slot": slot,
                })

            widgets = raw_node.get("widgets_values") if isinstance(raw_node.get("widgets_values"), list) else []
            scalar_specs = [x for x in specs if x.get("scalar")]
            for idx, widget_value in enumerate(widgets):
                spec = scalar_specs[idx] if idx < len(scalar_specs) else None
                name = spec["name"] if spec else f"Widget {idx + 1}"
                if any(x["name"] == name for x in inputs):
                    continue
                raw_value = input_overrides.get(name, widget_value)
                value_type = (
                    "bool" if isinstance(widget_value, bool)
                    else "int" if isinstance(widget_value, int) and not isinstance(widget_value, bool)
                    else "float" if isinstance(widget_value, float)
                    else "string"
                )
                inputs.append({
                    "name": name,
                    "value": _scalar_to_text(raw_value),
                    "value_type": value_type,
                    "options": spec.get("options", []) if spec else _input_options(class_type, name, object_info),
                    "connected_from": None,
                    "input_type": str(spec.get("type") if spec else value_type).upper(),
                    "slot": len(inputs),
                })

            raw_outputs = raw_node.get("outputs") if isinstance(raw_node.get("outputs"), list) else []
            outputs = []
            for slot, output in enumerate(raw_outputs):
                if isinstance(output, dict):
                    outputs.append({
                        "name": str(output.get("name") or output.get("type") or f"Output {slot + 1}"),
                        "type": str(output.get("type") or "*"),
                        "slot": slot,
                    })
            if not outputs:
                outputs = _object_outputs(class_type, object_info)

            nodes.append({
                "id": node_id,
                "title": title,
                "class_type": class_type,
                "color": color,
                "placement": placement,
                "width_mode": width_mode,
                "muted": muted,
                "inputs": inputs,
                "outputs": outputs,
                "position_x": x,
                "position_y": y,
                "node_width": node_width,
                "node_height": node_height,
            })

        for link in raw_links:
            if isinstance(link, list) and len(link) >= 5:
                target_id = str(link[3])
                target_node = next((n for n in nodes if n["id"] == target_id), None)
                to_slot = int(link[4])
                input_name = None
                if target_node and 0 <= to_slot < len(target_node.get("inputs") or []):
                    input_name = target_node["inputs"][to_slot]["name"]
                connections.append({
                    "from": str(link[1]),
                    "to": target_id,
                    "label": str(link[5]) if len(link) > 5 and link[5] is not None else None,
                    "from_slot": int(link[2]),
                    "to_slot": to_slot,
                    "input_name": input_name,
                    "type": str(link[5]) if len(link) > 5 and link[5] is not None else None,
                })
            elif isinstance(link, dict):
                origin = link.get("origin_id") or link.get("from")
                target = link.get("target_id") or link.get("to")
                if origin is not None and target is not None:
                    connections.append({
                        "from": str(origin), "to": str(target),
                        "label": str(link.get("type") or "") or None,
                        "from_slot": int(link.get("origin_slot") or 0),
                        "to_slot": int(link.get("target_slot") or 0),
                        "input_name": link.get("input_name"),
                        "type": str(link.get("type") or "") or None,
                    })

    if order:
        rank = {str(node_id): idx for idx, node_id in enumerate(order)}
        nodes.sort(key=lambda node: (rank.get(node["id"], 10**9), node["id"]))

    catalog = _workflow_catalog()
    item = next((x for x in catalog if x.get("id") == selected_id), None) or {}
    return {
        "ok": True,
        "workflow_id": selected_id,
        "name": item.get("name") or "Workflow",
        "format": fmt,
        "executable": bool(item.get("executable", fmt == "api")),
        "nodes": nodes,
        "connections": connections,
        "error": None,
    }

def _cast_override(original, text_value):
    if isinstance(original, bool):
        return str(text_value).strip().lower() in {"1", "true", "yes", "on", "да"}
    if isinstance(original, int) and not isinstance(original, bool):
        try:
            return int(float(str(text_value).strip()))
        except Exception:
            return original
    if isinstance(original, float):
        try:
            return float(str(text_value).strip().replace(",", "."))
        except Exception:
            return original
    if isinstance(original, str):
        return str(text_value)
    try:
        return json.loads(str(text_value))
    except Exception:
        return original


def _apply_editor_overrides(workflow_id, prompt):
    if not _is_api_workflow(prompt):
        return prompt
    state = _workflow_editor_state(workflow_id)
    node_state = state.get("nodes") if isinstance(state.get("nodes"), dict) else {}
    result = copy.deepcopy(prompt)
    for node_id, saved in node_state.items():
        if not isinstance(saved, dict):
            continue
        node = result.get(str(node_id))
        if not isinstance(node, dict):
            continue
        inputs = node.get("inputs")
        if not isinstance(inputs, dict):
            continue
        # Generic ComfyUI nodes do not share one universal bypass field. For
        # nodes that expose a conventional enable/bypass input, make the mobile
        # Mute switch affect execution; otherwise the muted state remains a
        # visual/editor marker and never rewires graph connections automatically.
        if bool(saved.get("muted", False)):
            if "enabled" in inputs and isinstance(inputs.get("enabled"), bool):
                inputs["enabled"] = False
            elif "active" in inputs and isinstance(inputs.get("active"), bool):
                inputs["active"] = False
            elif "bypass" in inputs and isinstance(inputs.get("bypass"), bool):
                inputs["bypass"] = True
        overrides = saved.get("inputs") if isinstance(saved.get("inputs"), dict) else {}
        for key, text_value in overrides.items():
            if key not in inputs:
                continue
            original = inputs[key]
            # Never replace graph connections through the mobile scalar editor.
            if isinstance(original, list) and len(original) >= 2 and isinstance(original[1], int):
                continue
            inputs[key] = _cast_override(original, text_value)
    return result



def _ui_scalar_widget_names(class_type, object_info=None):
    object_info = object_info if isinstance(object_info, dict) else _comfy_object_info()
    info = object_info.get(str(class_type), {}) if isinstance(object_info, dict) else {}
    input_info = info.get("input") if isinstance(info, dict) else {}
    names = []
    if isinstance(input_info, dict):
        for section in ("required", "optional"):
            values = input_info.get(section)
            if not isinstance(values, dict):
                continue
            for key, spec in values.items():
                first = spec[0] if isinstance(spec, list) and spec else None
                if isinstance(first, list) or str(first).upper() in {"INT", "FLOAT", "STRING", "BOOLEAN"}:
                    if key not in names:
                        names.append(key)
    return names


def _upload_userdata_at_path(rel_path, raw):
    clean = str(rel_path).replace("\\", "/").lstrip("/")
    for encoded in (urllib.parse.quote(clean, safe=""), urllib.parse.quote(clean, safe="/")):
        try:
            req = urllib.request.Request(
                _comfy_base() + "/userdata/" + encoded,
                data=raw,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=5) as response:
                response.read()
            return True
        except Exception:
            continue
    return False


def _persist_workflow_node_change(workflow_id, node_id, body):
    # Persist edits into imported files and, when possible, ComfyUI's own
    # userdata workflow file. History entries are immutable and therefore use
    # editor-state overlays only.
    selected_id, value = _load_workflow(workflow_id)
    if value is None:
        return False
    fmt = _workflow_format(value)
    changed = False
    object_info = _comfy_object_info()
    raw_inputs = body.get("inputs") if isinstance(body.get("inputs"), dict) else {}

    if fmt == "api":
        node = value.get(str(node_id)) if isinstance(value, dict) else None
        if isinstance(node, dict):
            title = body.get("title")
            if isinstance(title, str):
                meta = node.get("_meta") if isinstance(node.get("_meta"), dict) else {}
                meta["title"] = title
                node["_meta"] = meta
                changed = True
            inputs = node.get("inputs") if isinstance(node.get("inputs"), dict) else {}
            for key, text_value in raw_inputs.items():
                if key not in inputs:
                    continue
                original = inputs[key]
                if isinstance(original, list) and len(original) >= 2 and isinstance(original[1], int):
                    continue
                inputs[key] = _cast_override(original, text_value)
                changed = True

    elif fmt == "ui":
        raw_nodes = value.get("nodes") if isinstance(value.get("nodes"), list) else []
        node = next((x for x in raw_nodes if isinstance(x, dict) and str(x.get("id")) == str(node_id)), None)
        if isinstance(node, dict):
            if isinstance(body.get("title"), str):
                node["title"] = body.get("title")
                changed = True
            if isinstance(body.get("color"), str):
                node["color"] = body.get("color")
                changed = True
            if "muted" in body:
                # Current ComfyUI frontend/LiteGraph uses NEVER=2 for a muted
                # node and ALWAYS=0 for normal execution.
                node["mode"] = 2 if bool(body.get("muted")) else 0
                changed = True
            if "position_x" in body or "position_y" in body:
                old_pos = node.get("pos") if isinstance(node.get("pos"), list) and len(node.get("pos")) >= 2 else [0, 0]
                node["pos"] = [float(body.get("position_x", old_pos[0]) or 0), float(body.get("position_y", old_pos[1]) or 0)]
                changed = True
            if "node_width" in body or "node_height" in body:
                old_size = node.get("size") if isinstance(node.get("size"), list) and len(node.get("size")) >= 2 else [235, 175]
                node["size"] = [float(body.get("node_width", old_size[0]) or 235), float(body.get("node_height", old_size[1]) or 175)]
                changed = True
            widgets = node.get("widgets_values") if isinstance(node.get("widgets_values"), list) else None
            if widgets is not None and raw_inputs:
                names = _ui_scalar_widget_names(node.get("type") or node.get("class_type"), object_info)
                for idx, name in enumerate(names):
                    if idx >= len(widgets) or name not in raw_inputs:
                        continue
                    widgets[idx] = _cast_override(widgets[idx], raw_inputs[name])
                    changed = True

    if not changed:
        return False

    raw = json.dumps(value, ensure_ascii=False, indent=2).encode("utf-8")
    try:
        if selected_id.startswith("file:"):
            name = selected_id[5:]
            path = COMFY_WORKFLOW_DIR / Path(name).name
            path.write_bytes(raw)
        elif selected_id.startswith("userdata:"):
            rel = selected_id[len("userdata:"):]
            if not _upload_userdata_at_path(rel, raw):
                return False
        else:
            return False
        COMFY_CATALOG_CACHE["time"] = 0.0
        return True
    except Exception:
        return False


def _comfy_models(folder):
    try:
        value = _comfy_json("/models/" + urllib.parse.quote(folder, safe=""), timeout=4)
    except Exception:
        return []
    if isinstance(value, list):
        return [str(item) for item in value if isinstance(item, str)][:400]
    return []


def _comfy_sampler_options():
    samplers = []
    schedulers = []
    try:
        info = _comfy_json("/object_info/KSampler", timeout=4)
        node = info.get("KSampler", {}) if isinstance(info, dict) else {}
        required = ((node.get("input") or {}).get("required") or {}) if isinstance(node, dict) else {}
        sampler_value = required.get("sampler_name") if isinstance(required, dict) else None
        scheduler_value = required.get("scheduler") if isinstance(required, dict) else None
        if isinstance(sampler_value, list) and sampler_value and isinstance(sampler_value[0], list):
            samplers = [str(x) for x in sampler_value[0]]
        if isinstance(scheduler_value, list) and scheduler_value and isinstance(scheduler_value[0], list):
            schedulers = [str(x) for x in scheduler_value[0]]
    except Exception:
        pass
    return samplers[:120], schedulers[:120]


def _recent_comfy_images(limit=12):
    images = []
    for prompt_id, entry in _history_entries(limit=12):
        outputs = entry.get("outputs", {}) if isinstance(entry, dict) else {}
        if not isinstance(outputs, dict):
            continue
        for node_output in outputs.values():
            if not isinstance(node_output, dict):
                continue
            for item in node_output.get("images", []) if isinstance(node_output.get("images"), list) else []:
                if not isinstance(item, dict) or not item.get("filename"):
                    continue
                filename = str(item.get("filename", ""))
                subfolder = str(item.get("subfolder", ""))
                folder_type = str(item.get("type", "output"))
                images.append({
                    "id": f"{prompt_id}|{folder_type}|{subfolder}|{filename}",
                    "filename": filename,
                    "subfolder": subfolder,
                    "type": folder_type,
                    "prompt_id": prompt_id,
                })
                if len(images) >= limit:
                    return images
    return images


def _comfy_system_label(system_stats):
    gpu = None
    vram = None
    if isinstance(system_stats, dict):
        devices = system_stats.get("devices")
        if isinstance(devices, list) and devices:
            device = devices[0]
            if isinstance(device, dict):
                gpu = str(device.get("name") or device.get("type") or "GPU")
                try:
                    total = float(device.get("vram_total", 0) or 0)
                    free = float(device.get("vram_free", 0) or 0)
                    if total > 0:
                        used = max(0.0, total - free)
                        vram = f"{used / (1024**3):.1f}/{total / (1024**3):.1f} GB"
                except Exception:
                    pass
    return gpu, vram




def _comfy_system_metrics(system_stats=None):
    vm = psutil.virtual_memory()
    result = {
        "cpu_percent": float(psutil.cpu_percent(interval=None)),
        "ram_used_gb": round(float(vm.used) / (1024 ** 3), 1),
        "ram_total_gb": round(float(vm.total) / (1024 ** 3), 1),
        "gpu_percent": None,
        "gpu_temperature": None,
        "gpu_name": None,
        "vram_used_gb": None,
        "vram_total_gb": None,
    }

    # NVIDIA is the primary GPU in this PC Remote setup. nvidia-smi gives the
    # most useful live values; ComfyUI /system_stats remains the fallback.
    try:
        creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        completed = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=name,utilization.gpu,temperature.gpu,memory.used,memory.total",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=1.8,
            creationflags=creationflags,
        )
        line = (completed.stdout or "").splitlines()[0]
        parts = [x.strip() for x in line.split(",")]
        if len(parts) >= 5:
            result["gpu_name"] = parts[0]
            result["gpu_percent"] = float(parts[1])
            result["gpu_temperature"] = float(parts[2])
            result["vram_used_gb"] = round(float(parts[3]) / 1024.0, 1)
            result["vram_total_gb"] = round(float(parts[4]) / 1024.0, 1)
            return result
    except Exception:
        pass

    if isinstance(system_stats, dict):
        devices = system_stats.get("devices")
        if isinstance(devices, list) and devices and isinstance(devices[0], dict):
            device = devices[0]
            result["gpu_name"] = str(device.get("name") or device.get("type") or "GPU")
            try:
                total = float(device.get("vram_total", 0) or 0)
                free = float(device.get("vram_free", 0) or 0)
                if total > 0:
                    result["vram_total_gb"] = round(total / (1024 ** 3), 1)
                    result["vram_used_gb"] = round(max(0.0, total - free) / (1024 ** 3), 1)
            except Exception:
                pass
    return result


def _detect_model_profile(workflow):
    if not isinstance(workflow, dict):
        return "generic", "image"
    try:
        blob = json.dumps(workflow, ensure_ascii=False).lower()
    except Exception:
        blob = str(workflow).lower()

    if any(token in blob for token in ("wan2.1", "wan2.2", "wanvideo", "wan_video", "wan video", "wanvace", "wan vace")):
        return "wan", "video"
    if any(token in blob for token in ("z-image", "z_image", "zimage", "z image")):
        return "zimage", "image"
    if any(token in blob for token in ("video", "frames", "frame_count", "vhs_", "videocombine", "image to video", "text to video")):
        return "generic_video", "video"
    return "generic_image", "image"


def _save_loaded_workflow(workflow_id, value):
    raw = json.dumps(value, ensure_ascii=False, indent=2).encode("utf-8")
    if workflow_id.startswith("file:"):
        path = COMFY_WORKFLOW_DIR / Path(workflow_id[5:]).name
        path.write_bytes(raw)
    elif workflow_id.startswith("userdata:"):
        rel = workflow_id[len("userdata:"):]
        if not _upload_userdata_at_path(rel, raw):
            return False
    else:
        return False
    COMFY_CATALOG_CACHE["time"] = 0.0
    COMFY_CATALOG_CACHE["value"] = []
    return True


def _next_workflow_node_id(value, fmt):
    ids = []
    if fmt == "api" and isinstance(value, dict):
        ids = list(value.keys())
    elif fmt == "ui" and isinstance(value, dict):
        ids = [x.get("id") for x in (value.get("nodes") or []) if isinstance(x, dict)]
    numeric = []
    for item in ids:
        try:
            numeric.append(int(item))
        except Exception:
            pass
    return str(max(numeric, default=0) + 1)


def _catalog_node_item(class_type, info, object_info):
    display = str(info.get("display_name") or info.get("name") or class_type)
    category = str(info.get("category") or "Other")
    recommended_types = {
        "CheckpointLoaderSimple", "LoraLoader", "LoadImage", "CLIPTextEncode",
        "KSampler", "KSamplerAdvanced", "EmptyLatentImage", "VAEDecode",
        "VAEEncode", "VAELoader", "SaveImage", "PreviewImage",
    }
    inputs = []
    for spec in _object_input_specs(class_type, object_info):
        default = spec.get("default")
        value_type = "string"
        if isinstance(default, bool): value_type = "bool"
        elif isinstance(default, int) and not isinstance(default, bool): value_type = "int"
        elif isinstance(default, float): value_type = "float"
        elif not spec.get("scalar"): value_type = "connection"
        inputs.append({
            "name": spec["name"],
            "value": _scalar_to_text(default),
            "value_type": value_type,
            "options": spec.get("options") or [],
            "connected_from": None,
            "input_type": spec.get("type") or "*",
            "slot": spec.get("slot") or 0,
        })
    return {
        "id": class_type,
        "class_type": class_type,
        "display_name": display,
        "category": category,
        "recommended": class_type in recommended_types,
        "inputs": inputs,
        "outputs": _object_outputs(class_type, object_info),
    }


def _create_node_in_workflow(workflow_id, class_type, x, y):
    selected_id, value = _load_workflow(workflow_id)
    if value is None:
        raise ValueError("Workflow не найден.")
    fmt = _workflow_format(value)
    if selected_id.startswith("history:"):
        raise ValueError("Workflow из истории сначала сохраните или импортируйте, чтобы менять структуру.")
    object_info = _comfy_object_info()
    info = object_info.get(class_type)
    if not isinstance(info, dict):
        raise ValueError("Такая нода не найдена в установленном ComfyUI.")
    node_id = _next_workflow_node_id(value, fmt)
    specs = _object_input_specs(class_type, object_info)
    display = str(info.get("display_name") or class_type)

    if fmt == "api":
        inputs = {}
        for spec in specs:
            if spec.get("scalar"):
                inputs[spec["name"]] = spec.get("default")
        value[node_id] = {"class_type": class_type, "inputs": inputs, "_meta": {"title": display}}
    elif fmt == "ui":
        numeric_id = int(node_id)
        input_defs = []
        widget_values = []
        for spec in specs:
            if spec.get("scalar"):
                widget_values.append(spec.get("default"))
            else:
                input_defs.append({"name": spec["name"], "type": spec.get("type") or "*", "link": None})
        output_defs = [
            {"name": out["name"], "type": out["type"], "links": None}
            for out in _object_outputs(class_type, object_info)
        ]
        raw_nodes = value.setdefault("nodes", [])
        order = max([int(n.get("order", 0) or 0) for n in raw_nodes if isinstance(n, dict)] + [0]) + 1
        raw_nodes.append({
            "id": numeric_id,
            "type": class_type,
            "pos": [float(x), float(y)],
            "size": [235, 175],
            "flags": {},
            "order": order,
            "mode": 0,
            "inputs": input_defs,
            "outputs": output_defs,
            "properties": {"Node name for S&R": class_type},
            "widgets_values": widget_values,
            "title": display,
        })
        value["last_node_id"] = max(int(value.get("last_node_id") or 0), numeric_id)
    else:
        raise ValueError("Неподдерживаемый формат workflow.")

    if not _save_loaded_workflow(selected_id, value):
        raise ValueError("Не удалось сохранить workflow.")

    def mutate(state):
        nodes = state.get("nodes") if isinstance(state.get("nodes"), dict) else {}
        saved = nodes.get(node_id) if isinstance(nodes.get(node_id), dict) else {}
        saved.update({"position_x": float(x), "position_y": float(y), "node_width": 235.0, "node_height": 175.0})
        nodes[node_id] = saved
        state["nodes"] = nodes
    _update_workflow_editor_state(selected_id, mutate)
    details = _workflow_details(selected_id)
    node = next((n for n in details.get("nodes", []) if n.get("id") == node_id), None) if details else None
    return node


def _delete_node_from_workflow(workflow_id, node_id):
    selected_id, value = _load_workflow(workflow_id)
    if value is None:
        raise ValueError("Workflow не найден.")
    if selected_id.startswith("history:"):
        raise ValueError("Workflow из истории сначала сохраните или импортируйте.")
    fmt = _workflow_format(value)
    if fmt == "api":
        value.pop(str(node_id), None)
        for node in value.values():
            if not isinstance(node, dict) or not isinstance(node.get("inputs"), dict):
                continue
            for key in list(node["inputs"].keys()):
                raw = node["inputs"].get(key)
                if isinstance(raw, list) and raw and str(raw[0]) == str(node_id):
                    node["inputs"].pop(key, None)
    elif fmt == "ui":
        raw_nodes = value.get("nodes") if isinstance(value.get("nodes"), list) else []
        raw_links = value.get("links") if isinstance(value.get("links"), list) else []
        removed_link_ids = set()
        kept_links = []
        for link in raw_links:
            if isinstance(link, list) and len(link) >= 5 and (str(link[1]) == str(node_id) or str(link[3]) == str(node_id)):
                removed_link_ids.add(link[0])
            else:
                kept_links.append(link)
        value["links"] = kept_links
        value["nodes"] = [n for n in raw_nodes if not (isinstance(n, dict) and str(n.get("id")) == str(node_id))]
        for node in value["nodes"]:
            if not isinstance(node, dict): continue
            for entry in node.get("inputs") or []:
                if isinstance(entry, dict) and entry.get("link") in removed_link_ids:
                    entry["link"] = None
            for output in node.get("outputs") or []:
                if isinstance(output, dict) and isinstance(output.get("links"), list):
                    links = [x for x in output["links"] if x not in removed_link_ids]
                    output["links"] = links or None
    else:
        raise ValueError("Неподдерживаемый формат workflow.")
    if not _save_loaded_workflow(selected_id, value):
        raise ValueError("Не удалось сохранить workflow.")
    def mutate(state):
        nodes = state.get("nodes") if isinstance(state.get("nodes"), dict) else {}
        nodes.pop(str(node_id), None)
        state["nodes"] = nodes
    _update_workflow_editor_state(selected_id, mutate)


def _connect_workflow_nodes(workflow_id, from_node, from_slot, to_node, to_input, to_slot):
    selected_id, value = _load_workflow(workflow_id)
    if value is None:
        raise ValueError("Workflow не найден.")
    if selected_id.startswith("history:"):
        raise ValueError("Workflow из истории сначала сохраните или импортируйте.")
    fmt = _workflow_format(value)
    if fmt == "api":
        target = value.get(str(to_node))
        if not isinstance(target, dict): raise ValueError("Целевая нода не найдена.")
        inputs = target.setdefault("inputs", {})
        inputs[str(to_input)] = [str(from_node), int(from_slot)]
    elif fmt == "ui":
        raw_nodes = value.get("nodes") if isinstance(value.get("nodes"), list) else []
        source = next((n for n in raw_nodes if isinstance(n, dict) and str(n.get("id")) == str(from_node)), None)
        target = next((n for n in raw_nodes if isinstance(n, dict) and str(n.get("id")) == str(to_node)), None)
        if source is None or target is None: raise ValueError("Нода не найдена.")
        target_inputs = target.get("inputs") if isinstance(target.get("inputs"), list) else []
        if not (0 <= int(to_slot) < len(target_inputs)):
            match = next((i for i, x in enumerate(target_inputs) if isinstance(x, dict) and str(x.get("name")) == str(to_input)), None)
            if match is None: raise ValueError("Вход ноды не найден.")
            to_slot = match
        # Remove an existing link on this target input first.
        existing = target_inputs[int(to_slot)].get("link") if isinstance(target_inputs[int(to_slot)], dict) else None
        if existing is not None:
            _disconnect_ui_link(value, target, int(to_slot), existing)
        links = value.setdefault("links", [])
        link_id = max([int(x[0]) for x in links if isinstance(x, list) and x and isinstance(x[0], int)] + [0]) + 1
        source_outputs = source.get("outputs") if isinstance(source.get("outputs"), list) else []
        if not (0 <= int(from_slot) < len(source_outputs)):
            raise ValueError("Выход ноды не найден.")
        out = source_outputs[int(from_slot)]
        link_type = str((out or {}).get("type") or (target_inputs[int(to_slot)] or {}).get("type") or "*")
        links.append([link_id, int(source.get("id")), int(from_slot), int(target.get("id")), int(to_slot), link_type])
        current = out.get("links") if isinstance(out, dict) and isinstance(out.get("links"), list) else []
        out["links"] = current + [link_id]
        target_inputs[int(to_slot)]["link"] = link_id
        value["last_link_id"] = max(int(value.get("last_link_id") or 0), link_id)
    else:
        raise ValueError("Неподдерживаемый формат workflow.")
    if not _save_loaded_workflow(selected_id, value):
        raise ValueError("Не удалось сохранить соединение.")


def _disconnect_ui_link(value, target, to_slot, link_id):
    links = value.get("links") if isinstance(value.get("links"), list) else []
    link = next((x for x in links if isinstance(x, list) and x and x[0] == link_id), None)
    value["links"] = [x for x in links if not (isinstance(x, list) and x and x[0] == link_id)]
    target_inputs = target.get("inputs") if isinstance(target.get("inputs"), list) else []
    if 0 <= to_slot < len(target_inputs) and isinstance(target_inputs[to_slot], dict):
        target_inputs[to_slot]["link"] = None
    if isinstance(link, list) and len(link) >= 3:
        raw_nodes = value.get("nodes") if isinstance(value.get("nodes"), list) else []
        source = next((n for n in raw_nodes if isinstance(n, dict) and str(n.get("id")) == str(link[1])), None)
        outputs = source.get("outputs") if isinstance(source, dict) and isinstance(source.get("outputs"), list) else []
        slot = int(link[2])
        if 0 <= slot < len(outputs) and isinstance(outputs[slot], dict) and isinstance(outputs[slot].get("links"), list):
            remain = [x for x in outputs[slot]["links"] if x != link_id]
            outputs[slot]["links"] = remain or None


def _disconnect_workflow_input(workflow_id, to_node, to_input):
    selected_id, value = _load_workflow(workflow_id)
    if value is None:
        raise ValueError("Workflow не найден.")
    if selected_id.startswith("history:"):
        raise ValueError("Workflow из истории сначала сохраните или импортируйте.")
    fmt = _workflow_format(value)
    if fmt == "api":
        target = value.get(str(to_node))
        if not isinstance(target, dict) or not isinstance(target.get("inputs"), dict):
            raise ValueError("Нода не найдена.")
        target["inputs"].pop(str(to_input), None)
    elif fmt == "ui":
        raw_nodes = value.get("nodes") if isinstance(value.get("nodes"), list) else []
        target = next((n for n in raw_nodes if isinstance(n, dict) and str(n.get("id")) == str(to_node)), None)
        if target is None: raise ValueError("Нода не найдена.")
        target_inputs = target.get("inputs") if isinstance(target.get("inputs"), list) else []
        slot = next((i for i, x in enumerate(target_inputs) if isinstance(x, dict) and str(x.get("name")) == str(to_input)), None)
        if slot is None: raise ValueError("Вход не найден.")
        link_id = target_inputs[slot].get("link")
        if link_id is not None:
            _disconnect_ui_link(value, target, slot, link_id)
    else:
        raise ValueError("Неподдерживаемый формат workflow.")
    if not _save_loaded_workflow(selected_id, value):
        raise ValueError("Не удалось сохранить изменение.")


@app.get("/api/comfy/nodes/catalog")
def comfy_nodes_catalog():
    query = str(request.args.get("q", "") or "").strip().lower()
    object_info = _comfy_object_info()
    items = []
    for class_type, info in object_info.items() if isinstance(object_info, dict) else []:
        if not isinstance(info, dict):
            continue
        item = _catalog_node_item(str(class_type), info, object_info)
        haystack = " ".join((item["class_type"], item["display_name"], item["category"])).lower()
        if query and query not in haystack:
            # Simple token-prefix matching makes `lo` find Load LoRA, Load Image, etc.
            tokens = haystack.replace("/", " ").replace("_", " ").split()
            if not any(token.startswith(query) for token in tokens):
                continue
        items.append(item)
    items.sort(key=lambda x: (not x["recommended"], x["category"].lower(), x["display_name"].lower()))
    return jsonify({"ok": True, "nodes": items[:160], "error": None})


@app.post("/api/comfy/workflow/node/add")
def comfy_workflow_node_add():
    body = request.get_json(silent=True) or {}
    try:
        node = _create_node_in_workflow(
            str(body.get("workflow_id") or ""),
            str(body.get("class_type") or ""),
            float(body.get("position_x") or 320),
            float(body.get("position_y") or 260),
        )
        return jsonify({"ok": True, "node": node, "error": None})
    except Exception as exc:
        return jsonify({"ok": False, "node": None, "error": str(exc)}), 400


@app.post("/api/comfy/workflow/node/delete")
def comfy_workflow_node_delete():
    body = request.get_json(silent=True) or {}
    try:
        _delete_node_from_workflow(str(body.get("workflow_id") or ""), str(body.get("node_id") or ""))
        return jsonify({"ok": True, "error": None})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


@app.post("/api/comfy/workflow/connect")
def comfy_workflow_connect():
    body = request.get_json(silent=True) or {}
    try:
        _connect_workflow_nodes(
            str(body.get("workflow_id") or ""),
            str(body.get("from_node") or ""),
            int(body.get("from_slot") or 0),
            str(body.get("to_node") or ""),
            str(body.get("to_input") or ""),
            int(body.get("to_slot") or 0),
        )
        return jsonify({"ok": True, "error": None})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


@app.post("/api/comfy/workflow/disconnect")
def comfy_workflow_disconnect():
    body = request.get_json(silent=True) or {}
    try:
        _disconnect_workflow_input(
            str(body.get("workflow_id") or ""),
            str(body.get("to_node") or ""),
            str(body.get("to_input") or ""),
        )
        return jsonify({"ok": True, "error": None})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


@app.get("/api/comfy/dashboard")
def comfy_dashboard():
    ensure_comfy_ws_thread()
    if not _comfy_available():
        _set_comfy_state(connected=False, running=False)
        return jsonify({
            "ok": True, "available": False,
            "message": "ComfyUI не отвечает на 127.0.0.1:8188.",
            "running": False, "progress": 0.0, "queue_remaining": 0,
            "current_node": None, "prompt_id": None, "error": None,
            "workflows": [], "selected_workflow": None,
            "parameters": _extract_workflow_parameters({}),
            "checkpoints": [], "loras": [], "vaes": [], "samplers": [], "schedulers": [],
            "images": [], "gpu": None, "vram": None,
            "system": _comfy_system_metrics({}), "model_profile": "generic", "media_type": "image",
        })

    state = _comfy_state_copy()
    try:
        queue = _comfy_json("/queue", timeout=3)
        running_items = queue.get("queue_running", []) if isinstance(queue, dict) else []
        pending_items = queue.get("queue_pending", []) if isinstance(queue, dict) else []
        queue_remaining = len(running_items) + len(pending_items)
        if queue_remaining:
            state["running"] = bool(running_items) or state.get("running", False)
        state["queue_remaining"] = queue_remaining
        _set_comfy_state(connected=True, running=state.get("running", False), queue_remaining=queue_remaining)
    except Exception:
        pass

    catalog = _workflow_catalog()
    requested = str(request.args.get("workflow_id", "") or "")
    selected_id, prompt = _load_workflow(requested)
    if prompt is None and catalog:
        selected_id, prompt = _load_workflow(catalog[0]["id"])
    parameters = _extract_workflow_parameters(prompt or {})

    checkpoints = _comfy_models("checkpoints")
    loras = _comfy_models("loras")
    vaes = _comfy_models("vae")
    samplers, schedulers = _comfy_sampler_options()
    try:
        system_stats = _comfy_json("/system_stats", timeout=3)
    except Exception:
        system_stats = {}
    gpu, vram = _comfy_system_label(system_stats)
    system = _comfy_system_metrics(system_stats)
    profile_prompt = _apply_editor_overrides(selected_id, prompt) if selected_id and _is_api_workflow(prompt) else (prompt or {})
    model_profile, media_type = _detect_model_profile(profile_prompt)

    state = _comfy_state_copy()
    return jsonify({
        "ok": True, "available": True, "message": None,
        "running": bool(state.get("running")),
        "progress": float(state.get("progress") or 0.0),
        "queue_remaining": int(state.get("queue_remaining") or 0),
        "current_node": state.get("current_node"),
        "prompt_id": state.get("prompt_id"),
        "error": state.get("error"),
        "workflows": catalog,
        "selected_workflow": selected_id,
        "parameters": parameters,
        "checkpoints": checkpoints, "loras": loras, "vaes": vaes,
        "samplers": samplers, "schedulers": schedulers,
        "images": _recent_comfy_images(limit=12),
        "gpu": gpu, "vram": vram,
        "system": system, "model_profile": model_profile, "media_type": media_type,
    })



@app.get("/api/comfy/workflow/details")
def comfy_workflow_details():
    workflow_id = str(request.args.get("workflow_id", "") or "")
    details = _workflow_details(workflow_id)
    if details is None:
        return jsonify({"ok": False, "workflow_id": workflow_id, "name": "", "format": "unknown", "executable": False, "nodes": [], "connections": [], "error": "Workflow не найден."}), 404
    return jsonify(details)


@app.post("/api/comfy/workflow/node/update")
def comfy_workflow_node_update():
    body = request.get_json(silent=True) or {}
    workflow_id = str(body.get("workflow_id", "") or "")
    node_id = str(body.get("node_id", "") or "")
    if not workflow_id or not node_id:
        return jsonify({"ok": False, "error": "Не указан workflow или node."}), 400

    def mutate(state):
        nodes = state.get("nodes")
        if not isinstance(nodes, dict):
            nodes = {}
        saved = nodes.get(node_id)
        if not isinstance(saved, dict):
            saved = {}
        for key in ("title", "color", "placement", "width_mode", "muted", "position_x", "position_y", "node_width", "node_height"):
            if key in body:
                saved[key] = body.get(key)
        raw_inputs = body.get("inputs")
        if isinstance(raw_inputs, dict):
            clean_inputs = {}
            for k, v in raw_inputs.items():
                if isinstance(k, str) and isinstance(v, (str, int, float, bool)):
                    clean_inputs[k] = str(v)
            saved["inputs"] = clean_inputs
        nodes[node_id] = saved
        state["nodes"] = nodes

    _update_workflow_editor_state(workflow_id, mutate)
    _persist_workflow_node_change(workflow_id, node_id, body)
    return jsonify({"ok": True, "error": None})


@app.post("/api/comfy/workflow/order")
def comfy_workflow_order():
    body = request.get_json(silent=True) or {}
    workflow_id = str(body.get("workflow_id", "") or "")
    order = body.get("order")
    if not workflow_id or not isinstance(order, list):
        return jsonify({"ok": False, "error": "Некорректный порядок нод."}), 400
    clean = [str(x) for x in order if isinstance(x, (str, int))][:1000]

    def mutate(state):
        state["order"] = clean

    _update_workflow_editor_state(workflow_id, mutate)
    return jsonify({"ok": True, "error": None})


@app.post("/api/comfy/workflows/import")
def comfy_workflow_import():
    body = request.get_json(silent=True) or {}
    filename = str(body.get("filename", "") or "workflow.json")
    raw = None

    pc_path = body.get("path")
    if isinstance(pc_path, str) and pc_path.strip():
        p = safe_path(pc_path)
        if p is None or not p.is_file() or p.suffix.lower() != ".json":
            return jsonify({"ok": False, "error": "Выберите JSON workflow на ПК.", "workflow": None}), 400
        if p.stat().st_size > 12 * 1024 * 1024:
            return jsonify({"ok": False, "error": "Workflow слишком большой.", "workflow": None}), 413
        raw = p.read_bytes()
        filename = p.name
    else:
        encoded = body.get("content_base64")
        if not isinstance(encoded, str) or not encoded:
            return jsonify({"ok": False, "error": "Файл не передан.", "workflow": None}), 400
        try:
            raw = base64.b64decode(encoded, validate=True)
        except Exception:
            return jsonify({"ok": False, "error": "Не удалось прочитать файл.", "workflow": None}), 400
        if len(raw) > 12 * 1024 * 1024:
            return jsonify({"ok": False, "error": "Workflow слишком большой.", "workflow": None}), 413

    try:
        value = json.loads(raw.decode("utf-8-sig"))
    except Exception:
        return jsonify({"ok": False, "error": "Это не JSON workflow.", "workflow": None}), 400

    fmt = _workflow_format(value)
    if fmt == "unknown":
        return jsonify({"ok": False, "error": "JSON не похож на workflow ComfyUI.", "workflow": None}), 400

    safe_name = _safe_workflow_filename(filename)
    destination = COMFY_WORKFLOW_DIR / safe_name
    if destination.exists():
        stem, suffix = destination.stem, destination.suffix
        for idx in range(2, 1000):
            candidate = COMFY_WORKFLOW_DIR / f"{stem} {idx}{suffix}"
            if not candidate.exists():
                destination = candidate
                safe_name = candidate.name
                break

    normalized = json.dumps(value, ensure_ascii=False, indent=2).encode("utf-8")
    destination.write_bytes(normalized)
    _try_upload_comfy_userdata(safe_name, normalized)
    COMFY_CATALOG_CACHE["time"] = 0.0
    COMFY_CATALOG_CACHE["value"] = []

    workflow_id = "file:" + safe_name
    catalog = _workflow_catalog(force=True)
    item = next((x for x in catalog if x.get("id") == workflow_id), None)
    return jsonify({"ok": True, "error": None, "workflow": item})


@app.post("/api/comfy/generate")
def comfy_generate():
    ensure_comfy_ws_thread()
    body = request.get_json(silent=True) or {}
    workflow_id = str(body.get("workflow_id", "") or "")
    selected_id, prompt = _load_workflow(workflow_id)
    if prompt is None or not _is_api_workflow(prompt):
        return jsonify({"ok": False, "prompt_id": None, "error": "Этот workflow доступен для просмотра/редактирования, но для запуска нужен API-format workflow."}), 400
    params = body.get("parameters") if isinstance(body.get("parameters"), dict) else {}
    try:
        prompt = _apply_workflow_parameters(prompt, params)
        prompt = _apply_editor_overrides(selected_id, prompt)
        payload = {"prompt": prompt, "client_id": COMFY_CLIENT_ID}
        response = _comfy_json("/prompt", method="POST", payload=payload, timeout=10)
        prompt_id = str(response.get("prompt_id", "")) if isinstance(response, dict) else ""
        if not prompt_id:
            raise RuntimeError("ComfyUI не вернул prompt_id")
        _set_comfy_state(connected=True, running=True, progress=0.0, prompt_id=prompt_id, current_node=None, error=None)
        return jsonify({"ok": True, "prompt_id": prompt_id, "error": None, "workflow_id": selected_id})
    except urllib.error.HTTPError as exc:
        try:
            detail = exc.read().decode("utf-8", errors="replace")
        except Exception:
            detail = str(exc)
        return jsonify({"ok": False, "prompt_id": None, "error": f"ComfyUI HTTP {exc.code}: {detail[:800]}"}), 502
    except Exception as exc:
        return jsonify({"ok": False, "prompt_id": None, "error": str(exc)}), 502


@app.post("/api/comfy/interrupt")
def comfy_interrupt():
    try:
        _comfy_json("/interrupt", method="POST", payload={}, timeout=5)
        _set_comfy_state(running=False, error="Генерация остановлена")
        return jsonify({"ok": True, "error": None})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 502


@app.post("/api/comfy/queue/clear")
def comfy_queue_clear():
    try:
        _comfy_json("/queue", method="POST", payload={"clear": True}, timeout=5)
        return jsonify({"ok": True, "error": None})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 502


@app.get("/api/comfy/image")
def comfy_image():
    filename = str(request.args.get("filename", "") or "")
    subfolder = str(request.args.get("subfolder", "") or "")
    folder_type = str(request.args.get("type", "output") or "output")
    if not filename or len(filename) > 400 or len(subfolder) > 600:
        abort(400)
    query = {"filename": filename, "subfolder": subfolder, "type": folder_type}
    try:
        req = urllib.request.Request(_comfy_http_url("/view", query), headers={"Accept": "image/*"})
        with urllib.request.urlopen(req, timeout=15) as response:
            data = response.read()
            content_type = response.headers.get_content_type() or "image/png"
        return Response(data, mimetype=content_type, headers={"Cache-Control": "private, max-age=30"})
    except urllib.error.HTTPError as exc:
        abort(exc.code if exc.code in (404, 403) else 502)
    except Exception:
        abort(502)


@app.post("/api/comfy/open/ui")
def comfy_open_ui():
    try:
        if os.name == "nt":
            os.startfile(_comfy_base())
        else:
            subprocess.Popen(["xdg-open", _comfy_base()])
        return jsonify({"ok": True, "error": None})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500


@app.post("/api/comfy/image/open")
def comfy_image_open():
    body = request.get_json(silent=True) or {}
    filename = str(body.get("filename", "") or "")
    subfolder = str(body.get("subfolder", "") or "")
    folder_type = str(body.get("type", "output") or "output")
    if not filename:
        abort(400)
    url = _comfy_http_url("/view", {"filename": filename, "subfolder": subfolder, "type": folder_type})
    try:
        if os.name == "nt":
            os.startfile(url)
        else:
            subprocess.Popen(["xdg-open", url])
        return jsonify({"ok": True, "error": None})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500



# ---------------------------------------------------------------------------
# CorelDRAW native integration
# ---------------------------------------------------------------------------

@app.post("/api/corel/launch")
def corel_launch():
    try:
        return jsonify(COREL.call("launch"))
    except CorelBridgeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 502


@app.get("/api/corel/status")
def corel_status():
    try:
        return jsonify(COREL.call("status"))
    except CorelBridgeError as exc:
        return jsonify({
            "ok": False,
            "running": False,
            "document_open": False,
            "document_name": "CorelDRAW",
            "document_path": "",
            "dirty": False,
            "page_index": 0,
            "page_count": 0,
            "selection_count": 0,
            "selection": None,
            "version": "",
            "error": str(exc),
        }), 200


@app.get("/api/corel/preview")
def corel_preview():
    try:
        path = COREL.call("preview")
        return send_file(path, mimetype="image/png", conditional=False, max_age=0)
    except CorelBridgeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 502


@app.get("/api/corel/objects")
def corel_objects():
    try:
        return jsonify(COREL.call("objects"))
    except CorelBridgeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 502


@app.post("/api/corel/new")
def corel_new_document():
    try:
        return jsonify(COREL.call("new"))
    except CorelBridgeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 502


@app.post("/api/corel/open")
def corel_open_document():
    body = request.get_json(silent=True) or {}
    raw_path = str(body.get("path", "") or "")
    p = safe_path(raw_path)
    if p is None or not p.is_file():
        return jsonify({"ok": False, "error": "Файл не найден."}), 404
    if p.suffix.lower() not in {".cdr", ".cdt", ".cmx", ".svg", ".pdf", ".ai", ".eps"}:
        return jsonify({"ok": False, "error": "Этот формат не поддерживается модулем CorelDRAW."}), 400
    try:
        return jsonify(COREL.call("open", path=str(p)))
    except CorelBridgeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 502


@app.post("/api/corel/action")
def corel_action():
    body = request.get_json(silent=True) or {}
    try:
        return jsonify(COREL.call("action", action=str(body.get("action", ""))))
    except CorelBridgeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 502


@app.post("/api/corel/select")
def corel_select():
    body = request.get_json(silent=True) or {}
    try:
        return jsonify(COREL.call("select", index=int(body.get("index", 0))))
    except (CorelBridgeError, ValueError, TypeError) as exc:
        return jsonify({"ok": False, "error": str(exc)}), 502


@app.post("/api/corel/transform")
def corel_transform():
    body = request.get_json(silent=True) or {}
    try:
        return jsonify(COREL.call(
            "transform",
            x=body.get("x"),
            y=body.get("y"),
            width=body.get("width"),
            height=body.get("height"),
            rotation=body.get("rotation"),
            keep_ratio=bool(body.get("keep_ratio", True)),
        ))
    except CorelBridgeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 502


@app.post("/api/corel/style")
def corel_style():
    body = request.get_json(silent=True) or {}
    try:
        return jsonify(COREL.call(
            "style",
            fill=body.get("fill"),
            outline=body.get("outline"),
            outline_width=body.get("outline_width"),
        ))
    except CorelBridgeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 502


@app.post("/api/corel/create")
def corel_create():
    body = request.get_json(silent=True) or {}
    try:
        return jsonify(COREL.call(
            "create",
            kind=str(body.get("kind", "")),
            text=str(body.get("text", "Текст")),
        ))
    except CorelBridgeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 502


@app.post("/api/corel/page")
def corel_page():
    body = request.get_json(silent=True) or {}
    try:
        return jsonify(COREL.call(
            "page",
            action=str(body.get("action", "")),
            index=body.get("index"),
        ))
    except CorelBridgeError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 502


def _status_payload():
    ip, mac, broadcast = _network_identity()
    tail_ip, tail_dns, tail_online = _tailscale_identity()
    zero_ip, zero_online = _zerotier_identity()
    return {
        "ok": True,
        "computer": socket.gethostname(),
        "ip": ip,
        "port": int(CONFIG["port"]),
        "locked": is_windows_locked(),
        "mac": mac,
        "broadcast": broadcast,
        "tailscale_ip": tail_ip,
        "tailscale_dns": tail_dns,
        "tailscale_online": tail_online,
        "zerotier_ip": zero_ip,
        "zerotier_online": zero_online,
        "transport": _request_transport(),
        "server_version": PCREMOTE_VERSION,
    }


@app.get("/api/ping")
def ping():
    return jsonify({
        "ok": True,
        "computer": socket.gethostname(),
        "port": int(CONFIG["port"]),
        "transport": _request_transport(),
        "server_version": PCREMOTE_VERSION,
        "password_set": password_is_set(),
    })


@app.post("/api/auth/login")
def auth_login():
    if not password_is_set():
        return jsonify({"ok": False, "error": "На PC Remote Server ещё не задан пароль подключения."}), 409
    body = request.get_json(silent=True) or {}
    password = str(body.get("password", "") or "")
    if not verify_connection_password(password):
        # Small delay makes repeated guessing materially slower without affecting normal login.
        time.sleep(0.18)
        return jsonify({"ok": False, "error": "Неверный пароль."}), 401
    return jsonify({"ok": True, "token": CONFIG["token"], "status": _status_payload(), "error": None})


@app.get("/api/status")
def status():
    return jsonify(_status_payload())


@app.get("/api/apps/desktop")
def desktop_apps():
    return jsonify(cached_scan("desktop"))


@app.get("/api/apps/all")
def all_apps():
    return jsonify(cached_scan("all"))


@app.get("/api/apps/recent")
def apps_recent():
    return jsonify(recent_apps())


@app.get("/api/apps")
def apps_compat():
    return jsonify(cached_scan("all"))


@app.get("/api/apps/icon")
def app_icon():
    app_id = request.args.get("id", "")
    item = next((x for x in all_known_apps() if x["id"] == app_id), None)
    if item is None:
        cached_scan("all", force=True)
        item = next((x for x in all_known_apps() if x["id"] == app_id), None)
    if item is None:
        abort(404)
    source = safe_path(app_id)
    if source is None:
        abort(404)
    # Batch launchers usually expose only the generic Windows script icon.
    # For recognized integrations such as ComfyUI, let the iPhone render its
    # crisp vector fallback instead of showing a low-quality gear/script icon.
    if item.get("integration") == "comfyui" and source.suffix.lower() in {".bat", ".cmd", ".ps1"}:
        abort(404)
    cache_path = cached_icon_path(app_id)
    if not cache_path.exists():
        tmp_path = cache_path.with_suffix(".tmp.png")
        try:
            tmp_path.unlink(missing_ok=True)
        except Exception:
            pass
        if not extract_windows_icon(source, tmp_path):
            try:
                tmp_path.unlink(missing_ok=True)
            except Exception:
                pass
            abort(404)
        try:
            tmp_path.replace(cache_path)
        except Exception:
            if tmp_path.exists():
                cache_path.write_bytes(tmp_path.read_bytes())
                tmp_path.unlink(missing_ok=True)
    return send_file(cache_path, mimetype="image/png", conditional=True, max_age=86400)


@app.post("/api/apps/launch")
def launch_app():
    body = request.get_json(silent=True) or {}
    app_id = body.get("id", "")
    allowed = {x["id"] for x in all_known_apps()}
    if app_id not in allowed:
        cached_scan("all", force=True)
        allowed = {x["id"] for x in all_known_apps()}
    if app_id not in allowed:
        abort(403)
    p = safe_path(app_id)
    if p is None:
        abort(404)
    try:
        start_item(p)
        record_recent(app_id)
        return jsonify({"ok": True, "error": None})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.post("/api/power/action")
def power_action():
    body = request.get_json(silent=True) or {}
    action = str(body.get("action", "")).lower()
    try:
        if action == "lock":
            if os.name == "nt":
                ctypes.windll.user32.LockWorkStation()
            return jsonify({"ok": True, "error": None})
        if action == "sleep":
            if os.name == "nt":
                result = ctypes.windll.powrprof.SetSuspendState(False, False, False)
                if not result:
                    raise OSError("Windows не принял команду перехода в сон")
            return jsonify({"ok": True, "error": None})
        if action == "restart":
            subprocess.Popen(["shutdown", "/r", "/t", "0"], creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            return jsonify({"ok": True, "error": None})
        if action == "shutdown":
            subprocess.Popen(["shutdown", "/s", "/t", "0"], creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            return jsonify({"ok": True, "error": None})
        abort(400)
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.get("/api/fs/roots")
def fs_roots():
    items = [
        {"name": "Рабочий стол", "path": str(desktop()), "kind": "folder", "icon": "desktop"},
        {"name": "Загрузки", "path": str(downloads()), "kind": "folder", "icon": "downloads"},
        {"name": "Домашняя папка", "path": str(Path.home()), "kind": "folder", "icon": "home"},
    ]
    for d in drives():
        items.append({"name": str(d), "path": str(d), "kind": "folder", "icon": "drive"})
    return jsonify(items)


@app.get("/api/fs/list")
def fs_list():
    p = safe_path(request.args.get("path", ""))
    if p is None or not p.is_dir():
        abort(404)
    items = []
    try:
        for child in p.iterdir():
            try:
                st = child.stat()
                items.append({
                    "name": child.name,
                    "path": str(child),
                    "kind": "folder" if child.is_dir() else "file",
                    "size": None if child.is_dir() else st.st_size,
                    "mtime": st.st_mtime,
                    "icon": "folder" if child.is_dir() else "file",
                })
            except (OSError, PermissionError):
                continue
    except PermissionError:
        abort(403)
    items.sort(key=lambda x: (x["kind"] != "folder", x["name"].lower()))
    return jsonify(items[:1000])


@app.get("/api/fs/download")
def fs_download():
    p = safe_path(request.args.get("path", ""))
    if p is None or not p.is_file():
        abort(404)
    try:
        return send_file(p, as_attachment=True, download_name=p.name, conditional=True)
    except PermissionError:
        abort(403)


@app.post("/api/fs/upload")
def fs_upload():
    folder = safe_path(request.form.get("path", "") or request.args.get("path", ""))
    if folder is None or not folder.is_dir():
        abort(404)
    uploaded = request.files.get("file")
    if uploaded is None:
        return jsonify({"ok": False, "error": "Файл не передан."}), 400

    original_name = Path(str(uploaded.filename or "upload.bin")).name.strip()
    if not original_name or original_name in (".", ".."):
        original_name = "upload.bin"
    # Windows rejects these characters in normal file names.
    for ch in '<>:"/\\|?*':
        original_name = original_name.replace(ch, "_")

    target = folder / original_name
    if target.exists():
        stem, suffix = target.stem, target.suffix
        index = 1
        while target.exists() and index < 10_000:
            target = folder / f"{stem} ({index}){suffix}"
            index += 1
    try:
        uploaded.save(str(target))
        st = target.stat()
        return jsonify({
            "ok": True,
            "error": None,
            "item": {
                "name": target.name,
                "path": str(target),
                "kind": "file",
                "size": st.st_size,
                "mtime": st.st_mtime,
                "icon": "file",
            },
        })
    except PermissionError:
        abort(403)
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500


@app.post("/api/fs/open")
def fs_open():
    body = request.get_json(silent=True) or {}
    p = safe_path(body.get("path", ""))
    if p is None:
        abort(404)
    try:
        start_item(p)
        return jsonify({"ok": True, "error": None})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500




# Native Windows touch injection (Windows 8+). Falls back to mouse only when the API is unavailable.
if os.name == "nt":
    class POINT(ctypes.Structure):
        _fields_ = [("x", wintypes.LONG), ("y", wintypes.LONG)]

    class RECT(ctypes.Structure):
        _fields_ = [("left", wintypes.LONG), ("top", wintypes.LONG), ("right", wintypes.LONG), ("bottom", wintypes.LONG)]

    class POINTER_INFO(ctypes.Structure):
        _fields_ = [
            ("pointerType", wintypes.DWORD), ("pointerId", wintypes.UINT), ("frameId", wintypes.UINT),
            ("pointerFlags", wintypes.DWORD), ("sourceDevice", wintypes.HANDLE), ("hwndTarget", wintypes.HWND),
            ("ptPixelLocation", POINT), ("ptHimetricLocation", POINT), ("ptPixelLocationRaw", POINT),
            ("ptHimetricLocationRaw", POINT), ("dwTime", wintypes.DWORD), ("historyCount", wintypes.UINT),
            ("inputData", wintypes.INT), ("dwKeyStates", wintypes.DWORD), ("performanceCount", ctypes.c_ulonglong),
            ("buttonChangeType", wintypes.DWORD),
        ]

    class POINTER_TOUCH_INFO(ctypes.Structure):
        _fields_ = [
            ("pointerInfo", POINTER_INFO), ("touchFlags", wintypes.DWORD), ("touchMask", wintypes.DWORD),
            ("rcContact", RECT), ("rcContactRaw", RECT), ("orientation", wintypes.UINT), ("pressure", wintypes.UINT),
        ]

    PT_TOUCH = 2
    POINTER_FLAG_INRANGE = 0x00000002
    POINTER_FLAG_INCONTACT = 0x00000004
    POINTER_FLAG_PRIMARY = 0x00002000
    POINTER_FLAG_DOWN = 0x00010000
    POINTER_FLAG_UPDATE = 0x00020000
    POINTER_FLAG_UP = 0x00040000
    TOUCH_MASK_CONTACTAREA = 0x00000001
    TOUCH_MASK_ORIENTATION = 0x00000002
    TOUCH_MASK_PRESSURE = 0x00000004

    _touch_ready = False
    try:
        _touch_ready = bool(ctypes.windll.user32.InitializeTouchInjection(10, 1))
    except Exception:
        _touch_ready = False
else:
    _touch_ready = False


def _inject_touch_point(pointer_id, x, y, phase):
    if not _touch_ready:
        return False
    info = POINTER_TOUCH_INFO()
    info.pointerInfo.pointerType = PT_TOUCH
    info.pointerInfo.pointerId = pointer_id
    info.pointerInfo.ptPixelLocation = POINT(int(x), int(y))
    base = POINTER_FLAG_INRANGE | POINTER_FLAG_PRIMARY
    if phase == "down":
        info.pointerInfo.pointerFlags = base | POINTER_FLAG_INCONTACT | POINTER_FLAG_DOWN
    elif phase == "move":
        info.pointerInfo.pointerFlags = base | POINTER_FLAG_INCONTACT | POINTER_FLAG_UPDATE
    else:
        info.pointerInfo.pointerFlags = base | POINTER_FLAG_UP
    radius = 3
    info.touchFlags = 0
    info.touchMask = TOUCH_MASK_CONTACTAREA | TOUCH_MASK_ORIENTATION | TOUCH_MASK_PRESSURE
    info.rcContact = RECT(int(x-radius), int(y-radius), int(x+radius), int(y+radius))
    info.rcContactRaw = info.rcContact
    info.orientation = 90
    info.pressure = 32000
    return bool(ctypes.windll.user32.InjectTouchInput(1, ctypes.byref(info)))


def _touch_tap(px, py, hold=0.045):
    if _touch_ready:
        if _inject_touch_point(1, px, py, "down"):
            time.sleep(max(0.02, min(1.2, hold)))
            _inject_touch_point(1, px, py, "up")
            return True
    pyautogui.click(px, py)
    return False


def _touch_swipe(start_px, start_py, end_px, end_py, duration=0.22):
    if not _touch_ready:
        pyautogui.moveTo(start_px, start_py)
        pyautogui.dragTo(end_px, end_py, duration=max(0.08, duration), button="left")
        return False
    steps = max(5, min(30, int(duration * 60)))
    if not _inject_touch_point(2, start_px, start_py, "down"):
        return False
    for i in range(1, steps):
        t = i / float(steps)
        x = start_px + (end_px - start_px) * t
        y = start_py + (end_py - start_py) * t
        _inject_touch_point(2, x, y, "move")
        time.sleep(duration / steps)
    _inject_touch_point(2, end_px, end_py, "up")
    return True


def _focused_control_is_text_input():
    if os.name != "nt":
        return False
    try:
        import comtypes
        import comtypes.client
        comtypes.CoInitialize()
        automation = comtypes.client.CreateObject("UIAutomationClient.CUIAutomation")
        element = automation.GetFocusedElement()
        control_type = int(element.CurrentControlType)
        # Edit, ComboBox, Document
        return control_type in {50004, 50003, 50030}
    except Exception:
        return False
    finally:
        try:
            comtypes.CoUninitialize()
        except Exception:
            pass


def _primary_monitor_geometry():
    with mss.mss() as sct:
        if len(sct.monitors) < 2:
            monitor = sct.monitors[0]
        else:
            monitor = sct.monitors[1]
        return {
            "left": int(monitor["left"]),
            "top": int(monitor["top"]),
            "width": int(monitor["width"]),
            "height": int(monitor["height"]),
        }


def _screen_point(x_norm, y_norm):
    geometry = _primary_monitor_geometry()
    try:
        x = max(0.0, min(1.0, float(x_norm)))
        y = max(0.0, min(1.0, float(y_norm)))
    except Exception:
        abort(400)
    px = geometry["left"] + int(round(x * max(0, geometry["width"] - 1)))
    py = geometry["top"] + int(round(y * max(0, geometry["height"] - 1)))
    return px, py


@app.get("/api/remote/info")
def remote_info():
    try:
        geometry = _primary_monitor_geometry()
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500
    return jsonify({
        "ok": True,
        "width": geometry["width"],
        "height": geometry["height"],
        "modes": {
            key: {"fps": value["fps"], "jpeg": value["jpeg"], "max_width": value["max_width"]}
            for key, value in REMOTE_PRESETS.items()
        },
    })


@app.get("/api/remote/frame")
def remote_frame():
    mode = request.args.get("mode", "balanced")
    preset = REMOTE_PRESETS.get(mode, REMOTE_PRESETS["balanced"])
    try:
        with REMOTE_LOCK:
            with mss.mss() as sct:
                monitor = sct.monitors[1] if len(sct.monitors) > 1 else sct.monitors[0]
                shot = sct.grab(monitor)
                image = Image.frombytes("RGB", shot.size, shot.rgb)
                if image.width > preset["max_width"]:
                    ratio = preset["max_width"] / float(image.width)
                    new_size = (preset["max_width"], max(1, int(image.height * ratio)))
                    resample = Image.Resampling.LANCZOS if mode == "quality" else Image.Resampling.BILINEAR
                    image = image.resize(new_size, resample)
                buffer = io.BytesIO()
                image.save(buffer, format="JPEG", quality=preset["jpeg"], optimize=False)
                payload = buffer.getvalue()
        response = Response(payload, mimetype="image/jpeg")
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
        response.headers["Pragma"] = "no-cache"
        return response
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.get("/api/remote/focus")
def remote_focus():
    return jsonify({"ok": True, "text_input": _focused_control_is_text_input()})


@app.post("/api/remote/input/touch")
def remote_touch():
    body = request.get_json(silent=True) or {}
    kind = str(body.get("kind", "tap")).lower()
    try:
        x1, y1 = _screen_point(body.get("x1", body.get("x", 0.5)), body.get("y1", body.get("y", 0.5)))
        x2, y2 = _screen_point(body.get("x2", body.get("x", 0.5)), body.get("y2", body.get("y", 0.5)))
        duration = max(0.05, min(1.5, float(body.get("duration", 0.22))))
    except Exception:
        abort(400)
    try:
        with INPUT_LOCK:
            if kind == "swipe":
                native = _touch_swipe(x1, y1, x2, y2, duration)
            elif kind == "long":
                native = _touch_tap(x1, y1, hold=max(0.55, duration))
            elif kind == "double":
                native = _touch_tap(x1, y1, hold=0.035)
                time.sleep(0.08)
                _touch_tap(x1, y1, hold=0.035)
            else:
                native = _touch_tap(x1, y1, hold=0.04)
        return jsonify({"ok": True, "error": None, "native_touch": bool(native)})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.post("/api/remote/input/tap")
def remote_tap():
    body = request.get_json(silent=True) or {}
    px, py = _screen_point(body.get("x", 0.5), body.get("y", 0.5))
    button = str(body.get("button", "left")).lower()
    if button not in {"left", "right"}:
        button = "left"
    clicks = body.get("clicks", 1)
    try:
        clicks = max(1, min(2, int(clicks)))
    except Exception:
        clicks = 1
    try:
        with INPUT_LOCK:
            pyautogui.click(px, py, clicks=clicks, interval=0.08 if clicks > 1 else 0.0, button=button)
        return jsonify({"ok": True, "error": None})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.post("/api/remote/input/scroll")
def remote_scroll():
    body = request.get_json(silent=True) or {}
    try:
        dy = int(body.get("dy", 0))
        dx = int(body.get("dx", 0))
    except Exception:
        abort(400)
    dy = max(-30, min(30, dy))
    dx = max(-30, min(30, dx))
    try:
        with INPUT_LOCK:
            if dy:
                pyautogui.scroll(dy)
            if dx and hasattr(pyautogui, "hscroll"):
                pyautogui.hscroll(dx)
        return jsonify({"ok": True, "error": None})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500




def _send_unicode_text(text):
    if os.name != "nt":
        pyperclip.copy(text)
        pyautogui.hotkey("ctrl", "v")
        return

    ULONG_PTR = wintypes.WPARAM

    class KEYBDINPUT(ctypes.Structure):
        _fields_ = [
            ("wVk", wintypes.WORD),
            ("wScan", wintypes.WORD),
            ("dwFlags", wintypes.DWORD),
            ("time", wintypes.DWORD),
            ("dwExtraInfo", ULONG_PTR),
        ]

    class INPUTUNION(ctypes.Union):
        _fields_ = [("ki", KEYBDINPUT)]

    class INPUT(ctypes.Structure):
        _anonymous_ = ("u",)
        _fields_ = [("type", wintypes.DWORD), ("u", INPUTUNION)]

    INPUT_KEYBOARD = 1
    KEYEVENTF_KEYUP = 0x0002
    KEYEVENTF_UNICODE = 0x0004

    encoded = text.encode("utf-16-le")
    code_units = [int.from_bytes(encoded[i:i+2], "little") for i in range(0, len(encoded), 2)]
    for unit in code_units:
        down = INPUT(type=INPUT_KEYBOARD, ki=KEYBDINPUT(0, unit, KEYEVENTF_UNICODE, 0, 0))
        up = INPUT(type=INPUT_KEYBOARD, ki=KEYBDINPUT(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, 0, 0))
        array = (INPUT * 2)(down, up)
        sent = ctypes.windll.user32.SendInput(2, ctypes.byref(array), ctypes.sizeof(INPUT))
        if sent != 2:
            raise OSError("SendInput failed")


@app.post("/api/remote/input/text")
def remote_text():
    body = request.get_json(silent=True) or {}
    text = str(body.get("text", ""))
    if not text:
        return jsonify({"ok": True, "error": None})
    if len(text) > 4000:
        abort(413)
    try:
        with INPUT_LOCK:
            _send_unicode_text(text)
        return jsonify({"ok": True, "error": None})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.post("/api/remote/input/key")
def remote_key():
    body = request.get_json(silent=True) or {}
    key = str(body.get("key", "")).lower()
    allowed = {
        "enter", "backspace", "esc", "tab", "left", "right", "up", "down",
        "home", "end", "delete", "win", "space", "pageup", "pagedown",
    }
    if key not in allowed:
        abort(400)
    try:
        with INPUT_LOCK:
            pyautogui.press(key)
        return jsonify({"ok": True, "error": None})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.post("/api/remote/input/hotkey")
def remote_hotkey():
    body = request.get_json(silent=True) or {}
    keys = body.get("keys", [])
    if not isinstance(keys, list) or not keys or len(keys) > 4:
        abort(400)
    allowed = {"ctrl", "alt", "shift", "win", "a", "c", "v", "x", "z", "y", "s", "f", "tab", "esc", "enter"}
    normalized = [str(key).lower() for key in keys]
    if any(key not in allowed for key in normalized):
        abort(400)
    try:
        with INPUT_LOCK:
            pyautogui.hotkey(*normalized)
        return jsonify({"ok": True, "error": None})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


def run_server():
    ensure_comfy_ws_thread()
    serve(app, host="0.0.0.0", port=int(CONFIG["port"]), threads=8, clear_untrusted_proxy_headers=True)


if __name__ == "__main__":
    print(f"PC Remote Server: http://{get_local_ip()}:{CONFIG['port']}")
    print(f"ID подключения: {connection_id()}")
    run_server()
