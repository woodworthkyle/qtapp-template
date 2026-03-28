"""
iOS platform utilities — no Rubicon, no Toga; pure ctypes.

All public functions are safe to call on non-iOS platforms (they no-op).
"""

import sys
import ctypes
from pathlib import Path


# ── minimal ObjC messenger ────────────────────────────────────────────────────

if sys.platform == "ios":
    _libobjc = ctypes.CDLL(None)

    _libobjc.objc_getClass.restype      = ctypes.c_void_p
    _libobjc.objc_getClass.argtypes     = [ctypes.c_char_p]
    _libobjc.sel_registerName.restype   = ctypes.c_void_p
    _libobjc.sel_registerName.argtypes  = [ctypes.c_char_p]
    _libobjc.class_addMethod.restype    = ctypes.c_bool
    _libobjc.class_addMethod.argtypes   = [
        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p,
    ]

    def _cls(name: str) -> int:
        return _libobjc.objc_getClass(name.encode())

    def _sel(name: str) -> int:
        return _libobjc.sel_registerName(name.encode())

    def _msg(obj, sel_name: str, *args,
             restype=ctypes.c_void_p, argtypes: list | None = None):
        _libobjc.objc_msgSend.restype  = restype
        _libobjc.objc_msgSend.argtypes = [ctypes.c_void_p, ctypes.c_void_p] + (argtypes or [])
        return _libobjc.objc_msgSend(obj, _sel(sel_name), *args)

    def _ns_string(s: str) -> int:
        return _msg(_cls("NSString"), "stringWithUTF8String:", s.encode(),
                    argtypes=[ctypes.c_char_p])

    def _ns_string_to_py(ns_str: int) -> str | None:
        if not ns_str:
            return None
        raw = _msg(ns_str, "UTF8String", restype=ctypes.c_char_p)
        return raw.decode() if raw else None


# ── iCloud ────────────────────────────────────────────────────────────────────

def get_icloud_documents_path(container_id: str | None = None) -> Path | None:
    """Return path to <iCloud container>/Documents, or None if unavailable.

    container_id defaults to the app's own iCloud container as configured in
    the Xcode entitlements (pass None to let iOS pick the default container).
    On non-iOS platforms this always returns None.
    """
    if sys.platform != "ios":
        return None
    try:
        fm = _msg(_cls("NSFileManager"), "defaultManager")
        ns_id = _ns_string(container_id) if container_id else None
        url = _msg(fm, "URLForUbiquityContainerIdentifier:", ns_id or 0,
                   argtypes=[ctypes.c_void_p])
        if not url:
            print("iCloud container not available", file=sys.stderr)
            return None
        path_ns = _msg(url, "path")
        path_str = _ns_string_to_py(path_ns)
        if path_str:
            p = Path(path_str) / "Documents"
            print(f"iCloud container: {p}", file=sys.stderr)
            return p
    except Exception as e:
        print(f"iCloud lookup failed: {e}", file=sys.stderr)
    return None


# ── show Qt window ────────────────────────────────────────────────────────────

def show_qt_window(qt_widget) -> None:
    """Make Qt's native QUIWindow key and visible.

    On iOS 13+, a UIWindow must have its windowScene set or it won't display.
    Qt creates a QUIWindow during showMaximized() but it may not have the
    correct windowScene assigned when our own AppDelegate UIWindow is already
    key.  This function:
      1. Finds Qt's actual QUIWindow via the widget's native view handle.
      2. Copies the windowScene from the current key window onto Qt's window.
      3. Calls makeKeyAndVisible on Qt's window (not addSubview — that causes
         coordinate-space zoom).
    """
    if sys.platform != "ios":
        return
    try:
        view_ptr = int(qt_widget.winId())
        qt_view = ctypes.c_void_p(view_ptr)

        # Qt's native window (QUIWindow) — the UIWindow containing Qt's view.
        qt_window = _msg(qt_view, "window")
        if not qt_window:
            print("show_qt_window: Qt's QUIWindow not yet created", file=sys.stderr)
            return

        # Copy the windowScene from the existing key window so that Qt's
        # window is associated with the active UIWindowScene (required iOS 13+).
        shared_app = _msg(_cls("UIApplication"), "sharedApplication")
        key_window = _msg(shared_app, "keyWindow")
        if key_window:
            scene = _msg(key_window, "windowScene")
            if scene:
                _msg(ctypes.c_void_p(qt_window), "setWindowScene:",
                     ctypes.c_void_p(scene), argtypes=[ctypes.c_void_p])

        # Make Qt's window the key visible window.
        _msg(ctypes.c_void_p(qt_window), "makeKeyAndVisible")
        print("show_qt_window: Qt QUIWindow made key and visible", file=sys.stderr)
    except Exception as e:
        print(f"show_qt_window failed: {e}", file=sys.stderr)


# ── URL scheme handler ────────────────────────────────────────────────────────
#
# AppDelegate.m (our ObjC bootstrap) implements application:openURL:options:
# natively and calls _handle_open_url(url_str) here when a URL arrives.
#
# Apps register a handler with register_url_handler(fn) during startup.
# fn receives the full URL string and should return True if it handled it.
#
# Multiple handlers are supported (called in registration order, first True
# return wins).  This lets qtapp's launcher and an app's own code both respond.
#
# URL scheme name (e.g. "myapp://") is set per-app in Info.plist under
# CFBundleURLTypes/CFBundleURLSchemes.  Python code doesn't need to know the
# scheme name — it receives whatever URL the OS delivers.

_url_handlers: list = []


def register_url_handler(fn) -> None:
    """Register a callable to receive incoming URLs.

    fn(url_str: str) -> bool
        Return True if the URL was handled (stops further dispatch).
        Return False / None to pass to the next registered handler.

    Safe to call on non-iOS platforms (registers but never fires).
    """
    _url_handlers.append(fn)


def _handle_open_url(url_str: str) -> None:
    """Called by AppDelegate when the OS delivers a URL to the app.

    Dispatches to registered handlers in order.  Not intended to be called
    directly by app code — use register_url_handler() instead.
    """
    print(f"ios: openURL: {url_str}", file=sys.stderr)
    for fn in _url_handlers:
        try:
            if fn(url_str):
                return
        except Exception as e:
            print(f"ios: url handler {fn!r} raised: {e}", file=sys.stderr)
    print(f"ios: no handler claimed URL: {url_str}", file=sys.stderr)
