# PC Remote 4.3 — сборка и установка через Sideloadly

## GitHub Actions
1. Загрузите проект в GitHub целиком, включая папку `.github`.
2. Откройте **Actions → Build PC Remote**.
3. Нажмите **Run workflow**.
4. После успешной сборки скачайте artifact **PCRemote-IPA**.
5. Распакуйте ZIP — внутри будет `PCRemote.ipa`.

Workflow сам ищет `PCRemote.xcodeproj`, поэтому название внешней папки менять в YAML не нужно.

## Установка поверх старой версии
1. Откройте Sideloadly.
2. Подключите iPhone.
3. Перетащите новый `PCRemote.ipa`.
4. Используйте тот же Apple ID и тот же Bundle ID.
5. Нажмите **Start**.

Старую версию удалять вручную не требуется.

## Windows-сервер
В этой версии изменён протокол ComfyUI и добавлены операции библиотеки workflow/редактора нод, поэтому вместе с IPA обязательно обновите Windows-сервер.

1. В той же сборке GitHub Actions скачайте artifact **PCRemote-Windows**.
2. Закройте старый `PCRemoteServer.exe`.
3. Замените старый сервер файлами из нового artifact.
4. Запустите новый `PCRemoteServer.exe` или перезапустите автозапуск.

После обновления в **Настройки → О приложении** на iPhone должна отображаться версия **4.3**.
