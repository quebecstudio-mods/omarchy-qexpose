import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "ExposeLayout.js" as Layout

// A Mac-style Exposé on the focused screen.
//
// - toggle (Super+D): live thumbnails of the current workspace's windows,
//   under a strip of the screen's workspaces, like Mission Control. Clicking a
//   workspace goes there; dropping a thumbnail on one moves the window there
//   ("+" is a new workspace).
// - showWindows (from a dock): one app's windows across every workspace,
//   minimized ones included (App Exposé).
// - A click (or Enter) puts everything back and focuses the chosen window;
//   Escape closes. On hover, × (or a middle click) closes the window.
//
// The same service runs the Alt+Tab switcher (Switcher.qml), which shares the
// recently used window order (mru) and focusWindow.
Item {
  id: root
  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property var shell: null
  property var manifest: null

  // Plugin settings, read from the plugin's entry in shell.json: the shell
  // hands them only to bar widgets.
  property var settings: ({})
  FileView {
    path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var id = root.manifest && root.manifest.id ? root.manifest.id : "quebecstudio.qexpose"
      var found = {}
      try {
        var list = JSON.parse(text()).plugins || []
        for (var i = 0; i < list.length; i++) if (list[i] && list[i].id === id) { found = list[i]; break }
      } catch (e) {}
      root.settings = found
    }
  }

  // "mac" (default): rounded corners and translucent surfaces; "omarchy": the
  // theme's corner radius and opaque surfaces.
  readonly property bool macStyle: root.settings.style !== "omarchy"
  readonly property int radius: macStyle ? Math.max(Style.cornerRadius, Style.space(12)) : Style.cornerRadius

  property bool opened: false
  // False: each thumbnail sits where its window is; true: in the grid.
  property bool expanded: false
  property bool closing: false
  // "workspace" (Super+D) or "app" (windows handed over by a dock).
  property string mode: "workspace"
  property var appAddresses: []
  property var windows: []
  property var workspaces: []
  property int selectedIndex: -1
  property var pendingFocus: null
  property int pendingWorkspace: -1
  property string monitorName: ""
  property int activeWorkspaceId: -1
  property real screenW: 0
  property real screenH: 0

  // Dragging a thumbnail onto the workspace strip.
  property int dragIndex: -1
  property point dragPoint
  property point dragGrab
  property int dropWorkspace: -1

  readonly property int animMs: Style.duration(240)
  readonly property int margin: Style.space(48)
  readonly property int gap: Style.space(36)
  readonly property int labelRoom: Math.round(Style.font.body * 2.4)
  readonly property bool stripShown: mode === "workspace"
  readonly property real stripCardH: Math.max(Style.space(80), Math.round(screenH * 0.11))
  readonly property real stripCardW: screenH > 0 ? Math.round(stripCardH * screenW / screenH) : stripCardH * 1.6
  readonly property real stripTop: Style.space(16)
  readonly property real stripHeight: stripCardH + Math.round(Style.font.body * 1.8)

  ShellIpc {
    target: "quebecstudio.qexpose"

    function toggle(): void { root.toggle() }
    function open(): void { if (!root.opened) root.openWorkspace() }
    function close(): void { if (root.opened) root.close(null) }
    // A JSON list of window addresses (with or without 0x), sent by a dock.
    function showWindows(addresses: string): void { root.openApp(addresses) }
    function switcherNext(): void { switcher.next() }
    function switcherPrev(): void { switcher.prev() }
    function switcherCommit(): void { switcher.commit() }
    function switcherCancel(): void { switcher.cancel() }
  }

  function toggle() {
    if (root.opened) root.close(null)
    else root.openWorkspace()
  }

  // ---- Addresses, history and focus (shared with the switcher) -------------

  function bare(address) {
    var a = String(address || "")
    return a.indexOf("0x") === 0 ? a.slice(2) : a
  }

  // Windows in the order they were focused, most recent first.
  property var mru: []

  function touch(address) {
    var a = root.bare(address)
    if (!a) return
    var next = root.mru.filter(function(other) { return other !== a })
    next.unshift(a)
    if (next.length > 200) next.length = 200
    root.mru = next
  }

  // At startup, the focus order Hyprland keeps (focusHistoryID).
  function seedMru() {
    var values = Hyprland.toplevels.values
    var known = []
    for (var i = 0; i < values.length; i++) {
      var ipc = values[i].lastIpcObject || {}
      if (ipc.focusHistoryID !== undefined) known.push({ a: root.bare(values[i].address), h: ipc.focusHistoryID })
    }
    if (known.length === 0) return
    known.sort(function(x, y) { return x.h - y.h })
    var seeded = known.map(function(k) { return k.a })
    for (var j = 0; j < root.mru.length; j++) if (seeded.indexOf(root.mru[j]) < 0) seeded.push(root.mru[j])
    root.mru = seeded
  }

  Component.onCompleted: {
    Hyprland.refreshToplevels()
    seedTimer.start()
  }

  Timer {
    id: seedTimer
    interval: 600
    onTriggered: root.seedMru()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (name === "activewindowv2") root.touch(String(event.data || ""))
    }
  }

  function iconFor(appId) {
    var entry = DesktopEntries.heuristicLookup(String(appId || ""))
    var icon = entry && entry.icon ? entry.icon : String(appId || "")
    return Quickshell.iconPath(icon, true)
  }

  function slotOf(id) {
    return ((id - 1) % 10) + 1
  }

  function dispatchCommand(step) {
    return "hyprctl dispatch " + Util.shellQuote(step)
  }

  // Focuses without warping the cursor to the window (cursor.no_warps while
  // focusing). A minimized window first comes back to the workspace shown on
  // the focused screen.
  function focusWindow(window) {
    var address = root.bare(window.address)
    if (!address) {
      if (window.toplevel) window.toplevel.activate()
      return
    }
    var target = "window = \"address:0x" + address + "\""
    // The user's own no_warps value is put back afterwards.
    var noWarps = function(value) { return "hyprctl eval \"hl.config({ cursor = { no_warps = " + value + " } })\" >/dev/null" }
    var saveNoWarps = "was=$(hyprctl getoption cursor:no_warps -j | jq -r '.bool // (.int == 1)'); [ \"$was\" = true ] || was=false; "
    var steps = []
    if (window.minimized) {
      var monitor = Hyprland.focusedMonitor
      var workspace = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
      if (workspace >= 1) steps.push(root.dispatchCommand("hl.dsp.window.move({ workspace = \"" + workspace + "\", " + target + " })"))
    }
    steps.push(root.dispatchCommand("hl.dsp.focus({ " + target + " })"))
    steps.push(root.dispatchCommand("hl.dsp.window.alter_zorder({ mode = \"top\", " + target + " })"))
    Util.execDetached(saveNoWarps + noWarps("true") + "; " + steps.join(" && ") + "; " + noWarps("$was"))
  }

  function closeWindow(window) {
    if (window && window.toplevel) window.toplevel.close()
    refreshTimer.restart()
  }

  function moveWindowTo(window, workspaceId) {
    var address = root.bare(window.address)
    if (!address || !(workspaceId >= 1)) return
    Util.execDetached(root.dispatchCommand("hl.dsp.window.move({ workspace = \"" + workspaceId + "\", follow = false, window = \"address:0x" + address + "\" })"))
    refreshTimer.restart()
  }

  // After a window closes or moves, the grid is laid out again.
  Timer {
    id: refreshTimer
    interval: 250
    onTriggered: if (root.opened && !root.closing) {
      Hyprland.refreshToplevels()
      Hyprland.refreshWorkspaces()
      settleTimer.restart()
    }
  }
  Timer {
    id: settleTimer
    interval: 120
    onTriggered: if (root.opened && !root.closing) root.relayout()
  }

  // ---- Building -------------------------------------------------------------

  function windowInfo(t, monitor) {
    var w = t.lastIpcObject || {}
    var ws = t.workspace
    var minimized = !!ws && String(ws.name || "") === "special:minimized"
    var at = w.at || [monitor.x, monitor.y]
    var size = w.size || [root.screenW / 2, root.screenH / 2]
    return {
      address: root.bare(t.address),
      toplevel: t.wayland,
      appId: String(t.wayland.appId || ""),
      workspaceId: ws ? ws.id : -1,
      minimized: minimized,
      onScreen: !!ws && ws.id === root.activeWorkspaceId,
      rect: { x: at[0] - monitor.x, y: at[1] - monitor.y, w: size[0], h: size[1] }
    }
  }

  function build() {
    var monitor = Hyprland.focusedMonitor
    if (!monitor || !monitor.activeWorkspace) return false
    var ipc = monitor.lastIpcObject || {}
    var scale = monitor.scale > 0 ? monitor.scale : 1
    root.monitorName = String(monitor.name || "")
    root.activeWorkspaceId = monitor.activeWorkspace.id
    // width and height are the mode's, before rotation.
    var rotated = (ipc.transform || 0) % 2 === 1
    root.screenW = Math.round((rotated ? monitor.height : monitor.width) / scale)
    root.screenH = Math.round((rotated ? monitor.width : monitor.height) / scale)
    var reserved = ipc.reserved || [0, 0, 0, 0]

    var list = []
    var wanted = root.appAddresses.map(root.bare)
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var t = toplevels[i]
      if (!t.wayland || !t.workspace) continue
      if (root.mode === "app") {
        if (wanted.indexOf(root.bare(t.address)) < 0) continue
      } else if (t.workspace.id !== root.activeWorkspaceId) continue
      list.push(root.windowInfo(t, monitor))
    }

    var order = Layout.readingOrder(list.map(function(item) { return item.rect }))
    list = order.map(function(index) { return list[index] })
    var top = reserved[1] + (root.stripShown ? root.stripTop + root.stripHeight : 0) + root.margin
    var area = {
      x: reserved[0] + root.margin,
      y: top,
      w: root.screenW - reserved[0] - reserved[2] - root.margin * 2,
      h: root.screenH - top - reserved[3] - root.margin
    }
    var result = Layout.layout(list.map(function(item) { return item.rect }), area, root.gap, root.labelRoom)
    for (var k = 0; k < list.length; k++) {
      var tile = result.tiles[k]
      list[k].tile = tile
      // A window that is not on screen starts small in the middle of its cell.
      if (!list[k].onScreen) list[k].rect = { x: tile.x + tile.w * 0.4, y: tile.y + tile.h * 0.4, w: tile.w * 0.2, h: tile.h * 0.2 }
    }
    root.windows = list
    root.workspaces = root.mode === "workspace" ? root.buildWorkspaces(monitor) : []
    return true
  }

  // The screen's workspaces, plus a new one at the end of the active one's
  // block of ten (Omarchy numbers workspaces per monitor in blocks of ten).
  function buildWorkspaces(monitor) {
    var block = Math.floor((root.activeWorkspaceId - 1) / 10)
    var ids = []
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var w = values[i]
      if (w.id <= 0 || !w.monitor || w.monitor.name !== monitor.name) continue
      if (ids.indexOf(w.id) < 0) ids.push(w.id)
    }
    if (ids.indexOf(root.activeWorkspaceId) < 0) ids.push(root.activeWorkspaceId)
    ids.sort(function(a, b) { return a - b })
    var result = ids.map(function(id) { return { id: id, slot: root.slotOf(id), fresh: false } })
    var inBlock = ids.filter(function(id) { return Math.floor((id - 1) / 10) === block })
    var last = inBlock.length > 0 ? root.slotOf(inBlock[inBlock.length - 1]) : 0
    if (last < 10) result.push({ id: block * 10 + last + 1, slot: last + 1, fresh: true })
    return result
  }

  // A workspace's windows, scaled down to a strip card.
  function miniWindows(workspaceId) {
    var monitor = Hyprland.focusedMonitor
    if (!monitor || root.screenW <= 0) return []
    var k = root.stripCardW / root.screenW
    var out = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var t = toplevels[i]
      if (!t.wayland || !t.workspace || t.workspace.id !== workspaceId) continue
      var w = t.lastIpcObject || {}
      if (!w.at || !w.size) continue
      out.push({ toplevel: t.wayland, x: (w.at[0] - monitor.x) * k, y: (w.at[1] - monitor.y) * k, w: w.size[0] * k, h: w.size[1] * k })
    }
    return out
  }

  function selectInitial() {
    root.selectedIndex = -1
    for (var i = 0; i < root.windows.length; i++) {
      if (root.windows[i].toplevel && root.windows[i].toplevel.activated) root.selectedIndex = i
    }
    if (root.selectedIndex < 0 && root.windows.length > 0) root.selectedIndex = 0
  }

  function start() {
    if (switcher.opened) switcher.cancel()
    Hyprland.refreshToplevels()
    Hyprland.refreshWorkspaces()
    if (!root.build()) return
    // App Exposé for windows that are gone: nothing to show.
    if (root.mode === "app" && root.windows.length === 0) return
    // Opening again during the close animation cancels it.
    closeTimer.stop()
    root.selectInitial()
    root.closing = false
    root.expanded = false
    root.pendingFocus = null
    root.pendingWorkspace = -1
    root.dragIndex = -1
    root.opened = true
    // The refresh above is asynchronous: lay out again with fresh positions.
    refreshTimer.restart()
  }

  function openWorkspace() {
    root.mode = "workspace"
    root.appAddresses = []
    root.start()
  }

  function openApp(json) {
    var list = []
    try { list = JSON.parse(String(json || "[]")) } catch (e) { list = [] }
    if (!Array.isArray(list) || list.length === 0) return
    if (root.opened) { root.opened = false; root.windows = [] }
    root.mode = "app"
    root.appAddresses = list.slice(0, 64).map(String)
    root.start()
  }

  function relayout() {
    var keep = root.selectedIndex >= 0 && root.selectedIndex < root.windows.length ? root.windows[root.selectedIndex].address : ""
    if (!root.build()) return
    root.selectedIndex = -1
    for (var i = 0; i < root.windows.length; i++) if (root.windows[i].address === keep) root.selectedIndex = i
    if (root.selectedIndex < 0 && root.windows.length > 0) root.selectedIndex = 0
    if (root.mode === "app" && root.windows.length === 0) root.close(null)
  }

  // Closes by sending the thumbnails back to their windows, then focuses
  // window or shows workspaceId when given.
  function close(window, workspaceId) {
    if (root.closing) return
    root.closing = true
    root.pendingFocus = window || null
    root.pendingWorkspace = workspaceId >= 1 ? workspaceId : -1
    root.dragIndex = -1
    root.expanded = false
    closeTimer.restart()
  }

  Timer {
    id: closeTimer
    interval: root.animMs
    onTriggered: {
      root.opened = false
      root.closing = false
      var target = root.pendingFocus
      var workspace = root.pendingWorkspace
      root.pendingFocus = null
      root.pendingWorkspace = -1
      root.windows = []
      root.workspaces = []
      if (target) root.focusWindow(target)
      else if (workspace >= 1) root.showWorkspace(workspace)
    }
  }

  // An existing workspace is focused by its id; a new one goes through
  // Omarchy, which creates it on this monitor.
  function showWorkspace(id) {
    var exists = Hyprland.workspaces.values.some(function(w) { return w.id === id })
    if (exists) Util.execDetached(root.dispatchCommand("hl.dsp.focus({ workspace = \"" + id + "\" })"))
    else Util.execDetached(root.dispatchCommand("o.workspaces.focus(" + root.slotOf(id) + ", " + JSON.stringify(root.monitorName) + ")"))
  }

  function move(direction) {
    var tiles = root.windows.map(function(item) { return item.tile })
    var next = Layout.neighbor(tiles, root.selectedIndex, direction)
    if (next >= 0) root.selectedIndex = next
  }

  function stripIndexAt(point) {
    for (var i = 0; i < stripRepeater.count; i++) {
      var card = stripRepeater.itemAt(i)
      if (!card) continue
      var p = card.mapFromItem(panel.contentItem, point.x, point.y)
      if (p.x >= 0 && p.y >= 0 && p.x <= card.width && p.y <= card.height) return i
    }
    return -1
  }

  function labelFor(window) {
    var title = (window.toplevel && window.toplevel.title) || window.appId
    if (root.mode !== "app" || window.onScreen) return title
    return root.placeLabel(title, window)
  }

  // "Title · minimized" or "Title · workspace 3", shared with the switcher.
  function placeLabel(title, window) {
    if (window.minimized) return strings.t("window.minimized").arg(title)
    return strings.t("window.onWorkspace").arg(title).arg(root.slotOf(window.workspaceId))
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "qexpose"

    // The thumbnails leave their windows once the surface is up.
    readonly property bool ready: contentRevealed
    onReadyChanged: if (ready && root.opened && !root.closing) Qt.callLater(function() { root.expanded = true })

    // A nearly opaque veil, so the real windows left in place behind it are
    // not mistaken for their thumbnails.
    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Commons.Color.background, 0.9)
      opacity: root.expanded ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: root.animMs; easing.type: Easing.OutCubic } }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.close(null)
    }

    // ---- Workspace strip (Super+D) --------------------------------------------
    Row {
      id: strip
      visible: root.stripShown && root.workspaces.length > 0
      spacing: Style.space(16)
      x: (parent.width - width) / 2
      y: ((Hyprland.focusedMonitor && Hyprland.focusedMonitor.lastIpcObject && Hyprland.focusedMonitor.lastIpcObject.reserved) ? Hyprland.focusedMonitor.lastIpcObject.reserved[1] : 0) + root.stripTop
      opacity: root.expanded ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: root.animMs } }

      Repeater {
        id: stripRepeater
        model: root.workspaces

        delegate: Item {
          id: card

          required property var modelData
          required property int index

          readonly property bool current: modelData.id === root.activeWorkspaceId
          readonly property bool target: root.dropWorkspace === modelData.id
          readonly property bool hovered: cardMouse.containsMouse

          width: root.stripCardW
          height: root.stripCardH + cardLabel.height + Style.space(6)

          Rectangle {
            id: cardBox
            width: root.stripCardW
            height: root.stripCardH
            radius: root.radius
            clip: true
            color: Util.alpha(Commons.Color.popups.background, card.modelData.fresh ? 0.35 : (root.macStyle ? 0.85 : 1))
            border.width: card.current || card.target || card.hovered ? Math.max(2, Style.space(3)) : Math.max(1, Style.space(1))
            border.color: card.target ? Commons.Color.accent
              : card.current ? Commons.Color.accent
              : card.hovered ? Util.alpha(Commons.Color.accent, 0.6)
              : Util.alpha(Commons.Color.muted, 0.6)

            Repeater {
              model: card.modelData.fresh || !root.opened ? [] : root.miniWindows(card.modelData.id)

              delegate: ScreencopyView {
                required property var modelData
                x: modelData.x
                y: modelData.y
                width: Math.max(1, modelData.w)
                height: Math.max(1, modelData.h)
                captureSource: root.opened ? modelData.toplevel : null
                live: false
                constraintSize: Qt.size(Math.max(1, Math.round(modelData.w * 2)), Math.max(1, Math.round(modelData.h * 2)))
              }
            }

            Text {
              visible: card.modelData.fresh
              anchors.centerIn: parent
              text: "+"
              color: Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Math.round(root.stripCardH * 0.4)
            }
          }

          Text {
            id: cardLabel
            anchors.horizontalCenter: cardBox.horizontalCenter
            anchors.top: cardBox.bottom
            anchors.topMargin: Style.space(6)
            textFormat: Text.PlainText
            text: card.modelData.fresh ? strings.t("workspace.new") : strings.t("workspace.name").arg(card.modelData.slot)
            color: Commons.Color.popups.text
            opacity: card.current ? 1 : 0.7
            font.family: Style.font.family
            font.pixelSize: Math.round(Style.font.body * 0.9)
            font.bold: card.current
          }

          MouseArea {
            id: cardMouse
            anchors.fill: cardBox
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (card.current) root.close(null)
              else root.close(null, card.modelData.id)
            }
          }
        }
      }
    }

    Text {
      visible: root.opened && root.windows.length === 0
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: strings.t("workspace.empty")
      color: Commons.Color.menu.text
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
    }

    // ---- Thumbnails -------------------------------------------------------------
    Repeater {
      model: root.windows

      delegate: Item {
        id: tile

        required property var modelData
        required property int index

        readonly property bool selected: root.selectedIndex === index
        readonly property bool dragged: root.dragIndex === index
        readonly property var place: root.expanded ? modelData.tile : modelData.rect
        // While dragged, the thumbnail follows the pointer, shrunk.
        readonly property real dragScale: 0.45

        x: dragged ? root.dragPoint.x - root.dragGrab.x * dragScale : place.x
        y: dragged ? root.dragPoint.y - root.dragGrab.y * dragScale : place.y
        width: Math.max(1, dragged ? modelData.tile.w * dragScale : place.w)
        height: Math.max(1, dragged ? modelData.tile.h * dragScale : place.h)
        z: dragged ? 10 : (selected ? 2 : 1)
        opacity: root.expanded || modelData.onScreen ? 1 : 0

        Behavior on x { enabled: !tile.dragged; NumberAnimation { duration: root.animMs; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: !tile.dragged; NumberAnimation { duration: root.animMs; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: root.animMs; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: root.animMs; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: root.animMs } }

        // Until the capture arrives (or if it never does): the app's icon.
        Rectangle {
          anchors.fill: parent
          visible: !shot.hasContent
          radius: root.radius
          color: Commons.Color.popups.background

          Image {
            anchors.centerIn: parent
            width: Math.min(parent.width, parent.height) * 0.35
            height: width
            sourceSize: Qt.size(128, 128)
            source: root.iconFor(tile.modelData.appId)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
          }
        }

        ScreencopyView {
          id: shot
          anchors.fill: parent
          captureSource: root.opened ? tile.modelData.toplevel : null
          live: root.opened
          constraintSize: Qt.size(Math.round(tile.modelData.tile.w * 1.5), Math.round(tile.modelData.tile.h * 1.5))
        }

        // Outline, stronger on the selected window (hover or keyboard).
        Rectangle {
          anchors.fill: parent
          anchors.margins: -border.width
          color: "transparent"
          radius: root.radius
          border.width: tile.selected ? Math.max(2, Style.space(3)) : Math.max(1, Style.space(1))
          border.color: tile.selected ? Commons.Color.accent : Util.alpha(Commons.Color.muted, 0.6)
          opacity: root.expanded ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: root.animMs } }
        }

        // The app's icon, straddling the thumbnail's bottom edge.
        Image {
          readonly property int size: Math.round(36 * Style.fontScale)
          visible: !tile.dragged
          width: size
          height: size
          x: (parent.width - width) / 2
          y: parent.height - height * 0.6
          sourceSize: Qt.size(size * 2, size * 2)
          source: root.iconFor(tile.modelData.appId)
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
          mipmap: true
          opacity: root.expanded ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: root.animMs } }
        }

        // The title under the selected window.
        Rectangle {
          visible: tile.selected && root.expanded && !tile.dragged
          readonly property real maxWidth: Math.max(tile.width, Style.space(220))
          width: Math.min(maxWidth, titleText.implicitWidth + Style.spacing.md * 2)
          height: titleText.implicitHeight + Style.spacing.xs * 2
          x: (tile.width - width) / 2
          y: tile.height + Math.round(36 * Style.fontScale) * 0.5
          radius: root.macStyle ? height / 2 : Style.cornerRadius
          color: Commons.Color.tooltip.background

          Text {
            id: titleText
            anchors.centerIn: parent
            width: Math.min(implicitWidth, parent.maxWidth - Style.spacing.md * 2)
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.labelFor(tile.modelData)
            color: Commons.Color.tooltip.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        MouseArea {
          id: tileMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: root.dragIndex >= 0 ? Qt.ClosedHandCursor : Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
          property point pressAt
          property bool moved: false

          // Hover selects only once the pointer moves, so thumbnails sliding
          // under a still pointer don't steal the keyboard selection.
          onPressed: function(mouse) {
            pressAt = Qt.point(mouse.x, mouse.y)
            moved = false
          }
          onPositionChanged: function(mouse) {
            if (!pressed) {
              if (root.dragIndex < 0) root.selectedIndex = tile.index
              return
            }
            if (!(pressedButtons & Qt.LeftButton) || !root.stripShown) return
            if (!moved && Math.hypot(mouse.x - pressAt.x, mouse.y - pressAt.y) < Style.space(10)) return
            if (!moved) {
              moved = true
              // The grab point, relative to the thumbnail's size in the grid.
              root.dragGrab = Qt.point(pressAt.x * tile.modelData.tile.w / Math.max(1, tile.width), pressAt.y * tile.modelData.tile.h / Math.max(1, tile.height))
              root.dragIndex = tile.index
            }
            root.dragPoint = tileMouse.mapToItem(panel.contentItem, mouse.x, mouse.y)
            var over = root.stripIndexAt(root.dragPoint)
            root.dropWorkspace = over >= 0 ? root.workspaces[over].id : -1
          }
          onReleased: function(mouse) {
            if (!moved) return
            var target = root.dropWorkspace
            var window = tile.modelData
            root.dragIndex = -1
            root.dropWorkspace = -1
            if (target >= 1 && target !== root.activeWorkspaceId) root.moveWindowTo(window, target)
          }
          onClicked: function(mouse) {
            if (moved) return
            if (mouse.button === Qt.MiddleButton) root.closeWindow(tile.modelData)
            else root.close(tile.modelData)
          }
        }

        // × closes the window (top left corner, on hover).
        Rectangle {
          readonly property int size: Math.round(26 * Style.fontScale)
          visible: root.expanded && !tile.dragged && (tileMouse.containsMouse || closeMouse.containsMouse)
          width: size
          height: size
          radius: root.macStyle ? size / 2 : Style.cornerRadius
          x: -size / 3
          y: -size / 3
          z: 5
          color: closeMouse.containsMouse ? Commons.Color.urgent : Commons.Color.popups.background
          border.width: Math.max(1, Style.space(1.5))
          border.color: Util.alpha(Commons.Color.muted, 0.8)

          Text {
            anchors.centerIn: parent
            text: "×"
            color: closeMouse.containsMouse ? Commons.Color.background : Commons.Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Math.round(parent.size * 0.75)
            font.bold: true
          }

          MouseArea {
            id: closeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.closeWindow(tile.modelData)
          }
        }
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Component.onCompleted: forceActiveFocus()

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) root.close(null)
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          if (root.selectedIndex >= 0 && root.selectedIndex < root.windows.length) root.close(root.windows[root.selectedIndex])
          else root.close(null)
        }
        else if (event.key === Qt.Key_Left) root.move("left")
        else if (event.key === Qt.Key_Right) root.move("right")
        else if (event.key === Qt.Key_Up) root.move("up")
        else if (event.key === Qt.Key_Down) root.move("down")
        else if (event.key === Qt.Key_Tab && root.windows.length > 0) root.selectedIndex = (root.selectedIndex + 1) % root.windows.length
        else if (event.key === Qt.Key_Backtab && root.windows.length > 0) root.selectedIndex = (root.selectedIndex - 1 + root.windows.length) % root.windows.length
        else if (event.key === Qt.Key_W && (event.modifiers & Qt.ControlModifier) && root.selectedIndex >= 0) root.closeWindow(root.windows[root.selectedIndex])
        else return
        event.accepted = true
      }
    }

    onShownChanged: if (shown) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Switcher {
    id: switcher
    expose: root
  }
}
