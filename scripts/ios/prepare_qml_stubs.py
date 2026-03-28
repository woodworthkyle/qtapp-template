#!/usr/bin/env python3
"""
prepare_qml_stubs.py — Xcode build phase helper for iOS QML module stubs.

Qt's qrc-embedded qmldirs reference plugin .so files that don't exist in a
dynamic PySide6 iOS build.  This script extracts the QML module files from the
macOS PySide6 installation, strips the iOS-incompatible directives, and writes
the result to DEST_DIR so the Xcode build can bundle them.

At runtime the iOS engine is pointed at the bundled stubs (which have no plugin
directive), so it never touches the qrc qmldirs and never tries to dlopen a
missing plugin.

NOTE: This script uses whatever PySide6 is importable from PYSIDE6_PYTHON (or
python3 in PATH).  That version should ideally match the iOS PySide6 wheel; for
stable controls (Button, Label, SpinBox, etc.) a minor-version mismatch is safe.
Set PYSIDE6_PYTHON in config.env to pin the correct interpreter, e.g.:
    PYSIDE6_PYTHON=/path/to/conda/envs/my_env/bin/python3

Usage (called by xcodegen.yml build phase):
    python3 scripts/ios/prepare_qml_stubs.py --dest <output_dir>
"""

import argparse
import sys
from pathlib import Path

# ── Modules to stub out ───────────────────────────────────────────────────────
# Maps QML module URI → relative path used in the import filesystem.
MODULES: dict[str, str] = {
    "QtQuick":                    "QtQuick",
    "QtQuick.Templates":          "QtQuick/Templates",
    "QtQuick.Controls.impl":      "QtQuick/Controls/impl",
    "QtQuick.Controls.Basic":     "QtQuick/Controls/Basic",
    "QtQuick.Layouts":            "QtQuick/Layouts",
    "QtQuick.Controls":           "QtQuick/Controls",
    # Style-override modules: empty stubs so the qrc versions (which have
    # plugin directives AND type overrides that corrupt Basic registration)
    # are never loaded.
    "QtQuick.Controls.iOS":       "QtQuick/Controls/iOS",
    "QtQuick.Controls.Material":  "QtQuick/Controls/Material",
    "QtQuick.Controls.Fusion":    "QtQuick/Controls/Fusion",
    "QtQuick.Controls.Imagine":   "QtQuick/Controls/Imagine",
    "QtQuick.Controls.Universal": "QtQuick/Controls/Universal",
}

STYLE_OVERRIDES: frozenset[str] = frozenset({
    "QtQuick.Controls.iOS",
    "QtQuick.Controls.Material",
    "QtQuick.Controls.Fusion",
    "QtQuick.Controls.Imagine",
    "QtQuick.Controls.Universal",
})


def find_pyside6_qml() -> Path:
    """Return the PySide6 QML root directory (handles pip and conda layouts)."""
    import PySide6
    base = Path(PySide6.__file__).parent
    # pip layout: PySide6/Qt/qml  or  PySide6/qml
    for candidate in (base / "Qt" / "qml", base / "qml"):
        if (candidate / "QtQuick").is_dir():
            return candidate
    # conda layout: $CONDA_PREFIX/lib/qt6/qml
    prefix = Path(sys.prefix)
    for candidate in (
        prefix / "lib" / "qt6" / "qml",
        prefix / "lib" / "qt" / "qml",
        prefix / "share" / "qt6" / "qml",
    ):
        if (candidate / "QtQuick").is_dir():
            return candidate
    raise RuntimeError(
        f"Cannot find PySide6 QML directory.\n"
        f"  Checked under {base} (pip layout)\n"
        f"  Checked under {prefix}/lib/qt6/qml (conda layout)\n"
        "Make sure PySide6 is installed in the Python used by this script.\n"
        "Set PYSIDE6_PYTHON in config.env to specify the interpreter."
    )


def clean_qmldir(text: str) -> str:
    """Strip iOS-incompatible directives and fix non-standard ones."""
    lines = []
    for raw in text.splitlines():
        line = raw.rstrip()
        stripped = line.lstrip()
        # Drop: plugin loader lines (no .so on iOS), classname (plugin metadata),
        # linktarget (static-link hint), typeinfo (plugin metadata),
        # and prefer (redirect to qrc — we serve files locally instead).
        if any(stripped.startswith(pfx) for pfx in (
            "plugin ", "optional plugin ",
            "classname ", "linktarget ",
            "typeinfo ", "prefer ",
        )):
            continue
        # "default import" is a non-standard Qt Quick Controls extension
        # processed only by the plugin; the QML engine ignores it.
        # Convert to a standard "import" the engine understands.
        if stripped.startswith("default import "):
            line = line.replace("default import ", "import ", 1)
        lines.append(line)
    return "\n".join(lines) + "\n"


def copy_qml_files(qmldir_text: str, src_dir: Path, dest_dir: Path) -> int:
    """Copy every .qml / .js file referenced in qmldir_text from src to dest."""
    copied = 0
    for line in qmldir_text.splitlines():
        tokens = line.split()
        for token in tokens:
            if token.endswith(".qml") or token.endswith(".js"):
                src = src_dir / token
                dst = dest_dir / token
                if src.exists() and not dst.exists():
                    dst.write_bytes(src.read_bytes())
                    copied += 1
                break
    return copied


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dest", required=True,
                        help="Output directory (will be created if needed)")
    args = parser.parse_args()

    dest = Path(args.dest)

    try:
        qml_root = find_pyside6_qml()
    except (ImportError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

    import PySide6
    print(f"prepare_qml_stubs: PySide6 {PySide6.__version__} → {dest}", file=sys.stderr)

    for uri, rel in MODULES.items():
        out_dir = dest / rel
        out_dir.mkdir(parents=True, exist_ok=True)

        if uri in STYLE_OVERRIDES:
            (out_dir / "qmldir").write_text(f"module {uri}\n")
            continue

        src_dir = qml_root / rel
        src_qmldir = src_dir / "qmldir"

        if not src_qmldir.exists():
            print(f"  WARNING: {src_qmldir} not found — writing minimal stub",
                  file=sys.stderr)
            body = f"module {uri}\n"
            if uri == "QtQuick.Controls":
                body += "import QtQuick.Controls.Basic auto\n"
            (out_dir / "qmldir").write_text(body)
            continue

        raw = src_qmldir.read_text(encoding="utf-8", errors="replace")
        cleaned = clean_qmldir(raw)
        (out_dir / "qmldir").write_text(cleaned)
        n = copy_qml_files(cleaned, src_dir, out_dir)
        print(f"  {uri}: {len(cleaned)}b qmldir + {n} QML files", file=sys.stderr)


if __name__ == "__main__":
    main()
