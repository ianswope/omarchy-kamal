import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus popup for Kamal 2 apps. One row per app: whether it answers,
// which revision its containers are actually running, whether every declared
// role is up, and how far that is from what has been pushed.
Panel {
  id: root
  moduleName: "ianswope.kamal"
  ipcTarget: "ianswope.kamal"
  manageIpc: false

  property int selectedIndex: 0
  property bool cursorActive: false
  property string confirmKind: ""
  property var confirmApp: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var items: kamal.navItems
  readonly property bool confirming: confirmKind !== ""
  readonly property bool countVisible: kamal.showCount && kamal.barCountText !== ""

  // Only a site that is actually down recolours the bar. Undeployed commits are
  // normal between a push and a deploy, so they get the badge, not the alarm.
  readonly property color barIconColor: kamal.level === "critical" ? bar.urgent : barForeground
  readonly property color heroColor: kamal.level === "critical" ? urgent : foreground

  readonly property string confirmMessage: {
    if (confirmKind !== "deploy") return ""
    return Model.deployPreview(confirmApp)
  }

  function levelColor(level) {
    if (level === "critical") return urgent
    if (level === "warn") return Qt.lighter(urgent, 1.25)
    return dim
  }

  function appAt(i) {
    var list = kamal.apps || []
    return (i >= 0 && i < list.length) ? list[i] : null
  }

  function selectedItem() {
    if (items.length === 0) return null
    return items[Math.max(0, Math.min(selectedIndex, items.length - 1))]
  }

  function ensureCursor() {
    if (items.length === 0) { selectedIndex = 0; return }
    selectedIndex = Math.max(0, Math.min(selectedIndex, items.length - 1))
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    selectedIndex = Math.max(0, Math.min(items.length - 1, selectedIndex + dy))
    scrollCursorIntoView()
  }

  function activateCursor() {
    ensureCursor()
    var item = selectedItem()
    if (!item) return
    if (item.kind === "app") kamal.openApp(item.app)
  }

  function askDeploy(index) {
    var a = appAt(index)
    if (!a) return
    if (Model.deploymentActive(kamal.deploymentFor(a))) { kamal.note("A deployment is already active for " + a.name); return }
    var reason = Model.deployBlockReason(a)
    if (reason) { kamal.note(a.name + ": " + reason); return }
    // A timer refresh or config reorder must not change what was confirmed.
    confirmApp = JSON.parse(JSON.stringify(a))
    confirmKind = "deploy"
    // Cancel first: the other button restarts a live site.
    confirmDialog.selectedIndex = 0
  }

  function askDeploySelected() {
    var item = selectedItem()
    if (item && item.kind === "app") askDeploy(item.index)
  }

  function cancelConfirm() {
    confirmKind = ""
    confirmApp = null
  }

  function acceptConfirm() {
    var app = confirmApp
    var kind = confirmKind
    cancelConfirm()
    if (kind === "deploy") kamal.deploy(app)
  }

  property var rowRegistry: ({})
  function registerRow(index, item) { rowRegistry[index] = item }

  function scrollCursorIntoView() {
    var target = rowRegistry[selectedIndex]
    if (!panelFlick || !target) return
    Qt.callLater(function() {
      if (!target) return
      var margin = Style.space(6)
      var point = target.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + target.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onConfirmingChanged: if (!confirming && opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

  onOpenedChanged: if (opened) {
    cursorActive = false
    cancelConfirm()
    if (panelFlick) panelFlick.contentY = 0
    kamal.refresh(false)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: kamal
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { kamal.refresh(false); return "ok" }
    function fetch(): string { kamal.refresh(true); return "ok" }
    function status(): string { return kamal.headline }
    function level(): string { return kamal.level }
  }

  TextMetrics {
    id: countMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.bar.iconFont
    text: kamal.barCountText
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.iconSlot + (root.countVisible ? countMetrics.width + Style.space(3) : 0)
    iconComponent: Component {
      Item {
        Row {
          anchors.centerIn: parent
          spacing: Style.space(3)

          KamalIcon {
            anchors.verticalCenter: parent.verticalCenter
            iconSize: Style.space(12)
            color: root.barIconColor
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.countVisible
            text: kamal.barCountText
            textFormat: Text.PlainText
            color: root.barIconColor
            font.family: root.fontFamily
            font.pixelSize: Style.bar.iconFont
            renderType: Text.NativeRendering
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) kamal.refresh(false)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(
      root.confirming ? Style.space(600)
        : headerColumn.implicitHeight + column.implicitHeight + footerColumn.implicitHeight + Style.space(34),
      Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.confirming
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: {
        if (root.cursorActive) root.activateCursor()
        else root.cursorActive = true
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r") kamal.refresh(false)
        else if (t === "f") kamal.refresh(true)
        else if (t === "d") root.askDeploySelected()
        else if (t === "l") { var sl = root.selectedItem(); if (sl && sl.kind === "app") kamal.logs(sl.app) }
        else if (t === "y") { var s = root.selectedItem(); if (s && s.kind === "app") kamal.copyDeployCommand(s.app) }
        else if (t === "e") kamal.openConfig()
      }

      Column {
        id: headerColumn
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(10)

        PanelHero {
          id: hero
          width: parent.width
          title: "Kamal"
          meta: kamal.headline
          foreground: root.heroColor
          fontFamily: root.fontFamily
          iconComponent: Component {
            KamalIcon {
              iconSize: Style.font.display
              color: root.heroColor
            }
          }
        }

        Text {
          visible: kamal.deploymentError !== ""
          width: parent.width
          text: kamal.deploymentError
          textFormat: Text.PlainText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          visible: kamal.actionStatus !== ""
          width: parent.width
          text: kamal.actionStatus
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Column {
          id: faultColumn
          width: parent.width
          spacing: Style.space(6)
          visible: faults.length > 0

          // Capped. One row per app can produce several faults each, and an
          // unbounded column here pushes the app list itself off the top of
          // the panel -- the list is what the panel is for.
          readonly property int faultLimit: 3
          readonly property var allFaults: (kamal.issues || []).filter(function(i) {
            return i.level === "critical" || i.level === "warn"
          })
          readonly property var faults: allFaults.slice(0, faultLimit)
          readonly property int hiddenFaults: Math.max(0, allFaults.length - faultLimit)

          Repeater {
            model: faultColumn.faults
            Row {
              required property var modelData
              width: faultColumn.width
              spacing: Style.space(8)

              Rectangle {
                width: Style.space(4)
                height: Style.space(4)
                radius: width / 2
                color: root.levelColor(modelData.level)
                y: Style.space(5)
              }

              Text {
                width: parent.width - Style.space(12)
                text: modelData.text
                textFormat: Text.PlainText
                color: root.levelColor(modelData.level)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }

          Text {
            visible: faultColumn.hiddenFaults > 0
            width: parent.width
            text: "and " + faultColumn.hiddenFaults + " more"
            textFormat: Text.PlainText
            color: Qt.darker(root.dim, 1.15)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      Flickable {
        id: panelFlick
        anchors.top: headerColumn.bottom
        anchors.topMargin: Style.space(12)
        anchors.bottom: footerColumn.top
        anchors.bottomMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(4)

          Text {
            visible: !kamal.configured && kamal.everLoaded
            width: parent.width
            text: "No apps configured yet. Press e to create " + kamal.configPath + ", then give each app a name, its repo, and the env file its secrets come from. Everything else is read from the repo's config/deploy.yml."
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: kamal.apps
            AppRow {
              required property var modelData
              required property int index
              width: column.width
              app: modelData
              appIndex: index
            }
          }
        }
      }

      Column {
        id: footerColumn
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(4)

        PanelSeparator { foreground: root.foreground }

        Text {
          visible: kamal.fetchAge !== ""
          width: parent.width
          text: kamal.fetchAge + " · press f to refresh from origin"
          textFormat: Text.PlainText
          color: Qt.darker(root.dim, 1.15)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: "enter open · d deploy · l logs · y copy · f fetch · e edit config"
          textFormat: Text.PlainText
          color: Qt.darker(root.dim, 1.15)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 10
        opened: root.confirming
        focus: root.confirming
        message: root.confirmMessage
        confirmText: "Deploy"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelConfirm()
        onConfirmed: root.acceptConfirm()
        Keys.onPressed: function(event) {
          if (confirmDialog.handleKey(event)) event.accepted = true
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component AppRow: CursorSurface {
    id: appRow
    property var app: null
    property int appIndex: -1

    readonly property bool down: Model.isDown(app) || Model.deadRoles(app).length > 0
    readonly property int behindCount: Model.behind(app)
    readonly property var deployment: kamal.deploymentFor(app)

    hasCursor: root.cursorActive && root.selectedIndex === appIndex
    foreground: root.foreground
    implicitHeight: appContent.implicitHeight + Style.space(12)

    onAppIndexChanged: if (appIndex >= 0) root.registerRow(appIndex, appRow)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      onEntered: {
        root.cursorActive = true
        root.selectedIndex = appRow.appIndex
      }
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.askDeploy(appRow.appIndex)
        else if (mouse.button === Qt.MiddleButton) kamal.copyDeployCommand(appRow.app)
        else kamal.openApp(appRow.app)
      }
    }

    Row {
      id: appContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(9)

      // Up, down, or unknown at a glance.
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(6)
        height: Style.space(6)
        radius: width / 2
        color: appRow.down ? root.urgent
             : (appRow.app && appRow.app.health && appRow.app.health.checked ? root.foreground : root.dim)
        opacity: appRow.down ? 1.0 : 0.75
      }

      Column {
        width: parent.width - Style.space(6) - Style.space(96) - Style.space(27)
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: appRow.app ? appRow.app.name : ""
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: {
            if (!appRow.app) return ""
            var bits = []
            var drift = Model.driftText(appRow.app)
            if (drift) bits.push(drift)
            if (appRow.app.deployed && appRow.app.deployed.short) bits.push(appRow.app.deployed.short)
            var age = Model.deployedAge(appRow.app, kamal.status.now)
            if (age) bits.push(age)
            // Only when it is news: a dead role, or more than one role to
            // account for. A lone healthy web role is already implied above.
            var roles = Model.rolesSummary(appRow.app)
            if (roles) bits.push(roles)
            var secrets = Model.secretsText(appRow.app)
            if (secrets) bits.push(secrets)
            return bits.join(" · ")
          }
          textFormat: Text.PlainText
          color: appRow.behindCount > 0 ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          visible: !!appRow.deployment
          width: parent.width
          text: Model.deploymentDetail(appRow.deployment)
          textFormat: Text.PlainText
          color: appRow.deployment && ["failed", "interrupted", "incomplete"].indexOf(appRow.deployment.phase) >= 0 ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      Column {
        width: Style.space(96)
        spacing: Style.space(2)

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignRight
          text: Model.deploymentActive(appRow.deployment) ? Model.deploymentLabel(appRow.deployment)
            : appRow.behindCount > 0 ? appRow.behindCount + " to deploy" : ""
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignRight
          text: Model.healthText(appRow.app)
          textFormat: Text.PlainText
          color: appRow.down ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
