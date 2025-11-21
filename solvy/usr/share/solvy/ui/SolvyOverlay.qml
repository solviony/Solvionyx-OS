import QtQuick 2.15
import QtQuick.Controls 2.15
import QtGraphicalEffects 1.15

Rectangle {
    id: root
    anchors.fill: parent
    visible: true
    color: "transparent"

    // Dim background
    Rectangle {
        anchors.fill: parent
        color: "#66000000"
    }

    // Aurora glass panel
    Rectangle {
        id: panel
        width: parent.width * 0.55
        height: parent.height * 0.32
        radius: 26
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        color: "#101322EE"
        border.color: "#5ad3ff"
        border.width: 1

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#203A72" }
                GradientStop { position: 0.5; color: "#132035" }
                GradientStop { position: 1.0; color: "#0A1825" }
            }
            opacity: 0.80
        }

        // Solvy label
        Column {
            anchors.centerIn: parent
            spacing: 8

            Text {
                text: "Solvy is listening..."
                font.pixelSize: 30
                font.bold: true
                color: "#FFFFFF"
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                text: "Say “Hey Solvy” and ask anything."
                font.pixelSize: 16
                color: "#A0B7D9"
                horizontalAlignment: Text.AlignHCenter
            }
        }

        // Mic orb
        Rectangle {
            id: micOrb
            width: 76
            height: 76
            radius: 38
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottomMargin: 22
            color: "#1C9BF280"

            Rectangle {
                anchors.fill: parent
                anchors.margins: 6
                radius: width / 2
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#4CC9F0" }
                    GradientStop { position: 1.0; color: "#4361EE" }
                }
            }

            SequentialAnimation on scale {
                loops: Animation.Infinite
                NumberAnimation { from: 1.0; to: 1.12; duration: 900; easing.type: Easing.InOutQuad }
                NumberAnimation { from: 1.12; to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
            }
        }
    }
}
