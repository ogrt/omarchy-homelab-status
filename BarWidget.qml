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

  // Ticks once a second while the popup is open so "12s ago" labels stay
  // live without a full status re-check.
  property double nowMs: Date.now()
  Timer {
    interval: 1000
    running: root.popupOpen
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  function statusLabel(s) {
    if (s.status === "up") return "Up" + (s.code ? " (" + s.code + ")" : "")
    if (s.status === "warn") return "Reachable, HTTP " + s.code
    if (s.status === "down") return "Down"
    return "Checking…"
  }

  function latencyLabel(s) {
    return (s.latencyMs === null || s.latencyMs === undefined) ? "" : Math.round(s.latencyMs) + " ms"
  }

  function targetLabel(svc) {
    var addr = svc.type === "tcp" ? (svc.host + ":" + svc.port) : svc.url
    return svc.hostHeader ? (addr + "  (Host: " + svc.hostHeader + ")") : addr
  }

  function agoLabel(checkedAt) {
    if (!checkedAt) return "never checked"
    var deltaSec = Math.max(0, Math.round((root.nowMs - checkedAt) / 1000))
    if (deltaSec < 1) return "just now"
    if (deltaSec < 60) return deltaSec + "s ago"
    var deltaMin = Math.round(deltaSec / 60)
    if (deltaMin < 60) return deltaMin + "m ago"
    return Math.round(deltaMin / 60) + "h ago"
  }

  function tooltipFor(svc) {
    var s = homelabService.statusFor(svc.name)
    var parts = [svc.name + " — " + statusLabel(s)]
    var lat = latencyLabel(s)
    if (lat) parts.push(lat)
    return parts.join("  ·  ")
  }

  readonly property int upCount: {
    var n = 0
    for (var i = 0; i < serviceList.length; i++) if (homelabService && homelabService.statusFor(serviceList[i].name).status === "up") n++
    return n
  }
  readonly property int warnCount: {
    var n = 0
    for (var i = 0; i < serviceList.length; i++) if (homelabService && homelabService.statusFor(serviceList[i].name).status === "warn") n++
    return n
  }
  readonly property int downCount: {
    var n = 0
    for (var i = 0; i < serviceList.length; i++) if (homelabService && homelabService.statusFor(serviceList[i].name).status === "down") n++
    return n
  }
  readonly property string summaryLabel: {
    var parts = []
    if (upCount > 0) parts.push(upCount + " up")
    if (warnCount > 0) parts.push(warnCount + " warn")
    if (downCount > 0) parts.push(downCount + " down")
    return parts.length > 0 ? parts.join(" · ") : "No services checked yet"
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
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          text: root.summaryLabel
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
          width: parent.width - refreshButton.implicitWidth - Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }

        Button {
          id: refreshButton
          iconText: "󰑐"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          tooltipText: "Refresh all"
          onClicked: if (root.homelabService) root.homelabService.startCycle()
        }
      }

      Text {
        visible: root.homelabService && root.homelabService.configError !== ""
        text: "⚠ " + (root.homelabService ? root.homelabService.configError : "")
        color: root.homelabService ? root.homelabService.colorForStatus("down") : Color.urgent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
      }

      PanelSeparator {
        visible: root.serviceList.length > 0
        foreground: root.bar.foreground
      }

      Repeater {
        model: root.serviceList

        Column {
          id: row
          required property var modelData
          width: column.width
          spacing: Style.space(3)

          readonly property var rowStatus: root.homelabService ? root.homelabService.statusFor(modelData.name) : { status: "unknown" }
          readonly property var rowHistory: root.homelabService ? root.homelabService.historyFor(modelData.name) : []

          Row {
            width: parent.width
            spacing: Style.space(8)

            Rectangle {
              width: Style.space(8)
              height: Style.space(8)
              radius: width / 2
              anchors.verticalCenter: parent.verticalCenter
              color: root.homelabService ? root.homelabService.colorFor(row.modelData.name) : Color.muted
              Behavior on color { ColorAnimation { duration: 200 } }
            }

            Text {
              text: row.modelData.name
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              elide: Text.ElideRight
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(16) - recheckButton.implicitWidth - statusText.implicitWidth - Style.space(8)
            }

            Text {
              id: statusText
              text: root.statusLabel(row.rowStatus) + (root.latencyLabel(row.rowStatus) ? "  ·  " + root.latencyLabel(row.rowStatus) : "")
              color: Qt.darker(root.bar.foreground, 1.3)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }

            Button {
              id: recheckButton
              iconText: "󰑐"
              iconSize: Style.font.caption
              foreground: root.bar.foreground
              horizontalPadding: Style.space(4)
              verticalPadding: Style.space(2)
              tooltipText: "Recheck now"
              onClicked: if (root.homelabService) root.homelabService.recheckOne(row.modelData.name)
            }
          }

          Text {
            text: root.targetLabel(row.modelData)
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            text: "Checked " + root.agoLabel(row.rowStatus.checkedAt)
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            visible: row.rowStatus.status === "down" && !!row.rowStatus.error
            text: row.rowStatus.error
            color: root.homelabService ? root.homelabService.colorForStatus("down") : Color.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            width: parent.width
          }

          // Uptime sparkline: last historyLimit checks, oldest to newest.
          Row {
            visible: row.rowHistory.length > 0
            spacing: Style.space(2)
            topPadding: Style.space(2)

            Repeater {
              model: row.rowHistory

              Rectangle {
                required property var modelData
                width: Style.space(4)
                height: Style.space(8)
                radius: 1
                color: root.homelabService ? root.homelabService.colorForStatus(modelData) : Color.muted
              }
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
