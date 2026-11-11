import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// An Alt+Tab switcher, as on Windows and the Mac: while Alt is held, a row of
// window previews (every workspace, minimized windows included), most recently
// used first. Each Tab moves on (Shift+Tab moves back); releasing Alt goes to
// the chosen window. Escape cancels; a click also chooses.
//
// Hyprland sends switcherNext / switcherPrev on Alt+Tab and Alt+Shift+Tab, and
// switcherCommit when Alt is released. When Alt+Tab is tapped quickly, the
// release can arrive before the switcher opens: it is remembered, and the
// opening that follows switches straight to the previous window without
// showing anything.
Item {
  id: root

  property var expose: null

  property bool opened: false
  property var windows: []
  property int selectedIndex: 0
  property real commitAskedAt: 0
  // When the switcher last closed: the Alt release that closed it can reach
  // commit() twice (the panel's key handler and the Hyprland bind).
  property real closedAt: 0

  // Previews shrink as windows add up, so the rows stay on screen.
  readonly property int thumbH: Math.round(130 * Style.fontScale * Math.min(1, Math.sqrt(14 / Math.max(14, root.windows.length))))
  readonly property int cardPad: Style.space(10)
  readonly property int cardGap: Style.space(12)

  function collect() {
    var ex = root.expose
    var values = Hyprland.toplevels.values
    var list = []
    for (var i = 0; i < values.length; i++) {
      var t = values[i]
      if (!t.wayland || !t.workspace || !t.wayland.appId) continue
      var ws = t.workspace
      var name = String(ws.name || "")
      var minimized = name === "special:minimized"
      if (ws.id <= 0 && !minimized) continue
      var ipc = t.lastIpcObject || {}
      var size = ipc.size || [16, 10]
      list.push({
        address: ex.bare(t.address),
        toplevel: t.wayland,
        appId: String(t.wayland.appId || ""),
        workspaceId: ws.id,
        minimized: minimized,
        aspect: size[1] > 0 ? size[0] / size[1] : 1.6
      })
    }
    var mru = ex.mru
    list.sort(function(a, b) {
      var ia = mru.indexOf(a.address), ib = mru.indexOf(b.address)
      if (ia < 0) ia = 100000
      if (ib < 0) ib = 100000
      return ia - ib
    })
    return list
  }

  // The previous window: the second one when the first has the focus, else
  // the first (nothing focused, or the focused window just closed).
  function previousIndex(list) {
    var first = list[0]
    return first && first.toplevel && first.toplevel.activated ? Math.min(1, list.length - 1) : 0
  }

  function quickSwitch() {
    var list = root.collect()
    var index = root.previousIndex(list)
    if (list[index] && !(list[index].toplevel && list[index].toplevel.activated)) root.expose.focusWindow(list[index])
  }

  function begin(step) {
    if (root.expose.opened) return
    // Alt already released (Alt+Tab tapped quickly): switch straight away.
    if (Date.now() - root.commitAskedAt < 250) {
      root.commitAskedAt = 0
      if (step > 0) root.quickSwitch()
      return
    }
    root.windows = root.collect()
    if (root.windows.length === 0) return
    root.selectedIndex = step > 0 ? root.previousIndex(root.windows) : root.windows.length - 1
    root.opened = true
  }

  function next() {
    if (!root.opened) return root.begin(1)
    if (root.windows.length > 0) root.selectedIndex = (root.selectedIndex + 1) % root.windows.length
  }

  function prev() {
    if (!root.opened) return root.begin(-1)
    if (root.windows.length > 0) root.selectedIndex = (root.selectedIndex - 1 + root.windows.length) % root.windows.length
  }

  function commit() {
    if (!root.opened) {
      if (Date.now() - root.closedAt > 300) root.commitAskedAt = Date.now()
      return
    }
    var target = root.windows[root.selectedIndex]
    root.cancel()
    if (target) root.expose.focusWindow(target)
  }

  function cancel() {
    root.opened = false
    root.windows = []
    root.closedAt = Date.now()
  }

  function labelFor(window) {
    if (!window) return ""
    var title = (window.toplevel && window.toplevel.title) || window.appId
    var monitor = Hyprland.focusedMonitor
    var here = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
    if (window.minimized || window.workspaceId !== here) return root.expose.placeLabel(title, window)
    return title
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "qexpose-switcher"

    readonly property real maxRowWidth: width * 0.86

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.ceil(flow.implicitW) + contentLeftInset + contentRightInset
      height: flow.height + titleLine.height + Style.space(14) + contentTopInset + contentBottomInset
      radius: root.expose.macStyle ? Math.max(Style.cornerRadius, Style.space(16)) : Style.cornerRadius
      color: root.expose.macStyle ? Util.alpha(Commons.Color.menu.background, 0.85) : Commons.Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.md

      Flow {
        id: flow
        // The widest row once the cards wrap at the screen's width, so a
        // wrapped panel has no empty space on its right.
        readonly property real implicitW: {
          var widest = 0, row = 0
          for (var i = 0; i < root.windows.length; i++) {
            var w = root.cardWidth(root.windows[i])
            if (row > 0 && row + root.cardGap + w > panel.maxRowWidth) {
              widest = Math.max(widest, row)
              row = w
            } else row += (row > 0 ? root.cardGap : 0) + w
          }
          return Math.max(Style.space(200), widest, row)
        }
        x: card.contentLeftInset
        y: card.contentTopInset
        width: card.width - card.contentLeftInset - card.contentRightInset
        spacing: root.cardGap

        Repeater {
          model: root.windows

          delegate: Item {
            id: cell

            required property var modelData
            required property int index

            readonly property bool selected: root.selectedIndex === index

            width: root.cardWidth(modelData)
            height: root.thumbH + root.cardPad * 2

            Rectangle {
              anchors.fill: parent
              radius: root.expose.radius
              color: cell.selected ? Util.alpha(Commons.Color.accent, 0.18) : "transparent"
              border.width: cell.selected ? Math.max(2, Style.space(3)) : 0
              border.color: Commons.Color.accent
            }

            Item {
              id: thumb
              x: root.cardPad
              y: root.cardPad
              width: parent.width - root.cardPad * 2
              height: root.thumbH

              Rectangle {
                anchors.fill: parent
                visible: !shot.hasContent
                radius: root.expose.radius
                color: Commons.Color.popups.background

                Image {
                  anchors.centerIn: parent
                  width: Math.min(parent.width, parent.height) * 0.45
                  height: width
                  sourceSize: Qt.size(128, 128)
                  source: root.expose.iconFor(cell.modelData.appId)
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                }
              }

              ScreencopyView {
                id: shot
                anchors.fill: parent
                captureSource: root.opened ? cell.modelData.toplevel : null
                live: root.opened && cell.selected
                constraintSize: Qt.size(Math.round(thumb.width * 1.5), Math.round(thumb.height * 1.5))
              }

              Image {
                readonly property int size: Math.round(32 * Style.fontScale)
                width: size
                height: size
                x: (parent.width - width) / 2
                y: parent.height - height * 0.7
                sourceSize: Qt.size(size * 2, size * 2)
                source: root.expose.iconFor(cell.modelData.appId)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
                mipmap: true
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.selectedIndex = cell.index
              onClicked: {
                root.selectedIndex = cell.index
                root.commit()
              }
            }
          }
        }
      }

      Text {
        id: titleLine
        x: card.contentLeftInset
        y: flow.y + flow.height + Style.space(8)
        width: card.width - card.contentLeftInset - card.contentRightInset
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: root.labelFor(root.windows[root.selectedIndex])
        color: Commons.Color.menu.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    MouseArea {
      anchors.fill: parent
      z: -1
      onClicked: root.cancel()
    }

    Item {
      id: keys
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) root.cancel()
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.commit()
        else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab) root.next()
        else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab) root.prev()
        else return
        event.accepted = true
      }
      Keys.onReleased: function(event) {
        if (event.key === Qt.Key_Alt) {
          root.commit()
          event.accepted = true
        }
      }
    }

    onShownChanged: if (shown) Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function cardWidth(window) {
    var a = Math.max(0.6, Math.min(1.9, window ? window.aspect : 1.6))
    return Math.round(root.thumbH * a) + root.cardPad * 2
  }
}
