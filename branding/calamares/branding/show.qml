import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation

    Timer {
        interval: 3500
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    function onActivate() { }
    function onLeave() { }

    ImageSlide { src: "slideshow/slide01.png" }
    ImageSlide { src: "slideshow/slide02.png" }
    ImageSlide { src: "slideshow/slide03.png" }
    ImageSlide { src: "slideshow/slide04.png" }
}
