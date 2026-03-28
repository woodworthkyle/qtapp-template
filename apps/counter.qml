// counter.qml — QML-based up/down counter example.
//
// Drop in ~/Documents/ on the device and launch from the picker (shows as [QML]).
// Demonstrates the direct .qml drop-in — no Python glue needed.
//
// Uses only QtQuick (no QtQuick.Controls) because the Controls2 plugin binary
// is not present in this iOS PySide6 build.  All UI is built from Rectangle,
// Text, and MouseArea — which is the QtQuick base layer and always available.

import QtQuick

Rectangle {
    id: root
    anchors.fill: parent
    color: "#f5f5f5"

    property int count: 0
    property int step: 1

    // ── helpers ──────────────────────────────────────────────────────────
    component Btn: Rectangle {
        id: btn
        required property string label
        required property color baseColor
        signal tapped()
        width: 140; height: 56; radius: 10
        color: ma.pressed ? Qt.darker(baseColor, 1.2) : baseColor
        Text {
            text: btn.label
            font.pixelSize: 20; font.bold: true
            color: "white"
            anchors.centerIn: parent
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            onClicked: btn.tapped()
        }
    }

    component SmallBtn: Rectangle {
        id: sb
        required property string label
        signal tapped()
        width: 44; height: 44; radius: 8
        color: sma.pressed ? "#bdbdbd" : "#e0e0e0"
        Text {
            text: sb.label
            font.pixelSize: 22; font.bold: true
            color: "#424242"
            anchors.centerIn: parent
        }
        MouseArea {
            id: sma
            anchors.fill: parent
            onClicked: sb.tapped()
        }
    }

    // ── layout ───────────────────────────────────────────────────────────
    Column {
        anchors.centerIn: parent
        spacing: 32

        Text {
            text: "Counter"
            font.pixelSize: 28; font.bold: true
            color: "#212121"
            anchors.horizontalCenter: parent.horizontalCenter
        }

        Text {
            text: root.count
            font.pixelSize: 80; font.bold: true
            color: "#2196F3"
            anchors.horizontalCenter: parent.horizontalCenter
        }

        // Step controls
        Row {
            spacing: 12
            anchors.horizontalCenter: parent.horizontalCenter

            Text {
                text: "Step:"
                font.pixelSize: 18; color: "#616161"
                anchors.verticalCenter: parent.verticalCenter
            }

            SmallBtn {
                label: "−"
                onTapped: if (root.step > 1) root.step--
            }

            Text {
                text: root.step
                font.pixelSize: 20; font.bold: true; color: "#212121"
                width: 36; horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
            }

            SmallBtn {
                label: "+"
                onTapped: root.step++
            }
        }

        // Up / Down buttons
        Row {
            spacing: 20
            anchors.horizontalCenter: parent.horizontalCenter

            Btn {
                label: "▼  Down"
                baseColor: "#f44336"
                onTapped: root.count -= root.step
            }

            Btn {
                label: "▲  Up"
                baseColor: "#2196F3"
                onTapped: root.count += root.step
            }
        }
    }
}
