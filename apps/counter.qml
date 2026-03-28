// counter.qml — QML-based up/down counter example.
//
// Drop in ~/Documents/ on the device and launch from the picker (shows as [QML]).
// Demonstrates the direct .qml drop-in — no Python glue needed.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    anchors.fill: parent
    color: "#f5f5f5"

    property int count: 0
    property int increment: 1

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 40
        spacing: 24

        Label {
            text: "Counter"
            font.pixelSize: 28
            font.bold: true
            Layout.alignment: Qt.AlignHCenter
        }

        Label {
            text: root.count
            font.pixelSize: 72
            font.bold: true
            color: "#2196F3"
            Layout.alignment: Qt.AlignHCenter
        }

        // Increment-by row
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 12

            Label {
                text: "Increment by:"
                font.pixelSize: 18
            }

            SpinBox {
                id: incSpin
                from: 1
                to: 100
                value: 1
                font.pixelSize: 18
                onValueChanged: root.increment = value
            }
        }

        // Up / Down buttons
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 20

            Button {
                text: "▼ Down"
                font.pixelSize: 22
                implicitWidth: 140
                implicitHeight: 56
                onClicked: root.count -= root.increment
            }

            Button {
                text: "▲ Up"
                font.pixelSize: 22
                implicitWidth: 140
                implicitHeight: 56
                onClicked: root.count += root.increment
            }
        }

        Item { Layout.fillHeight: true }
    }
}
