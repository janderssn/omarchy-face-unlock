import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar icon and popup for Face Unlock: whether the laptop sees you, and the
// two presence switches, named as Windows names them. All the behaviour lives in Service.qml;
// this only shows its state and flips its settings.
Panel {
  id: root
  moduleName: "janderssn.face-unlock"
  ipcTarget: "face-unlock-panel"

  readonly property string pluginId: "janderssn.face-unlock"
  property var service: null

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string setupState: service ? service.setupState : "unknown"
  readonly property bool needsSetup: setupState === "missing" || setupState === "outdated"
  readonly property bool sensorWorking: service ? service.sensorWorking : false
  readonly property var present: service ? service.present : null
  readonly property bool watching: sensorWorking && present === true
  // The camera's privacy switch is on. Nothing on the laptop shows it, and it
  // blinds both face unlock and the presence sensor.
  readonly property bool cameraPrivacy: service ? service.presence.cameraPrivacy : false

  // 󰱻 face recognition
  readonly property string glyph: "\u{F0C7B}"

  readonly property var delayOptions: [15, 30, 60, 120]

  // Rows the keyboard cursor walks, top to bottom.
  readonly property var rows: (needsSetup ? ["setup"] : []).concat(sensorWorking ? ["wake", "lock"] : [])
  property int rowIndex: 0
  property bool cursorActive: false
  readonly property string currentRow: cursorActive && rows.length > 0 ? rows[Math.min(rowIndex, rows.length - 1)] : ""

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string statusText: {
    if (!service || setupState === "unknown") return strings.t("status.starting")
    if (setupState === "missing") return strings.t("status.notSetUp")
    if (service.presence.sensor === "missing") return strings.t("status.noSensor")
    if (!sensorWorking) return strings.t("status.sensorOff")
    if (cameraPrivacy) return strings.t("status.cameraPrivacy")
    if (present === null) return strings.t("status.checking")
    if (present === false) return strings.t("status.away")
    return service.attentive ? strings.t("status.looking") : strings.t("status.here")
  }

  // Beside the status: how far away you are, or why nothing is being seen.
  readonly property string distanceText: cameraPrivacy ? strings.t("status.paused")
    : watching && service.distanceMm > 0
      ? strings.t("status.distance").arg(Commons.I18n.formatNumber(Math.round(service.distanceMm / 10)))
      : ""

  function delayLabel(seconds) {
    return seconds < 60
      ? strings.tn("delay.seconds", seconds).arg(Commons.I18n.formatNumber(seconds))
      : strings.tn("delay.minutes", seconds / 60).arg(Commons.I18n.formatNumber(seconds / 60))
  }

  function stepDelay(direction) {
    if (!service) return
    var index = 0
    for (var i = 0; i < delayOptions.length; i++) {
      if (delayOptions[i] <= service.lockDelaySeconds) index = i
    }
    index = Math.max(0, Math.min(delayOptions.length - 1, index + direction))
    service.setOption("lockDelaySeconds", delayOptions[index])
  }

  function activate(row) {
    if (!service) return
    if (row === "setup") {
      service.runSetup()
      root.close()
    } else if (row === "wake") service.setOption("wakeOnApproach", !service.wakeOnApproach)
    else if (row === "lock") service.setOption("lockOnLeave", !service.lockOnLeave)
  }

  function hover(row, isHovered) {
    if (!isHovered) return
    var index = rows.indexOf(row)
    if (index < 0) return
    rowIndex = index
    cursorActive = true
  }

  function findService() {
    if (!service && bar && bar.shell) service = bar.shell.serviceFor(pluginId)
  }

  // The service plugin can finish loading after the bar has drawn this.
  Timer {
    interval: 1000
    repeat: true
    running: root.service === null
    triggeredOnStart: true
    onTriggered: root.findService()
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    rowIndex = 0
    findService()
    if (service) service.refreshSetup()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    tooltipText: ""
    // Dimmed while nobody is seen, the way Omarchy's Tailscale icon reads off.
    opacity: root.watching || root.needsSetup ? 1 : 0.55
    onPressed: function(b) { root.toggle() }

    Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0 && root.rows.length > 0) root.rowIndex = Math.max(0, Math.min(root.rows.length - 1, root.rowIndex + dy))
        else if (dx !== 0 && root.currentRow === "lock") root.stepDelay(dx)
      }
      onActivateRequested: if (root.currentRow !== "") root.activate(root.currentRow)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        PanelHero {
          foreground: root.foreground
          fontFamily: root.fontFamily
          title: strings.t("title")
          meta: root.distanceText === "" ? root.statusText : root.statusText + "  ·  " + root.distanceText
          iconOpacity: root.watching ? 1 : 0.55
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.glyph
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        // ---- Setup ------------------------------------------------------------
        Column {
          visible: root.needsSetup
          width: parent.width
          spacing: Style.space(8)

          PanelSeparator { foreground: root.foreground }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.setupState === "outdated" ? strings.t("setup.outdated") : strings.t("setup.missing")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            text: root.setupState === "outdated" ? strings.t("setup.update") : strings.t("setup.start")
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            bordered: true
            hasCursor: root.currentRow === "setup"
            onHovered: function(h) { root.hover("setup", h) }
            onClicked: root.activate("setup")
          }
        }

        // ---- Presence -----------------------------------------------------------
        Column {
          visible: root.sensorWorking
          width: parent.width
          spacing: Style.space(6)

          PanelSeparator { foreground: root.foreground }

          Toggle {
            width: parent.width
            label: strings.t("wake.label")
            description: strings.t("wake.description")
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            checked: root.service ? root.service.wakeOnApproach : false
            hasCursor: root.currentRow === "wake"
            onHovered: function(h) { root.hover("wake", h) }
            onClicked: root.activate("wake")
          }

          Toggle {
            width: parent.width
            label: strings.t("lock.label")
            description: strings.t("lock.description").arg(root.delayLabel(root.service ? root.service.lockDelaySeconds : Model.DEFAULTS.lockDelaySeconds))
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            checked: root.service ? root.service.lockOnLeave : false
            hasCursor: root.currentRow === "lock"
            onHovered: function(h) { root.hover("lock", h) }
            onClicked: root.activate("lock")
          }

          ButtonGroup {
            visible: root.service ? root.service.lockOnLeave : false
            anchors.horizontalCenter: parent.horizontalCenter
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            focusable: false
            options: root.delayOptions.map(function(seconds) {
              return { value: String(seconds), label: root.delayLabel(seconds) }
            })
            value: root.service ? String(root.service.lockDelaySeconds) : ""
            onChanged: function(value) { if (root.service) root.service.setOption("lockDelaySeconds", Number(value)) }
          }
        }
      }
    }
  }
}
