"""CorelDRAW automation bridge for PC Remote.

The bridge keeps every COM call on one dedicated STA thread.  CorelDRAW's
object model is an out-of-process COM server; using a single worker avoids
cross-thread COM proxy problems when Flask/Waitress handles concurrent calls.
"""
from __future__ import annotations

import queue
import tempfile
import threading
import time
from pathlib import Path


class CorelBridgeError(RuntimeError):
    pass


def _safe(obj, name, default=None):
    try:
        value = getattr(obj, name)
        return value
    except Exception:
        return default


def _float(value, default=0.0):
    try:
        return float(value)
    except Exception:
        return default


def _int(value, default=0):
    try:
        return int(value)
    except Exception:
        return default


def _hex_to_rgb(value: str):
    value = str(value or "").strip().lstrip("#")
    if len(value) == 3:
        value = "".join(ch * 2 for ch in value)
    if len(value) != 6:
        raise ValueError("Цвет должен быть в формате #RRGGBB")
    try:
        return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))
    except ValueError as exc:
        raise ValueError("Некорректный цвет") from exc


class CorelAutomation:
    def __init__(self):
        self._queue: queue.Queue = queue.Queue()
        self._thread = threading.Thread(target=self._run, name="PCRemote-CorelDRAW", daemon=True)
        self._started = threading.Event()
        self._thread.start()
        self._started.wait(timeout=3)

    def call(self, operation: str, **kwargs):
        result_queue: queue.Queue = queue.Queue(maxsize=1)
        self._queue.put((operation, kwargs, result_queue))
        try:
            ok, payload = result_queue.get(timeout=20)
        except queue.Empty as exc:
            raise CorelBridgeError("CorelDRAW не ответил вовремя.") from exc
        if ok:
            return payload
        raise CorelBridgeError(str(payload))

    def _run(self):
        try:
            import comtypes
            from comtypes.client import CreateObject, GetActiveObject

            comtypes.CoInitialize()
            self._CreateObject = CreateObject
            self._GetActiveObject = GetActiveObject
            self._com_available = True
        except Exception as exc:
            self._com_available = False
            self._com_error = exc
        self._app = None
        self._started.set()

        while True:
            operation, kwargs, result_queue = self._queue.get()
            try:
                handler = getattr(self, f"_op_{operation}")
                result_queue.put((True, handler(**kwargs)))
            except Exception as exc:
                result_queue.put((False, self._friendly_error(exc)))

    def _friendly_error(self, exc: Exception) -> str:
        text = str(exc).strip()
        if not text:
            text = exc.__class__.__name__
        if "class not registered" in text.lower():
            return "CorelDRAW не найден или его COM-интерфейс не зарегистрирован."
        return text

    def _connect(self, create=True):
        if not self._com_available:
            raise CorelBridgeError(f"COM недоступен: {self._com_error}")

        # Re-use the same proxy while it remains alive.
        if self._app is not None:
            try:
                _ = self._app.Documents.Count
                return self._app
            except Exception:
                self._app = None

        try:
            self._app = self._GetActiveObject("CorelDRAW.Application")
        except Exception:
            if not create:
                raise CorelBridgeError("CorelDRAW не запущен.")
            # dynamic=True avoids depending on a generated Python wrapper for a
            # particular CorelDRAW version.
            self._app = self._CreateObject("CorelDRAW.Application", dynamic=True)
        try:
            self._app.Visible = True
        except Exception:
            pass
        return self._app

    def _document(self, create=False):
        app = self._connect(create=True)
        try:
            count = _int(app.Documents.Count)
        except Exception:
            count = 0
        if count <= 0:
            if not create:
                return app, None
            doc = app.CreateDocument()
            return app, doc
        try:
            return app, app.ActiveDocument
        except Exception:
            return app, app.Documents.Item(count)

    @staticmethod
    def _selection(doc):
        try:
            return doc.ActiveSelectionRange
        except Exception:
            return None

    @staticmethod
    def _selection_count(doc):
        selection = CorelAutomation._selection(doc)
        if selection is None:
            return 0
        return _int(_safe(selection, "Count", 0))

    @staticmethod
    def _active_shape(doc):
        try:
            selection = doc.ActiveSelectionRange
            if _int(selection.Count) > 0:
                return selection.Shapes.Item(1)
        except Exception:
            pass
        try:
            return doc.ActiveShape
        except Exception:
            return None

    def _shape_payload(self, shape, index: int):
        name = str(_safe(shape, "Name", "") or "").strip()
        shape_type = _int(_safe(shape, "Type", 0))
        label = name or f"Объект {index}"
        text_value = ""
        try:
            text_obj = shape.Text
            text_value = str(text_obj.Story.Text or "")
            if text_value.strip():
                label = text_value.strip().replace("\r", " ").replace("\n", " ")[:48]
        except Exception:
            pass
        return {
            "id": str(index),
            "index": index,
            "name": label,
            "type": shape_type,
            "x": _float(_safe(shape, "PositionX", 0)),
            "y": _float(_safe(shape, "PositionY", 0)),
            "width": _float(_safe(shape, "SizeWidth", 0)),
            "height": _float(_safe(shape, "SizeHeight", 0)),
            "rotation": _float(_safe(shape, "RotationAngle", 0)),
            "text": text_value[:300],
        }

    def _status_payload(self, app, doc):
        if doc is None:
            return {
                "ok": True,
                "running": True,
                "document_open": False,
                "document_name": "Без документа",
                "document_path": "",
                "dirty": False,
                "page_index": 0,
                "page_count": 0,
                "selection_count": 0,
                "selection": None,
                "version": str(_safe(app, "Version", _safe(app, "VersionMajor", "")) or ""),
            }

        page_count = _int(_safe(_safe(doc, "Pages", None), "Count", 0))
        page_index = _int(_safe(_safe(doc, "ActivePage", None), "Index", 1), 1)
        selected = self._active_shape(doc)
        selected_payload = self._shape_payload(selected, 0) if selected is not None else None
        return {
            "ok": True,
            "running": True,
            "document_open": True,
            "document_name": str(_safe(doc, "Name", "Документ") or "Документ"),
            "document_path": str(_safe(doc, "FilePath", "") or ""),
            "dirty": bool(_safe(doc, "Dirty", False)),
            "page_index": page_index,
            "page_count": page_count,
            "selection_count": self._selection_count(doc),
            "selection": selected_payload,
            "version": str(_safe(app, "Version", _safe(app, "VersionMajor", "")) or ""),
        }

    # ---- operations -----------------------------------------------------

    def _op_launch(self):
        app = self._connect(create=True)
        try:
            app.Visible = True
        except Exception:
            pass
        return {"ok": True}

    def _op_status(self):
        app, doc = self._document(create=False)
        return self._status_payload(app, doc)

    def _op_new(self):
        app = self._connect(create=True)
        app.Visible = True
        app.CreateDocument()
        return self._status_payload(app, app.ActiveDocument)

    def _op_open(self, path: str):
        path = str(Path(path).resolve())
        if not Path(path).is_file():
            raise CorelBridgeError("Файл не найден.")
        app = self._connect(create=True)
        app.Visible = True
        app.OpenDocument(path)
        return self._status_payload(app, app.ActiveDocument)

    def _op_preview(self):
        app, doc = self._document(create=False)
        if doc is None:
            raise CorelBridgeError("В CorelDRAW нет открытого документа.")
        root = Path(tempfile.gettempdir()) / "PCRemoteCorelPreview"
        root.mkdir(parents=True, exist_ok=True)
        path = root / f"preview-{int(time.time() * 1000)}.png"
        export_filter = doc.ExportBitmap(str(path), 802, 1, 4, 1200, 0, 96, 96)  # PNG, current page, RGB
        try:
            export_filter.Finish()
        except Exception:
            pass
        if not path.exists() or path.stat().st_size == 0:
            raise CorelBridgeError("CorelDRAW не смог создать предпросмотр.")
        # Keep the directory bounded.
        for old in sorted(root.glob("preview-*.png"), key=lambda p: p.stat().st_mtime)[:-4]:
            try:
                old.unlink()
            except Exception:
                pass
        return str(path)

    def _op_objects(self):
        _app, doc = self._document(create=False)
        if doc is None:
            return []
        try:
            shapes = doc.ActivePage.Shapes
            count = _int(shapes.Count)
        except Exception:
            return []
        items = []
        # Corel collections are 1-based. Limit the mobile object list to keep
        # extremely complex artwork responsive; the full editor stays on PC.
        for index in range(1, min(count, 300) + 1):
            try:
                items.append(self._shape_payload(shapes.Item(index), index))
            except Exception:
                continue
        return items

    def _op_select(self, index: int):
        _app, doc = self._document(create=False)
        if doc is None:
            raise CorelBridgeError("Нет открытого документа.")
        index = int(index)
        shape = doc.ActivePage.Shapes.Item(index)
        try:
            doc.ClearSelection()
        except Exception:
            pass
        shape.CreateSelection()
        return self._status_payload(_app, doc)

    def _op_transform(self, x=None, y=None, width=None, height=None, rotation=None, keep_ratio=True):
        app, doc = self._document(create=False)
        if doc is None:
            raise CorelBridgeError("Нет открытого документа.")
        selection = self._selection(doc)
        if selection is None or _int(_safe(selection, "Count", 0)) <= 0:
            raise CorelBridgeError("Сначала выберите объект.")

        # SetSize is preferable because it keeps the selection centered and
        # handles multi-object selections. PositionX/Y and RotationAngle are
        # available on both Shape and ShapeRange in modern CorelDRAW versions.
        if width is not None or height is not None:
            current_w = max(_float(_safe(selection, "SizeWidth", 1), 1), 0.0001)
            current_h = max(_float(_safe(selection, "SizeHeight", 1), 1), 0.0001)
            new_w = _float(width, current_w) if width is not None else current_w
            new_h = _float(height, current_h) if height is not None else current_h
            if keep_ratio:
                if width is not None and height is None:
                    new_h = current_h * new_w / current_w
                elif height is not None and width is None:
                    new_w = current_w * new_h / current_h
            try:
                selection.SetSize(new_w, new_h)
            except Exception:
                # Single-shape fallback.
                shape = self._active_shape(doc)
                if shape is not None:
                    shape.SetSize(new_w, new_h)
        if x is not None:
            try:
                selection.PositionX = _float(x)
            except Exception:
                shape = self._active_shape(doc)
                if shape is not None:
                    shape.PositionX = _float(x)
        if y is not None:
            try:
                selection.PositionY = _float(y)
            except Exception:
                shape = self._active_shape(doc)
                if shape is not None:
                    shape.PositionY = _float(y)
        if rotation is not None:
            value = _float(rotation)
            try:
                selection.RotationAngle = value
            except Exception:
                shape = self._active_shape(doc)
                if shape is not None:
                    shape.RotationAngle = value
        try:
            app.Refresh()
        except Exception:
            pass
        return self._status_payload(app, doc)

    def _op_style(self, fill=None, outline=None, outline_width=None):
        app, doc = self._document(create=False)
        if doc is None:
            raise CorelBridgeError("Нет открытого документа.")
        selection = self._selection(doc)
        if selection is None or _int(_safe(selection, "Count", 0)) <= 0:
            raise CorelBridgeError("Сначала выберите объект.")

        count = _int(selection.Count)
        for i in range(1, count + 1):
            try:
                shape = selection.Shapes.Item(i)
            except Exception:
                continue
            if fill:
                r, g, b = _hex_to_rgb(fill)
                try:
                    shape.Fill.UniformColor.RGBAssign(r, g, b)
                except Exception:
                    pass
            if outline:
                r, g, b = _hex_to_rgb(outline)
                try:
                    shape.Outline.Color.RGBAssign(r, g, b)
                except Exception:
                    pass
            if outline_width is not None:
                try:
                    shape.Outline.Width = max(0.0, _float(outline_width))
                except Exception:
                    pass
        try:
            app.Refresh()
        except Exception:
            pass
        return self._status_payload(app, doc)

    def _op_create(self, kind: str, text: str = "Текст"):
        app, doc = self._document(create=True)
        page = doc.ActivePage
        layer = doc.ActiveLayer
        page_w = max(_float(_safe(page, "SizeWidth", 8.0), 8.0), 1.0)
        page_h = max(_float(_safe(page, "SizeHeight", 8.0), 8.0), 1.0)
        cx = page_w / 2.0
        cy = page_h / 2.0
        width = max(page_w * 0.28, 1.0)
        height = max(page_h * 0.18, 0.7)
        kind = str(kind or "").lower()

        if kind == "rectangle":
            shape = layer.CreateRectangle2(cx - width / 2, cy + height / 2, width, height)
        elif kind == "ellipse":
            shape = layer.CreateEllipse2(cx, cy, width / 2, height / 2)
        elif kind == "text":
            shape = layer.CreateArtisticText(cx - width / 2, cy, str(text or "Текст"))
        elif kind == "line":
            shape = layer.CreateLineSegment(cx - width / 2, cy, cx + width / 2, cy)
        else:
            raise CorelBridgeError("Неизвестный инструмент.")
        try:
            doc.ClearSelection()
        except Exception:
            pass
        try:
            shape.CreateSelection()
        except Exception:
            pass
        try:
            app.Refresh()
        except Exception:
            pass
        return self._status_payload(app, doc)

    def _op_page(self, action: str, index=None):
        app, doc = self._document(create=False)
        if doc is None:
            raise CorelBridgeError("Нет открытого документа.")
        pages = doc.Pages
        count = _int(pages.Count)
        current = _int(doc.ActivePage.Index, 1)
        action = str(action or "").lower()
        if action == "add":
            doc.AddPages(1)
            try:
                doc.Pages.Item(_int(doc.Pages.Count)).Activate()
            except Exception:
                pass
        elif action == "next":
            pages.Item(min(count, current + 1)).Activate()
        elif action == "previous":
            pages.Item(max(1, current - 1)).Activate()
        elif action == "set":
            target = max(1, min(_int(index, current), count))
            pages.Item(target).Activate()
        else:
            raise CorelBridgeError("Неизвестная команда страницы.")
        return self._status_payload(app, doc)

    def _op_action(self, action: str):
        app, doc = self._document(create=False)
        action = str(action or "").lower()
        if action == "show":
            app.Visible = True
            try:
                app.Refresh()
            except Exception:
                pass
            return {"ok": True}
        if doc is None:
            raise CorelBridgeError("Нет открытого документа.")

        selection = self._selection(doc)
        selection_count = self._selection_count(doc)

        if action == "save":
            doc.Save()
        elif action == "undo":
            doc.Undo()
        elif action == "redo":
            doc.Redo()
        elif action == "delete":
            if selection_count <= 0:
                raise CorelBridgeError("Сначала выберите объект.")
            selection.Delete()
        elif action == "duplicate":
            if selection_count <= 0:
                raise CorelBridgeError("Сначала выберите объект.")
            selection.Duplicate()
        elif action == "group":
            if selection_count < 2:
                raise CorelBridgeError("Для группировки выберите минимум два объекта.")
            selection.Group()
        elif action == "ungroup":
            if selection_count <= 0:
                raise CorelBridgeError("Сначала выберите группу.")
            selection.Ungroup()
        elif action == "select_all":
            doc.ActivePage.Shapes.All.CreateSelection()
        elif action == "deselect":
            doc.ClearSelection()
        elif action == "front":
            if selection_count <= 0:
                raise CorelBridgeError("Сначала выберите объект.")
            for i in range(1, selection_count + 1):
                try:
                    selection.Shapes.Item(i).OrderToFront()
                except Exception:
                    pass
        elif action == "back":
            if selection_count <= 0:
                raise CorelBridgeError("Сначала выберите объект.")
            for i in range(1, selection_count + 1):
                try:
                    selection.Shapes.Item(i).OrderToBack()
                except Exception:
                    pass
        else:
            raise CorelBridgeError("Неизвестная команда CorelDRAW.")

        try:
            app.Refresh()
        except Exception:
            pass
        return self._status_payload(app, doc)


COREL = CorelAutomation()
