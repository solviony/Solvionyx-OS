import QtQuick 2.5

Item {
    id: imageslide
    visible: false
    anchors.fill: parent

    property bool isSlide: true
    property string notes: ""
    property string src: ""

    Image {
        anchors.fill: parent
        source: imageslide.src
        fillMode: Image.PreserveAspectCrop
        smooth: true
        cache: true
        asynchronous: true
    }
}
