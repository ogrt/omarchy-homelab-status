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
    if (s.status === "warn") return s.code ? ("Reachable, HTTP " + s.code) : (s.error || "Degraded")
    if (s.status === "down") return "Down"
    return "Checking…"
  }

  function latencyLabel(s) {
    return (s.latencyMs === null || s.latencyMs === undefined) ? "" : Math.round(s.latencyMs) + " ms"
  }

  function targetLabel(svc) {
    var addr = svc.type === "tcp" ? (svc.host + ":" + svc.port)
      : svc.type === "docker" ? ((svc.local ? "local" : svc.host) + "  ·  " + svc.container)
      : svc.url
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

  // Worst status across all services, for the single-dot compact mode --
  // down beats warn beats up, so the bar always shows the thing worth
  // noticing rather than averaging it away.
  readonly property string worstStatus: downCount > 0 ? "down" : warnCount > 0 ? "warn" : upCount > 0 ? "up" : "unknown"

  readonly property bool compactMode: homelabService ? homelabService.compactMode : false

  visible: serviceList.length > 0
  implicitWidth: serviceList.length > 0 ? (compactMode ? compactSlot.width : dotsRow.implicitWidth) + Style.space(10) : 0
  implicitHeight: barSize

  // Whole-widget click target underneath the dots: the dots themselves are
  // only ~8px, easy to miss (and a miss can land on the bar's own empty-space
  // double-click, which toggles bar transparency -- surprising and
  // unrelated). Declared before dotsRow, so it sits *below* it in stacking
  // order: hovering a dot still resolves to that dot's own MouseArea on top
  // (tooltip shows the right service), but a click anywhere else in the
  // widget's bounds falls through to here and still opens the popup.
  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.popupOpen = !root.popupOpen
  }

  // Single-dot mode (config "compact": true) for people with enough
  // services that one-dot-per-service would sprawl across the bar -- worst
  // status wins, full detail is still one click away in the popup.
  Item {
    id: compactSlot
    visible: root.compactMode
    anchors.centerIn: parent
    width: root.dotSize + Style.space(4)
    height: root.dotSize + Style.space(4)

    Rectangle {
      anchors.centerIn: parent
      width: root.dotSize
      height: root.dotSize
      radius: width / 2
      color: root.homelabService ? root.homelabService.colorForStatus(root.worstStatus) : Color.muted
      Behavior on color { ColorAnimation { duration: 200 } }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: if (root.bar) root.bar.showTooltip(compactSlot, root.summaryLabel)
      onExited: if (root.bar) root.bar.hideTooltip(compactSlot)
      onClicked: root.popupOpen = !root.popupOpen
    }
  }

  Row {
    id: dotsRow
    visible: !root.compactMode
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

  // PopupCard centers the card under `anchorItem`, then clamps the result
  // into [margin, window.width - popupWidth - margin] so it never runs off
  // screen. The other panels (audio/network/bluetooth) end up flush against
  // the monitor's right edge because they're PanelWindows docked there
  // directly; to match that look from a PopupCard, the simplest robust
  // route is to feed it a deliberately oversized virtual anchor width so
  // the centered position always overflows -- the same clamp then always
  // pins the card to window.width - popupWidth - margin, i.e. flush right,
  // without depending on where our actual (narrow, mid-bar) widget sits.
  Item {
    id: rightEdgeAnchor
    x: 0
    y: 0
    height: root.height
    width: 100000
  }

  PopupCard {
    id: popup
    anchorItem: rightEdgeAnchor
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(10)

        Text {
          text: "󰒍" // mdi-server
          color: Color.accent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.icon
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          width: parent.width - refreshButton.implicitWidth - Style.space(28)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            text: "Homelab Status"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            text: root.summaryLabel
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
          }
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

      // Config error (red, "0 services") and warning (yellow, "N skipped")
      // are the same banner shape with a different source/color, so one
      // Repeater renders both instead of duplicating the block.
      Repeater {
        model: [
          { text: root.homelabService ? root.homelabService.configError : "", statusKey: "down" },
          { text: root.homelabService ? root.homelabService.configWarning : "", statusKey: "warn" }
        ]

        Text {
          required property var modelData
          visible: modelData.text !== ""
          text: "⚠ " + modelData.text
          color: root.homelabService ? root.homelabService.colorForStatus(modelData.statusKey) : Color.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          width: column.width
        }
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
          required property int index
          width: column.width
          spacing: Style.space(3)

          readonly property var rowStatus: root.homelabService ? root.homelabService.statusFor(modelData.name) : { status: "unknown" }
          readonly property var rowHistory: root.homelabService ? root.homelabService.historyFor(modelData.name) : []
          readonly property string rowGroup: modelData.group || ""
          // Header only on the first service of each group, so services
          // sharing a "group" in config.json render under one label.
          readonly property bool isGroupHeader: rowGroup !== "" &&
            (index === 0 || (root.serviceList[index - 1].group || "") !== rowGroup)
          // Depends on root.nowMs so a snooze that just expired clears the
          // button/label without waiting for the next status check.
          readonly property bool rowSnoozed: {
            root.nowMs
            return root.homelabService ? root.homelabService.isSnoozed(modelData.name) : false
          }

          Text {
            visible: row.isGroupHeader
            text: row.rowGroup
            color: Color.accent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            topPadding: row.index === 0 ? 0 : Style.space(6)
            width: parent.width
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: row.modelData.type === "tcp" ? "󰜄" : row.modelData.type === "docker" ? "󰡨" : "󰖟" // mdi-lan-connect / mdi-docker / mdi-web
              color: Qt.darker(root.bar.foreground, 1.3)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }

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
              width: parent.width - Style.space(30) - snoozeButton.implicitWidth - recheckButton.implicitWidth - statusText.implicitWidth - Style.space(14)
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
              id: snoozeButton
              iconText: row.rowSnoozed ? "󰂛" : "󰂚" // mdi bell-off / bell-outline
              iconSize: Style.font.caption
              foreground: row.rowSnoozed ? (root.homelabService ? root.homelabService.colorForStatus("warn") : root.bar.foreground) : root.bar.foreground
              horizontalPadding: Style.space(4)
              verticalPadding: Style.space(2)
              tooltipText: row.rowSnoozed ? "Notifications snoozed — click to resume" : "Snooze notifications " + (root.homelabService ? root.homelabService.snoozeMinutes : 30) + "m"
              onClicked: if (root.homelabService) root.homelabService.toggleSnooze(row.modelData.name)
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

          // Indented to line up under the name, past the type icon + dot.
          Column {
            x: Style.space(28)
            width: parent.width - Style.space(28)
            spacing: Style.space(3)

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
              visible: (row.rowStatus.status === "down" || row.rowStatus.status === "warn") && !!row.rowStatus.error
              text: row.rowStatus.error
              color: root.homelabService ? root.homelabService.colorForStatus(row.rowStatus.status) : Color.urgent
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
