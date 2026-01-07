import QtQuick 2.12
import QtQuick.Controls 2.12
import QtWebEngine 1.7

Item {
    anchors.fill: parent

    property var slides: [
        "slideshow/slides/01-welcome.html",
        "slideshow/slides/02-solvy.html",
        "slideshow/slides/03-performance.html",
        "slideshow/slides/04-security.html",
        "slideshow/slides/05-ready.html"
    ]

    property int index: 0

    Timer {
        interval: 6500
        running: true
        repeat: true
        onTriggered: {
            index = (index + 1) % slides.length
            web.url = Qt.resolvedUrl(slides[index])
        }
    }

    WebEngineView {
        id: web
        anchors.fill: parent
        url: Qt.resolvedUrl(slides[0])
    }
}
