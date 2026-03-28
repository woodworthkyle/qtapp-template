"""
counter_widget.py — widget-based up/down counter example.

Demonstrates create_widget(back_fn) with QWidget, layouts, and signals.
Drop in ~/Documents/ and launch from the picker.
"""

from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QSpinBox,
)
from PySide6.QtCore import Qt


def create_widget(back_fn):
    root = QWidget()
    layout = QVBoxLayout(root)
    layout.setContentsMargins(40, 80, 40, 40)
    layout.setSpacing(24)
    layout.setAlignment(Qt.AlignmentFlag.AlignTop)

    title = QLabel("Counter")
    title.setAlignment(Qt.AlignmentFlag.AlignCenter)
    title.setStyleSheet("font-size: 28px; font-weight: bold;")
    layout.addWidget(title)

    count_label = QLabel("0")
    count_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
    count_label.setStyleSheet("font-size: 72px; font-weight: bold; color: #2196F3;")
    layout.addWidget(count_label)

    # Increment-by field
    inc_row = QHBoxLayout()
    inc_row.setSpacing(12)
    inc_label = QLabel("Increment by:")
    inc_label.setStyleSheet("font-size: 18px;")
    inc_spin = QSpinBox()
    inc_spin.setRange(1, 100)
    inc_spin.setValue(1)
    inc_spin.setStyleSheet("font-size: 18px; padding: 6px;")
    inc_row.addStretch()
    inc_row.addWidget(inc_label)
    inc_row.addWidget(inc_spin)
    inc_row.addStretch()
    layout.addLayout(inc_row)

    # Up / Down buttons
    btn_row = QHBoxLayout()
    btn_row.setSpacing(20)
    down_btn = QPushButton("▼ Down")
    up_btn   = QPushButton("▲ Up")
    for btn in (down_btn, up_btn):
        btn.setStyleSheet("font-size: 22px; padding: 14px 32px;")
        btn.setMinimumWidth(130)
    btn_row.addStretch()
    btn_row.addWidget(down_btn)
    btn_row.addWidget(up_btn)
    btn_row.addStretch()
    layout.addLayout(btn_row)

    layout.addStretch()

    back_btn = QPushButton("← Back")
    back_btn.setStyleSheet("font-size: 16px; padding: 10px 24px; color: #888;")
    back_btn.clicked.connect(back_fn)
    layout.addWidget(back_btn, alignment=Qt.AlignmentFlag.AlignCenter)

    count = [0]

    def update():
        count_label.setText(str(count[0]))

    def on_up():
        count[0] += inc_spin.value()
        update()

    def on_down():
        count[0] -= inc_spin.value()
        update()

    up_btn.clicked.connect(on_up)
    down_btn.clicked.connect(on_down)

    return root
