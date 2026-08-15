PC Remote 4.3 — workflows ComfyUI

По умолчанию модуль подключается к ComfyUI на этом же ПК:
http://127.0.0.1:8188

В PC Remote 4.3 workflow попадают тремя способами:
1. Сохранённые workflow из user-data библиотеки ComfyUI.
2. Недавние workflow из истории выполнений ComfyUI.
3. JSON, импортированные через кнопку + с ПК или iPhone.

Можно также вручную положить JSON в эту папку `comfy_workflows`.

Важно о форматах:
- обычный save-format хранит визуальный граф и подходит для мобильного редактора нод;
- API-format (File -> Export Workflow (API)) можно непосредственно запускать через /prompt.

Если нужный workflow открыт только во вкладке браузера и ещё не сохранён, сохраните его в ComfyUI или импортируйте JSON, чтобы PC Remote мог показать его в библиотеке.

Если ComfyUI работает на другом локальном порту, измените comfy_url в windows/config.json, например:
"comfy_url": "http://127.0.0.1:8189"
