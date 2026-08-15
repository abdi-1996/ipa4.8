# Проверка PC Remote 4.6.2

Перед упаковкой архива выполнено:

- `python -m py_compile` для `server.py`, `gui.py`, `corel_bridge.py`;
- `swiftc -parse` для всех Swift-файлов iOS;
- проверка `Info.plist`: версия 4.6.2, build 10, ATS для LAN/Tailscale;
- проверка YAML GitHub Actions;
- проверка, что `CorelDrawView.swift` добавлен в Xcode target;
- проверка наличия CorelDRAW API routes на Windows Server.

Полная компиляция iOS выполняется на macOS runner GitHub Actions. Реальное COM-управление CorelDRAW требует Windows с установленным CorelDRAW и проверяется уже на вашем ПК.
