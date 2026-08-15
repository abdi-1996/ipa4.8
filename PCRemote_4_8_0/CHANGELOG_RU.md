# PC Remote 4.8.0 — Clean Rebuild

Версия 4.8.0 собрана заново на базе последних функций проекта с упором на стабильное подключение.

## Подключение
- один пароль, который задаётся в PC Remote Server;
- маршруты: **Авто / LAN / ZeroTier / Tailscale**;
- Авто пробует **LAN → ZeroTier → Tailscale**;
- iPhone использует `Network.framework` (`NWConnection`) для API, а не `URLSession`;
- добавлен публичный безопасный `/api/ping` только для проверки доступности сервера;
- в настройках до входа появилась кнопка **«Проверить соединение»**;
- сервер слушает `0.0.0.0:8765`;
- Windows Server показывает LAN, Tailscale и ZeroTier IP;
- кнопка **«Настроить LAN / Tailscale / ZeroTier»** создаёт нужные правила Windows Firewall через UAC;
- в Windows-пакет входят `SETUP_NETWORK_ADMIN.ps1/.bat` и `CHECK_NETWORK.ps1`.

## Сохранено из предыдущих версий
- ComfyUI и node editor;
- CorelDRAW Remote;
- Проводник и обмен файлами;
- удалённый экран и сенсорное управление;
- Wake-on-LAN и питание ПК;
- меню Пуск, поиск приложений, темы и главный экран.

## Адреса текущего ПК
- LAN: `192.168.8.248:8765`
- ZeroTier: `10.204.78.78:8765`
- Tailscale: `100.105.141.17:8765`

Для ZeroTier и Tailscale соответствующее VPN-приложение на iPhone должно быть включено.
