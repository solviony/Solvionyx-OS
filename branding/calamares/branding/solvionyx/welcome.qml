import QtQuick 2.12
Rectangle {
  width: 800; height: 400; color: "#0B0C10"
  Image { id: logo; anchors.centerIn: parent; source: "images/logo-dark.png"; width: 160; height: 160; fillMode: Image.PreserveAspectFit
    SequentialAnimation on opacity {
      loops: Animation.Infinite
      PropertyAnimation { from:0.8; to:1.0; duration:1400; easing.type:Easing.InOutQuad }
      PropertyAnimation { from:1.0; to:0.8; duration:1400; easing.type:Easing.InOutQuad }
    }
  }
  Text { anchors.horizontalCenter: parent.horizontalCenter; anchors.top: logo.bottom; anchors.topMargin: 20
    text: "The engine behind the vision."; color: "#66FFCC"; font.pixelSize: 18; font.bold: true }
}
