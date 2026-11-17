import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The settings window: every switch Face Unlock has, in one place. Opened
// from the bar panel's Settings button, a right click on the bar icon, or
// `omarchy-shell face-unlock settings`. All behaviour lives in Service.qml;
// this shows its state and flips its settings, as the bar panel does.
Item {
  id: root

  // Set by Service.qml once loaded.
  property var service: null
  signal closed()

  readonly property color foreground: Commons.Color.foreground
  readonly property color background: Commons.Color.background
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: Style.font.family

  readonly property bool sensorWorking: service ? service.sensorWorking : false
  readonly property bool setupReady: service ? service.setupState === "ready" : false
  readonly property var delayOptions: [15, 30, 60, 120]

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function delayLabel(seconds) {
    return seconds < 60
      ? strings.tn("delay.seconds", seconds).arg(Commons.I18n.formatNumber(seconds))
      : strings.tn("delay.minutes", seconds / 60).arg(Commons.I18n.formatNumber(seconds / 60))
  }

  function flip(key) {
    if (service) service.setOption(key, !service[key])
  }

  component Note: Text {
    textFormat: Text.PlainText
    width: parent ? parent.width : 0
    wrapMode: Text.WordWrap
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component Switch: Toggle {
    width: parent ? parent.width : 0
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
  }

  component Choice: ButtonGroup {
    foreground: root.foreground
    background: root.background
    accent: root.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
  }

  FloatingWindow {
    id: window
    title: strings.t("settings.title")
    color: root.background
    visible: true
    implicitWidth: 520
    implicitHeight: Math.min(760, column.implicitHeight + Style.space(48))
    // A fixed size makes Hyprland float the window instead of tiling it.
    minimumSize: Qt.size(implicitWidth, implicitHeight)
    maximumSize: Qt.size(implicitWidth, implicitHeight)

    onVisibleChanged: if (!visible) root.closed()

    FocusScope {
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: window.visible = false

      Flickable {
        id: flick
        anchors.fill: parent
        anchors.margins: Style.space(24)
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: column
          width: flick.width
          spacing: Style.space(8)

          // ---- Presence ---------------------------------------------------------
          PanelSectionHeader {
            text: strings.t("settings.presence")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Note {
            visible: !root.sensorWorking
            text: strings.t("settings.noSensor")
          }

          Switch {
            visible: root.sensorWorking
            label: strings.t("wake.label")
            description: strings.t("wake.description")
            checked: root.service ? root.service.wakeOnApproach : false
            onClicked: root.flip("wakeOnApproach")
          }

          Switch {
            visible: root.sensorWorking
            label: strings.t("lock.label")
            description: strings.t("lock.description").arg(root.delayLabel(root.service ? root.service.lockDelaySeconds : Model.DEFAULTS.lockDelaySeconds))
            checked: root.service ? root.service.lockOnLeave : false
            onClicked: root.flip("lockOnLeave")
          }

          Choice {
            visible: root.sensorWorking && (root.service ? root.service.lockOnLeave : false)
            anchors.horizontalCenter: parent.horizontalCenter
            options: root.delayOptions.map(function(seconds) {
              return { value: String(seconds), label: root.delayLabel(seconds) }
            })
            value: root.service ? String(root.service.lockDelaySeconds) : ""
            onChanged: function(value) { if (root.service) root.service.setOption("lockDelaySeconds", Number(value)) }
          }

          Switch {
            visible: root.sensorWorking
            label: strings.t("awake.label")
            description: strings.t("awake.description")
            checked: root.service ? root.service.keepAwake : false
            onClicked: root.flip("keepAwake")
          }

          Switch {
            visible: root.sensorWorking
            label: strings.t("attention.label")
            description: strings.t("attention.description")
            checked: root.service ? root.service.requireAttention : false
            onClicked: root.flip("requireAttention")
          }

          // ---- Screensaver ------------------------------------------------------
          Item { width: 1; height: Style.space(8) }

          PanelSectionHeader {
            text: strings.t("settings.screensaver")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Switch {
            label: strings.t("saverInput.label")
            description: strings.t("saverInput.description")
            checked: root.service ? root.service.screensaverInput : false
            onClicked: root.flip("screensaverInput")
          }

          Column {
            visible: root.sensorWorking
            width: parent.width
            spacing: Style.space(6)
            topPadding: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: strings.t("saverPresence.label")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
            }

            Choice {
              options: Model.SCREENSAVER_PRESENCE.map(function(mode) {
                return { value: mode, label: strings.t("saverPresence." + mode) }
              })
              value: root.service ? root.service.screensaverPresence : ""
              onChanged: function(value) { if (root.service) root.service.setOption("screensaverPresence", value) }
            }

            Note {
              text: strings.t("saverPresence.description." + (root.service ? root.service.screensaverPresence : "off"))
            }
          }

          // ---- sudo and admin prompts -------------------------------------------
          Item { visible: root.setupReady; width: 1; height: Style.space(8) }

          PanelSectionHeader {
            visible: root.setupReady
            text: strings.t("settings.prompts")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Switch {
            visible: root.setupReady
            label: strings.t("prompts.label")
            description: strings.t("prompts.description")
            checked: root.service ? root.service.prompts : false
            onClicked: if (root.service) root.service.setPrompts(!root.service.prompts)
          }
        }
      }
    }
  }
}
