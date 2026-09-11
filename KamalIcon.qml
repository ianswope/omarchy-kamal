import QtQuick
import qs.Commons

// A container set down on a host. The bar draws this near 12px, so it is two
// solid blocks and a bar rather than an outlined glyph, which turns to mush at
// that size. Deliberately not the ssh widget's arrow: what this reports is a
// container image that is already running, not a push on its way out.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real barHeight: Math.max(1, Math.round(iconSize * 0.13))
  readonly property real gap: Math.max(1, Math.round(iconSize * 0.16))
  readonly property real boxWidth: iconSize * 0.74
  readonly property real boxHeight: iconSize * 0.46
  readonly property real ribWidth: Math.max(1, Math.round(iconSize * 0.08))

  Item {
    id: stack
    width: parent.width
    height: root.boxHeight + root.gap + root.barHeight
    anchors.centerIn: parent

    // The container.
    Rectangle {
      id: box
      width: root.boxWidth
      height: root.boxHeight
      radius: Math.max(1, Math.round(root.iconSize * 0.06))
      x: (stack.width - width) / 2
      y: 0
      color: root.color
      antialiasing: true

      // Two ribs, cut out of the block so it reads as corrugated rather than as
      // a plain rectangle. Background-coloured strokes would need to know the
      // bar's background, so they are holes punched with opacity instead.
      Row {
        anchors.centerIn: parent
        spacing: root.ribWidth * 2

        Repeater {
          model: 2
          Rectangle {
            width: root.ribWidth
            height: box.height * 0.62
            color: "black"
            opacity: 0.35
            antialiasing: true
          }
        }
      }
    }

    // The host it is running on.
    Rectangle {
      width: root.iconSize * 0.92
      height: root.barHeight
      radius: height / 2
      x: (stack.width - width) / 2
      y: root.boxHeight + root.gap
      color: root.color
      antialiasing: true
    }
  }
}
