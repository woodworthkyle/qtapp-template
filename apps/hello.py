"""
hello.py — minimal qtapp sub-app example.

Demonstrates the sub-app contract:
    def create_widget(back_fn: Callable) -> QWidget

Drop this file in ~/Documents/ on the device (or run via deploy script)
and it will appear in the launcher's script list.
"""

from PySide6.QtWidgets import QWidget, QVBoxLayout, QLabel, QPushButton
from PySide6.QtCore import Qt


def create_widget(back_fn):
    root = QWidget()
    layout = QVBoxLayout(root)
    layout.setContentsMargins(40, 80, 40, 40)
    layout.setSpacing(20)
    layout.setAlignment(Qt.AlignmentFlag.AlignCenter)

    label = QLabel("Hello from qtapp!")
    label.setAlignment(Qt.AlignmentFlag.AlignCenter)
    label.setStyleSheet("font-size: 28px; font-weight: bold;")
    layout.addWidget(label)

    sub = QLabel("This is a minimal sub-app.\nDefine create_widget(back_fn) in any .py file.")
    sub.setAlignment(Qt.AlignmentFlag.AlignCenter)
    sub.setWordWrap(True)
    sub.setStyleSheet("font-size: 16px; color: #666;")
    layout.addWidget(sub)

    btn = QPushButton("← Back")
    btn.setStyleSheet("font-size: 18px; padding: 12px 32px;")
    btn.clicked.connect(back_fn)
    layout.addWidget(btn, alignment=Qt.AlignmentFlag.AlignCenter)

    return root
