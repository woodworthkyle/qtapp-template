"""
qtapp — sub-app launcher.

Scans the app's Documents directory for *.py files and launches them
as embedded QWidget sub-apps.

Sub-app contract
----------------
Each .py file may optionally define:

    def create_widget(back_fn: Callable) -> QWidget

where back_fn() returns the user to the picker.
If the function is absent the file is exec'd and a fallback label is shown.

Hot-reload
----------
Drop a file named _app_override.py in ~/Documents/ to replace this entire
module at startup without reinstalling.  The override must define main().

Launch request
--------------
Write a script name (no .py) or absolute path to ~/Documents/_launch_request.txt
before launching the app to auto-open that sub-app.  The deploy script does this.
On desktop, --app <name> and --file <path> CLI args work as well.
"""

import os
import sys
import importlib.util
import traceback
import datetime
from pathlib import Path


# ── iOS bootstrap ─────────────────────────────────────────────────────────────

def _setup_qt_paths():
    """Set QT_PLUGIN_PATH / QML2_IMPORT_PATH and preload PySide6 dylibs on iOS."""
    if sys.platform != "ios":
        return
    if "_qtapp_override_active" in sys.modules:
        return
    here = Path(__file__).resolve()
    bundle_root = None
    for parent in here.parents:
        if (parent / "app_packages").is_dir() or (parent / "app_packages.iphoneos").is_dir():
            bundle_root = parent
            break
    if bundle_root is None:
        # Fallback: find {bundle}/app on sys.path (handles edge cases)
        for entry in sys.path:
            p = Path(entry)
            if p.name == "app" and (p.parent / "app_packages").is_dir():
                bundle_root = p.parent
                break
    if bundle_root is None:
        print("WARNING: could not find bundle_root", file=sys.stderr)
        return
    plugins = bundle_root / "PlugIns"
    qml = bundle_root / "qml"
    if plugins.is_dir():
        os.environ.setdefault("QT_PLUGIN_PATH", str(plugins))
    if qml.is_dir():
        os.environ.setdefault("QML2_IMPORT_PATH", str(qml))
    _preload_pyside6_dylibs(bundle_root)


def _preload_pyside6_dylibs(bundle_root: Path):
    """Force-load shiboken6 + libpyside6 + all Qt framework binaries before
    QApplication is created.  Required on iOS because dlopen order matters."""
    import ctypes
    frameworks_dir = bundle_root / "Frameworks"
    # libpyside6 / shiboken6 flat dylibs
    for pattern in ("libshiboken6*.dylib", "libpyside6.abi3*.dylib", "libpyside6qml.abi3*.dylib"):
        for dylib in sorted(frameworks_dir.glob(pattern)):
            try:
                ctypes.CDLL(str(dylib))
                print(f"Preloaded: {dylib.name}", file=sys.stderr)
            except OSError as e:
                print(f"ERROR preloading {dylib}: {e}", file=sys.stderr)
    # Qt*.framework binaries — sign_pyside6.sh copies them from app_packages/PySide6/
    # into Frameworks/ as plain "Qt*.framework" (no "PySide6." prefix).
    # Load all of them so their QML plugin static registrations fire.
    for fw_dir in sorted(frameworks_dir.glob("Qt*.framework")):
        fw_bin = fw_dir / fw_dir.stem
        if fw_bin.exists():
            try:
                ctypes.CDLL(str(fw_bin))
            except OSError as e:
                print(f"WARNING: could not preload {fw_dir.name}: {e}", file=sys.stderr)


# Run at import time so paths are set before any PySide6 import.
_setup_qt_paths()


def _ios_show_qt_window(qt_widget) -> None:
    """Add Qt's QUIView to the key UIWindow and resize it to fill the window.

    Qt does not create its own QUIWindow when a third-party AppDelegate is in
    use (it requires QIOSApplicationDelegate for that).  Instead we grab Qt's
    native view via winId() and embed it directly in our AppDelegate UIWindow.

    The view's frame is explicitly set to the window bounds so that the Qt
    content fills the screen at the correct logical-point size (no zoom).

    Inlined in app.py so hot-reload deploys it without a full Xcode rebuild.
    """
    if sys.platform != "ios":
        return
    import ctypes as _ct

    class _CGRect(_ct.Structure):
        _fields_ = [("x", _ct.c_double), ("y", _ct.c_double),
                    ("w", _ct.c_double), ("h", _ct.c_double)]

    try:
        _lib = _ct.CDLL(None)
        _lib.sel_registerName.restype   = _ct.c_void_p
        _lib.sel_registerName.argtypes  = [_ct.c_char_p]
        _lib.objc_getClass.restype      = _ct.c_void_p
        _lib.objc_getClass.argtypes     = [_ct.c_char_p]

        def _sel(name: str):
            return _lib.sel_registerName(name.encode())

        def _msg(obj, sel_name: str, *args, argtypes=None, restype=_ct.c_void_p):
            _lib.objc_msgSend.restype  = restype
            _lib.objc_msgSend.argtypes = [_ct.c_void_p, _ct.c_void_p] + (argtypes or [])
            return _lib.objc_msgSend(obj, _sel(sel_name), *args)

        shared_app = _msg(_lib.objc_getClass(b"UIApplication"), "sharedApplication")
        key_window = _msg(shared_app, "keyWindow")
        if not key_window:
            print("_ios_show_qt_window: no keyWindow", file=sys.stderr)
            return

        # Get the window bounds (logical points).
        bounds: _CGRect = _msg(key_window, "bounds", restype=_CGRect)
        print(f"_ios_show_qt_window: keyWindow bounds={bounds.w}x{bounds.h}", file=sys.stderr)

        # Qt widget geometry for comparison.
        print(f"_ios_show_qt_window: qt_widget size={qt_widget.width()}x{qt_widget.height()}", file=sys.stderr)

        view = _ct.c_void_p(int(qt_widget.winId()))

        # Resize Qt's view to fill the window (fixes zoom if Qt used native pixels).
        _msg(view, "setFrame:", bounds, argtypes=[_CGRect], restype=None)

        _msg(key_window, "addSubview:", view, argtypes=[_ct.c_void_p])
        _msg(key_window, "bringSubviewToFront:", view, argtypes=[_ct.c_void_p])
        print("_ios_show_qt_window: Qt view embedded and raised", file=sys.stderr)
    except Exception as e:
        print(f"_ios_show_qt_window failed: {e}", file=sys.stderr)

if sys.platform == "ios":
    # Disable setlocale — iOS locale handling breaks Python's locale module.
    import locale as _locale
    _locale.setlocale = lambda *a, **kw: ""


# ── error helpers ─────────────────────────────────────────────────────────────

def _logs_dir() -> Path:
    logs = Path(os.path.expanduser("~")) / "Documents" / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    return logs


def _write_error_log(context: str, tb: str):
    try:
        ts = datetime.datetime.now().strftime("%Y-%m-%dT%H-%M-%S")
        path = _logs_dir() / f"{ts}_{context.replace('/', '_')}.err"
        path.write_text(f"Context: {context}\nTimestamp: {ts}\n\n{tb}\n")
        print(f"Error log: {path}", file=sys.stderr)
    except Exception as e:
        print(f"Failed to write error log: {e}", file=sys.stderr)


def _show_error_modal(title: str, tb: str, parent=None):
    print(f"ERROR DIALOG: {title}\n{tb}", file=sys.stderr)
    try:
        from PySide6.QtWidgets import QMessageBox
        dlg = QMessageBox(parent)
        dlg.setWindowTitle(title)
        dlg.setText(title)
        dlg.setDetailedText(tb)
        dlg.setIcon(QMessageBox.Icon.Critical)
        dlg.setStandardButtons(QMessageBox.StandardButton.Ok)
        dlg.exec()
    except Exception as e:
        print(f"Failed to show error modal: {e}", file=sys.stderr)


# ── script discovery ──────────────────────────────────────────────────────────

def _find_bundle_root() -> Path | None:
    """Return the app bundle root (the dir containing app/, app_packages/, Frameworks/).

    Works in both normal and hot-reload contexts.  In hot-reload, __file__
    resolves to ~/Documents/_app_override.py so parent traversal misses the
    bundle.  Instead we scan sys.path for an 'app' entry whose parent looks
    like a bundle — xcodebuild always puts {bundle}/app on PYTHONPATH.
    """
    # Fast path: __file__ is inside the bundle (non-hot-reload)
    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / "app_packages").is_dir() and (parent / "Frameworks").is_dir():
            return parent

    # Hot-reload fallback: find {bundle}/app on sys.path
    for entry in sys.path:
        p = Path(entry)
        if p.name == "app" and (p.parent / "app_packages").is_dir():
            return p.parent

    return None


def _get_script_dirs():
    """Return list of (label, Path) directories to scan for sub-app scripts."""
    dirs = []

    # Bundled example apps — always available without a separate deploy step.
    bundle_root = _find_bundle_root()
    if bundle_root is not None:
        bundled = bundle_root / "apps"
        if bundled.is_dir():
            dirs.append(("Built-in", bundled))

    docs = Path(os.path.expanduser("~")) / "Documents"
    docs.mkdir(parents=True, exist_ok=True)
    dirs.append(("Documents", docs))

    if sys.platform == "ios":
        from qtapp.platform.ios import get_icloud_documents_path
        icloud = get_icloud_documents_path()
        if icloud:
            icloud.mkdir(parents=True, exist_ok=True)
            dirs.append(("iCloud", icloud))

    return dirs


def _scan_scripts():
    """Return list of (label, Path) for all *.py and *.qml files in script dirs."""
    scripts = []
    for dir_label, directory in _get_script_dirs():
        try:
            for p in sorted(directory.glob("*.py")):
                scripts.append((f"[{dir_label}] {p.stem}", p))
            for p in sorted(directory.glob("*.qml")):
                scripts.append((f"[{dir_label}][QML] {p.stem}", p))
        except Exception as e:
            print(f"Error scanning {directory}: {e}", file=sys.stderr)
    return scripts


# ── dev menu button (floating AssistiveTouch-style) ───────────────────────────

def _make_dev_menu_button(parent, back_fn):
    from PySide6.QtWidgets import QWidget, QMenu, QGraphicsOpacityEffect, QApplication
    from PySide6.QtCore import Qt, QPoint, QPropertyAnimation, QEasingCurve, QTimer, Signal
    from PySide6.QtGui import QPainter, QColor, QPen

    SIZE = 56
    SNAP_MARGIN = 16
    IDLE_OPACITY = 0.30
    LIVE_OPACITY = 0.82

    class _AssistiveBtn(QWidget):
        _back_sig = Signal()

        def __init__(self, parent):
            super().__init__(parent)
            self._back_sig.connect(back_fn)
            self._drag_start_global = None
            self._drag_start_pos = None
            self._dragging = False
            self.setFixedSize(SIZE, SIZE)
            self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
            self._fx = QGraphicsOpacityEffect(self)
            self._fx.setOpacity(LIVE_OPACITY)
            self.setGraphicsEffect(self._fx)
            self._long_press = QTimer()
            self._long_press.setSingleShot(True)
            self._long_press.setInterval(500)
            self._long_press.timeout.connect(self._on_long_press)
            self._idle_timer = QTimer()
            self._idle_timer.setSingleShot(True)
            self._idle_timer.setInterval(2500)
            self._idle_timer.timeout.connect(self._fade_idle)
            self.hide()

        def paintEvent(self, event):
            p = QPainter(self)
            p.setRenderHint(QPainter.RenderHint.Antialiasing)
            sz = SIZE
            p.setBrush(QColor(255, 255, 255, 210))
            p.setPen(QPen(QColor(180, 180, 180, 160), 1.2))
            p.drawEllipse(2, 2, sz - 4, sz - 4)
            inner = int(sz * 0.38)
            m = (sz - inner) // 2
            p.setBrush(QColor(120, 120, 120, 200))
            p.setPen(Qt.PenStyle.NoPen)
            p.drawRoundedRect(m, m, inner, inner, 5, 5)
            p.end()

        def mousePressEvent(self, event):
            if event.button() != Qt.MouseButton.LeftButton:
                return
            self._drag_start_global = event.globalPosition().toPoint()
            self._drag_start_pos = self.pos()
            self._dragging = False
            app = QApplication.instance()
            QTimer.singleShot(0, app, self._long_press.start)
            QTimer.singleShot(0, app, self._idle_timer.stop)

        def mouseMoveEvent(self, event):
            if self._drag_start_global is None:
                return
            delta = event.globalPosition().toPoint() - self._drag_start_global
            if not self._dragging and (abs(delta.x()) > 8 or abs(delta.y()) > 8):
                self._dragging = True
                QTimer.singleShot(0, QApplication.instance(), self._long_press.stop)
            if self._dragging:
                new_pos = self._drag_start_pos + delta
                par = self.parent()
                new_pos.setX(max(0, min(new_pos.x(), par.width() - SIZE)))
                new_pos.setY(max(0, min(new_pos.y(), par.height() - SIZE)))
                self.move(new_pos)

        def mouseReleaseEvent(self, event):
            app = QApplication.instance()
            QTimer.singleShot(0, app, self._long_press.stop)
            if not self._dragging:
                self._back_sig.emit()
            else:
                QTimer.singleShot(0, app, self._snap_to_edge)
            self._drag_start_global = None
            self._drag_start_pos = None
            self._dragging = False
            QTimer.singleShot(0, app, self._idle_timer.start)

        def show(self):
            par = self.parent()
            w = par.width() or 390
            h = par.height() or 844
            self.move(w - SIZE - SNAP_MARGIN, max(120, h // 2))
            super().show()
            self.raise_()
            self._fx.setOpacity(LIVE_OPACITY)
            self._idle_timer.start()

        def hide(self):
            self._idle_timer.stop()
            super().hide()

        def _on_long_press(self):
            menu = QMenu(self)
            menu.setStyleSheet("font-size: 16px;")
            menu.addAction("Hide button", self.hide)
            menu.exec(self.mapToGlobal(QPoint(0, -menu.sizeHint().height())))

        def _fade_idle(self):
            self._fx.setOpacity(IDLE_OPACITY)

        def _snap_to_edge(self):
            par = self.parent()
            m = SNAP_MARGIN
            snap_x = m if (self.x() + SIZE // 2 < par.width() // 2) else (par.width() - SIZE - m)
            snap_y = max(60, min(self.y(), par.height() - SIZE - 40))
            anim = QPropertyAnimation(self, b"pos", self)
            anim.setDuration(260)
            anim.setEasingCurve(QEasingCurve.Type.OutCubic)
            anim.setEndValue(QPoint(snap_x, snap_y))
            anim.start(QPropertyAnimation.DeletionPolicy.DeleteWhenStopped)

    return _AssistiveBtn(parent)


# ── picker widget ─────────────────────────────────────────────────────────────

def _make_picker_widget(launch_fn):
    from PySide6.QtWidgets import (
        QWidget, QVBoxLayout, QHBoxLayout, QLabel,
        QListWidget, QListWidgetItem, QPushButton, QFileDialog,
    )
    from PySide6.QtCore import Qt

    root = QWidget()
    layout = QVBoxLayout()
    layout.setContentsMargins(20, 60, 20, 30)
    layout.setSpacing(12)

    title = QLabel("App Launcher")
    title.setAlignment(Qt.AlignmentFlag.AlignCenter)
    title.setStyleSheet("font-size: 24px; font-weight: bold;")
    layout.addWidget(title)

    list_widget = QListWidget()
    list_widget.setStyleSheet("font-size: 16px;")
    layout.addWidget(list_widget, stretch=1)

    btn_row = QHBoxLayout()
    refresh_btn = QPushButton("⟳ Refresh")
    browse_btn = QPushButton("📂 Browse")
    launch_btn = QPushButton("▶ Launch")
    for btn in (refresh_btn, browse_btn, launch_btn):
        btn.setStyleSheet("font-size: 16px; padding: 10px;")
    launch_btn.setStyleSheet("font-size: 16px; padding: 10px; font-weight: bold;")
    btn_row.addWidget(refresh_btn)
    btn_row.addWidget(browse_btn)
    btn_row.addWidget(launch_btn)
    layout.addLayout(btn_row)

    scripts = []

    def refresh():
        nonlocal scripts
        list_widget.clear()
        scripts = _scan_scripts()
        if scripts:
            for label, _ in scripts:
                list_widget.addItem(QListWidgetItem(label))
        else:
            list_widget.addItem(QListWidgetItem("(no .py files found — drop scripts in Documents)"))

    def on_launch():
        row = list_widget.currentRow()
        if 0 <= row < len(scripts):
            _, path = scripts[row]
            launch_fn(path)

    def on_browse():
        path, _ = QFileDialog.getOpenFileName(root, "Select Script", "", "Scripts (*.py *.qml);;Python (*.py);;QML (*.qml)")
        if path:
            launch_fn(Path(path))

    refresh_btn.clicked.connect(refresh)
    browse_btn.clicked.connect(on_browse)
    launch_btn.clicked.connect(on_launch)
    list_widget.itemDoubleClicked.connect(lambda _: on_launch())
    refresh()
    root.setLayout(layout)
    return root


# ── sub-app loading ───────────────────────────────────────────────────────────

def _make_subapp_widget(script_path: Path, back_fn):
    from PySide6.QtWidgets import QWidget, QVBoxLayout, QLabel, QScrollArea

    wrapper = QWidget()
    layout = QVBoxLayout()
    layout.setContentsMargins(0, 0, 0, 0)
    layout.setSpacing(0)

    try:
        content = _load_subapp_widget(script_path, back_fn)
    except Exception:
        tb = traceback.format_exc()
        print(f"ERROR loading {script_path}:\n{tb}", file=sys.stderr)
        _write_error_log(script_path.stem, tb)
        _show_error_modal(f"Error in {script_path.name}", tb, parent=wrapper)
        error_label = QLabel(f"Error loading {script_path.name}:\n\n{tb}")
        error_label.setStyleSheet("font-size: 12px; color: red; padding: 12px;")
        error_label.setWordWrap(True)
        scroll = QScrollArea()
        scroll.setWidget(error_label)
        scroll.setWidgetResizable(True)
        content = scroll

    layout.addWidget(content, stretch=1)
    wrapper.setLayout(layout)
    return wrapper


def _load_subapp_widget(script_path: Path, back_fn):
    from PySide6.QtWidgets import QLabel

    # ── QML file: wrap in QQuickWidget ───────────────────────────────────────
    if script_path.suffix == ".qml":
        from PySide6.QtQuickWidgets import QQuickWidget
        from PySide6.QtCore import QUrl

        if sys.platform == "ios":
            # Load Qt framework binaries so their global constructors run.
            # The constructors create QQmlModuleRegistration objects that
            # register deferred type-registration callbacks.  Those callbacks
            # are triggered automatically when the QML engine first imports
            # each module — we do NOT call them manually here because doing
            # so before the engine exists causes double-registration conflicts.
            import ctypes as _ct
            import tempfile as _tmpfile
            bundle_root = _find_bundle_root()
            if bundle_root:
                _fw_dir = bundle_root / "Frameworks"
                for _fw_name in (
                    "QtQuick", "QtQuickTemplates2", "QtQuickControls2Impl",
                    "QtQuickControls2", "QtQuickControls2Basic", "QtQuickLayouts",
                ):
                    _fw_bin = _fw_dir / f"{_fw_name}.framework" / _fw_name
                    if _fw_bin.exists():
                        try:
                            _ct.CDLL(str(_fw_bin))
                        except OSError:
                            pass

            # Both qrc import paths (qrc:/qt/qml and qrc:/qt-project.org/imports)
            # Both qrc import paths contain qmldirs with "plugin" directives
            # for plugin binaries that don't exist on a dynamic iOS build.
            # We replace them with minimal disk-based stubs that have NO plugin
            # directive.  The actual types were registered above by calling the
            # qml_register_types_* functions directly via ctypes.
            #
            # QtQuick.Controls qmldir needs "default import QtQuick.Controls.Basic
            # auto" so the engine automatically imports the Basic style and
            # exposes SpinBox, Label, Button, etc.

            from PySide6.QtQml import QQmlEngine
            from PySide6.QtCore import QFile, QIODevice
            from PySide6.QtQuickControls2 import QQuickStyle
            QQuickStyle.setStyle("Basic")

            # Read the real qmldir from qrc, strip directives that require
            # plugins (which don't exist in a dynamic iOS PySide6 build), and
            # return (cleaned_text, qrc_prefix) so QML files can be copied.
            def _read_qrc_qmldir(rel_path):
                for _pfx in (":/qt/qml/", ":/qt-project.org/imports/"):
                    _f = QFile(_pfx + rel_path + "/qmldir")
                    if _f.open(QIODevice.OpenModeFlag.ReadOnly):
                        _txt = bytes(_f.readAll()).decode("utf-8", errors="replace")
                        _f.close()
                        _prefer_base = _pfx + rel_path + "/"
                        _lines = []
                        for _l in _txt.splitlines():
                            if (_l.startswith("plugin ")
                                    or _l.startswith("optional plugin ")
                                    or _l.startswith("classname ")):
                                continue
                            # "default import" is a non-standard Qt Quick
                            # Controls extension processed by the plugin;
                            # the engine only understands "import Module".
                            if _l.startswith("default import "):
                                _l = _l[len("default "):]
                            # Strip "prefer" — QML files are copied locally
                            # so the engine never loads from qrc (re-reading
                            # the qrc qmldir would re-expose the broken plugin
                            # directive and mark the module unavailable).
                            if _l.startswith("prefer "):
                                _prefer_base = _l[len("prefer "):].strip()
                                if not _prefer_base.endswith("/"):
                                    _prefer_base += "/"
                                continue
                            _lines.append(_l)
                        return "\n".join(_lines) + "\n", _prefer_base
                return None, None

            # Copy every .qml / .js file referenced in a processed qmldir from
            # qrc to the local stub directory so the engine stays on-disk.
            def _copy_qrc_qml_files(qmldir_text, prefer_base, dest_dir):
                for _line in qmldir_text.splitlines():
                    _tok = _line.split()
                    # type lines: [qualifier] ComponentName version File.qml
                    for _t in _tok:
                        if _t.endswith(".qml") or _t.endswith(".js"):
                            _src_path = prefer_base + _t
                            _dst_path = dest_dir / _t
                            if _dst_path.exists():
                                break
                            _qf = QFile(_src_path)
                            if _qf.open(QIODevice.OpenModeFlag.ReadOnly):
                                _data = bytes(_qf.readAll())
                                _qf.close()
                                _dst_path.write_bytes(_data)
                            break

            _stub_dir = Path(_tmpfile.mkdtemp())
            _module_map = {
                "QtQuick":                    "QtQuick",
                "QtQuick.Templates":          "QtQuick/Templates",
                "QtQuick.Controls.impl":      "QtQuick/Controls/impl",
                "QtQuick.Controls.Basic":     "QtQuick/Controls/Basic",
                "QtQuick.Layouts":            "QtQuick/Layouts",
                "QtQuick.Controls":           "QtQuick/Controls",
                # Empty stubs for all style overrides to block them from loading
                # their qrc qmldirs which have broken plugin directives AND
                # type overrides that corrupt the Basic type registrations.
                "QtQuick.Controls.iOS":       "QtQuick/Controls/iOS",
                "QtQuick.Controls.Material":  "QtQuick/Controls/Material",
                "QtQuick.Controls.Fusion":    "QtQuick/Controls/Fusion",
                "QtQuick.Controls.Imagine":   "QtQuick/Controls/Imagine",
                "QtQuick.Controls.Universal": "QtQuick/Controls/Universal",
            }
            _style_overrides = {
                "QtQuick.Controls.iOS", "QtQuick.Controls.Material",
                "QtQuick.Controls.Fusion", "QtQuick.Controls.Imagine",
                "QtQuick.Controls.Universal",
            }
            for _uri, _rel in _module_map.items():
                _d = _stub_dir / _rel
                _d.mkdir(parents=True, exist_ok=True)
                if _uri in _style_overrides:
                    # Empty stub — prevent qrc version (with plugin + type overrides) from loading
                    _body = f"module {_uri}\n"
                else:
                    _body, _prefer_base = _read_qrc_qmldir(_rel)
                    if _body is None:
                        _body = f"module {_uri}\n"
                        if _uri == "QtQuick.Controls":
                            _body += "import QtQuick.Controls.Basic auto\n"
                    elif _prefer_base:
                        # Copy every QML/JS file referenced in this module's
                        # qmldir from qrc into the stub directory so the engine
                        # never loads from qrc (avoids secondary qmldir reload
                        # which would re-expose the broken plugin directive).
                        _copy_qrc_qml_files(_body, _prefer_base, _d)
                (_d / "qmldir").write_text(_body)

            _engine = QQmlEngine()

            # Call type registration functions now that the engine exists.
            # These are normally called by the plugin's registerTypes() entry
            # point.  We call them directly so the engine's type registry is
            # populated before any QML is compiled.
            if bundle_root:
                _REG_SYMS = (
                    ("QtQuick",             "_Z26qml_register_types_QtQuickv"),
                    ("QtQuickTemplates2",    "_Z36qml_register_types_QtQuick_Templatesv"),
                    ("QtQuickControls2Impl", "_Z40qml_register_types_QtQuick_Controls_implv"),
                    ("QtQuickControls2",     "_Z35qml_register_types_QtQuick_Controlsv"),
                    ("QtQuickControls2Basic","_Z41qml_register_types_QtQuick_Controls_Basicv"),
                    ("QtQuickLayouts",       "_Z34qml_register_types_QtQuick_Layoutsv"),
                )
                _fw_dir = bundle_root / "Frameworks"
                for _fw_name, _sym in _REG_SYMS:
                    _fw_bin = _fw_dir / f"{_fw_name}.framework" / _fw_name
                    if not _fw_bin.exists():
                        continue
                    try:
                        _lib = _ct.CDLL(str(_fw_bin))
                    except OSError as _e:
                        print(f"[qtapp] CDLL {_fw_name}: {_e}", file=sys.stderr)
                        continue
                    _fn = getattr(_lib, _sym, None)
                    if _fn is None:
                        continue
                    try:
                        _fn.restype = None
                        _fn.argtypes = []
                        _fn()
                    except Exception as _e:
                        print(f"[qtapp] reg error {_fw_name}: {_e}", file=sys.stderr)


            # ── resolve QML stubs directory ───────────────────────────────
            # Preferred: pre-built stubs bundled by the Xcode build phase
            # (scripts/ios/prepare_qml_stubs.py → {bundle}/qml_stubs/).
            # Fallback: extract from qrc at runtime into a temp directory.
            # The stubs replace qrc qmldirs that have broken "plugin"
            # directives for .so files that don't exist on iOS.
            _bundled = bundle_root / "qml_stubs" if bundle_root else None
            if _bundled and _bundled.is_dir():
                _stubs_path = str(_bundled)
            else:
                _stubs_path = str(_stub_dir)

            _paths = list(_engine.importPathList())
            _paths.insert(0, _stubs_path)
            _engine.setImportPathList(_paths)

            w = QQuickWidget(_engine, None)
            w._qml_engine = _engine
        else:
            w = QQuickWidget()

        w.setResizeMode(QQuickWidget.ResizeMode.SizeRootObjectToView)
        w.setSource(QUrl.fromLocalFile(str(script_path)))
        if w.status() == QQuickWidget.Status.Error:
            errors = "\n".join(e.toString() for e in w.errors())
            raise RuntimeError(f"QML load errors:\n{errors}")
        return w

    # ── Python script: load module, look for create_widget / create_qml_engine
    spec = importlib.util.spec_from_file_location(script_path.stem, script_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    if hasattr(mod, "create_widget"):
        return mod.create_widget(back_fn)

    if hasattr(mod, "create_qml_engine"):
        # create_qml_engine(back_fn) → QQmlApplicationEngine
        # Embed the root QML object into a QQuickWidget for stack compatibility.
        from PySide6.QtQuickWidgets import QQuickWidget
        from PySide6.QtCore import QUrl
        engine = mod.create_qml_engine(back_fn)
        root_objects = engine.rootObjects()
        if root_objects:
            w = QQuickWidget()
            w.setResizeMode(QQuickWidget.ResizeMode.SizeRootObjectToView)
            # Keep engine alive alongside the widget.
            w._qml_engine = engine
            qml_file = engine.rootObjects()[0].property("source") if root_objects else None
            if qml_file:
                w.setSource(QUrl(qml_file))
            return w
        label = QLabel("create_qml_engine returned engine with no root objects.")
        label.setStyleSheet("font-size: 14px; padding: 20px; color: orange;")
        return label

    label = QLabel(
        f"Loaded '{script_path.name}'.\n\n"
        "Define one of:\n"
        "  create_widget(back_fn) → QWidget\n"
        "  create_qml_engine(back_fn) → QQmlApplicationEngine\n"
        "Or drop a .qml file directly."
    )
    label.setWordWrap(True)
    label.setStyleSheet("font-size: 16px; padding: 20px;")
    return label


# ── launch request / CLI args ─────────────────────────────────────────────────

def _resolve_launch_script(name_or_path: str) -> Path | None:
    p = Path(name_or_path)
    if p.is_absolute():
        return p if p.exists() else None
    docs = Path(os.path.expanduser("~")) / "Documents"
    for ext in (".py", ".qml"):
        candidate = docs / f"{name_or_path}{ext}"
        if candidate.exists():
            return candidate
    return None


def _handle_launch_args(launcher) -> None:
    """Auto-launch a sub-app from _launch_request.txt or --app/--file CLI args."""
    req_file = Path(os.path.expanduser("~")) / "Documents" / "_launch_request.txt"
    target = None
    if req_file.exists():
        try:
            target = req_file.read_text().strip()
            req_file.unlink()
            print(f"_handle_launch_args: request file → '{target}'", file=sys.stderr)
        except Exception as e:
            print(f"_handle_launch_args: could not read request file: {e}", file=sys.stderr)

    if not target:
        import argparse
        parser = argparse.ArgumentParser(add_help=False)
        parser.add_argument("--app", default=None)
        parser.add_argument("--file", default=None)
        parsed, _ = parser.parse_known_args(sys.argv[1:])
        target = parsed.app or parsed.file
        if target:
            print(f"_handle_launch_args: sys.argv → '{target}'", file=sys.stderr)

    if not target:
        return

    script = _resolve_launch_script(target)
    if not script:
        print(f"WARNING: _handle_launch_args: '{target}' not found", file=sys.stderr)
        return

    print(f"_handle_launch_args: auto-launching {script}", file=sys.stderr)

    # On iOS, QTimer.singleShot isn't reliable before the event loop is live.
    # Hook applicationStateChanged which fires on first app-active from within
    # the running event loop.
    qt_app = sys.modules.get("_qtapp_instance")
    if qt_app is None:
        print("WARNING: _handle_launch_args: QApplication not in sys.modules", file=sys.stderr)
        return

    from PySide6.QtCore import Qt
    _fired = [False]

    def _on_active(state):
        if state == Qt.ApplicationState.ApplicationActive and not _fired[0]:
            _fired[0] = True
            try:
                qt_app.applicationStateChanged.disconnect(_on_active)
            except Exception:
                pass
            print("_handle_launch_args: applicationStateChanged → scheduling launch", file=sys.stderr)
            from PySide6.QtCore import QTimer
            QTimer.singleShot(0, qt_app, lambda: launcher._launch(script))

    qt_app.applicationStateChanged.connect(_on_active)
    print("_handle_launch_args: applicationStateChanged connected", file=sys.stderr)


# ── main launcher class ───────────────────────────────────────────────────────

class Launcher:
    def __init__(self, qt_app):
        self._qt_app = qt_app
        self._root = None
        self._stack = None
        self._dev_menu = None
        self._setup_ui()

    def _setup_ui(self):
        from PySide6.QtWidgets import QWidget, QStackedWidget, QVBoxLayout

        self._root = QWidget()
        root_layout = QVBoxLayout(self._root)
        root_layout.setContentsMargins(0, 0, 0, 0)
        root_layout.setSpacing(0)

        self._stack = QStackedWidget()
        root_layout.addWidget(self._stack)

        self._dev_menu = _make_dev_menu_button(self._root, back_fn=self._back)

        picker = _make_picker_widget(self._launch)
        self._stack.addWidget(picker)
        self._stack.setCurrentIndex(0)
        self._root.showMaximized()

        # Store root widget for platform code that needs the native window handle.
        sys.modules["_qtapp_root_widget"] = self._root

        if sys.platform == "ios":
            from PySide6.QtCore import QTimer
            # Defer to after the first event-loop iteration so Qt's QUIWindow
            # has been fully created, then make it the key visible window.
            # Inlined here (not imported from ios.py) so hot-reload works
            # without a full rebuild whenever this file changes.
            QTimer.singleShot(100, self._root, lambda: _ios_show_qt_window(self._root))

    def _launch(self, script_path: Path):
        while self._stack.count() > 1:
            w = self._stack.widget(1)
            self._stack.removeWidget(w)
            w.deleteLater()
        try:
            sub = _make_subapp_widget(script_path, self._back)
        except Exception:
            tb = traceback.format_exc()
            print(f"ERROR in _launch {script_path}:\n{tb}", file=sys.stderr)
            _write_error_log(script_path.stem, tb)
            _show_error_modal(f"Launch Error: {script_path.name}", tb)
            return
        self._stack.addWidget(sub)
        self._stack.setCurrentIndex(1)
        self._dev_menu.show()
        print(f"Sub-app launch succeeded: {script_path}", file=sys.stderr)

    def _back(self):
        self._dev_menu.hide()
        self._stack.setCurrentIndex(0)
        # Refresh the picker list
        from PySide6.QtWidgets import QPushButton
        picker = self._stack.widget(0)
        for btn in picker.findChildren(QPushButton):
            if "Refresh" in btn.text():
                btn.click()
                break


# ── bootstrap shim (for platform bootstrappers that call main().main_loop()) ──

class _Bootstrap:
    """Returned by main() so platform bootstrappers can call main_loop()."""
    def main_loop(self):
        if sys.platform == "ios":
            # Qt's iOS platform plugin (QIOSIntegration) integrates with
            # CFRunLoop automatically when QApplication is created.  Calling
            # exec() here would block inside applicationDidFinishLaunching:,
            # starving the run loop and triggering the watchdog.  Return and
            # let UIApplicationMain drive the event loop instead.
            return
        from PySide6.QtWidgets import QApplication
        sys.exit(QApplication.exec())


# ── entry point ───────────────────────────────────────────────────────────────

def main():
    # Hot-reload: if _app_override.py exists in Documents, execute it instead.
    _sentinel = "_qtapp_override_active"
    _override = Path(os.path.expanduser("~")) / "Documents" / "_app_override.py"
    if _override.exists() and _sentinel not in sys.modules:
        sys.modules[_sentinel] = True
        print(f"Hot-reload: {_override}", file=sys.stderr)
        _spec = importlib.util.spec_from_file_location("qtapp.app", _override)
        _mod = importlib.util.module_from_spec(_spec)
        sys.modules["qtapp.app"] = _mod
        try:
            _spec.loader.exec_module(_mod)
            if hasattr(_mod, "main"):
                return _mod.main()
        except Exception:
            print(f"Hot-reload FAILED:\n{traceback.format_exc()}", file=sys.stderr)

    from PySide6.QtWidgets import QApplication
    qt_app = QApplication.instance() or QApplication(sys.argv)
    qt_app.setQuitOnLastWindowClosed(False)

    # Store for _handle_launch_args (QApplication.instance() unreliable early on iOS).
    sys.modules["_qtapp_instance"] = qt_app

    try:
        launcher = Launcher(qt_app)
    except Exception:
        tb = traceback.format_exc()
        print(f"FATAL: launcher init failed:\n{tb}", file=sys.stderr)
        _write_error_log("startup", tb)
        return _Bootstrap()

    if sys.platform == "ios":
        from qtapp.platform import ios as _ios
        from urllib.parse import urlparse, parse_qs

        def _url_handler(url_str: str) -> bool:
            # Handles  <scheme>://<name>  and  <scheme>://launch?app=<name>
            # where <name> is a script in ~/Documents.
            try:
                parsed = urlparse(url_str)
                query  = parse_qs(parsed.query)
                name   = (query.get("app") or query.get("file") or [None])[0]
                if name is None:
                    # path component: myapp://script-name  or  myapp://launch/script-name
                    path_part = parsed.netloc or parsed.path.strip("/")
                    if path_part and path_part != "launch":
                        name = path_part
                if name:
                    script = _resolve_launch_script(name)
                    if script:
                        from PySide6.QtCore import QTimer
                        QTimer.singleShot(0, qt_app,
                                          lambda s=script: launcher._launch(s))
                        return True
                    print(f"URL scheme: script '{name}' not found", file=sys.stderr)
            except Exception as e:
                print(f"URL handler error: {e}", file=sys.stderr)
            return False

        _ios.register_url_handler(_url_handler)

    _handle_launch_args(launcher)

    return _Bootstrap()
