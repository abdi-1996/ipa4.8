# ZeroTier в PC Remote 4.8.1

Текущая сеть:
- ПК: **10.204.78.78**
- iPhone: **10.204.78.79**
- порт PC Remote: **8765/TCP**

Оба устройства должны быть Authorized в одной ZeroTier-сети.

На Windows запустите PC Remote Server. В его окне должен отображаться ZeroTier IP. Один раз нажмите **«Настроить LAN / Tailscale / ZeroTier»** и подтвердите права администратора.

На iPhone:
1. Включите ZeroTier.
2. PC Remote → Подключение → ZeroTier.
3. Адрес: `10.204.78.78`, порт: `8765`.
4. Нажмите **«Проверить соединение»**.
5. Если проверка успешна — введите пароль PC Remote Server и войдите.

В режиме **Авто** порядок: LAN → ZeroTier → Tailscale.
