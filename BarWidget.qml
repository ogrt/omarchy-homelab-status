import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// Render-only: reads state off the ogibon.homelab service, never checks a
// host itself. All of this reacts to Service.qml's `status` property, so a
// slow/unreachable host never blocks a paint here -- the worst case is a dot
// staying its previous color until that service's Process exits.
BarWidget {
  id: root
  moduleName: "ogibon.homelab"

  readonly property var homelabService: bar?.shell?.serviceFor("ogibon.homelab")
  readonly property var serviceList: homelabService ? homelabService.services : []
  readonly property real dotSize: Style.space(8)

  property bool popupOpen: false
  function close() { popupOpen = false }

  function statusLabel(s) {
    if (s.status === "up") return "Up" + (s.code ? " (" + s.code + ")" : "")
    if (s.status === "warn") return "Reachable, HTTP " + s.code
    if (s.status === "down") return "Down" + (s.error ? " — " + s.error : "")
    return "Checking…"
  }

  function latencyLabel(s) {
    return (s.latencyMs === null || s.latencyMs === undefined) ? "" : Math.round(s.latencyMs) + " ms"
  }

  function tooltipFor(svc) {
    var s = homelabService.statusFor(svc.name)
    var parts = [svc.name + " — " + statusLabel(s)]
    var lat = latencyLabel(s)
    if (lat) parts.push(lat)
    return parts.join("  ·  ")
  }

  visible: serviceList.length > 0
  implicitWidth: serviceList.length > 0 ? dotsRow.implicitWidth + Style.space(10) : 0
  implicitHeight: barSize

  Row {
    id: dotsRow
    anchors.centerIn: parent
    spacing: Style.space(6)

    Repeater {
      model: root.serviceList

      Item {
        id: dotSlot
        required property var modelData
        width: root.dotSize
        height: root.dotSize
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined

        readonly property var svcStatus: root.homelabService ? root.homelabService.statusFor(modelData.name) : { status: "unknown" }

        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: root.homelabService ? root.homelabService.colorFor(modelData.name) : Color.muted
          border.width: 0

          Behavior on color { ColorAnimation { duration: 200 } }
        }

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(3)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: if (root.bar) root.bar.showTooltip(dotSlot, root.tooltipFor(modelData))
          onExited: if (root.bar) root.bar.hideTooltip(dotSlot)
          onClicked: root.popupOpen = !root.popupOpen
        }
      }
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(260))
    contentHeight: popup.fittedContentHeight(list.implicitHeight)

    Column {
      id: list
      anchors.fill: parent
      spacing: Style.space(8)

      Repeater {
        model: root.serviceList

        Row {
          id: row
          required property var modelData
          width: list.width
          spacing: Style.space(8)

          readonly property var rowStatus: root.homelabService ? root.homelabService.statusFor(modelData.name) : { status: "unknown" }

          Rectangle {
            width: Style.space(8)
            height: Style.space(8)
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: root.homelabService ? root.homelabService.colorFor(modelData.name) : Color.muted
          }

          Column {
            width: parent.width - Style.space(20)
            spacing: Style.space(1)

            Text {
              text: row.modelData.name
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.statusLabel(row.rowStatus) + (root.latencyLabel(row.rowStatus) ? "  ·  " + root.latencyLabel(row.rowStatus) : "")
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }
      }

      Text {
        visible: root.serviceList.length === 0
        text: "No services configured — edit config.json"
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
