import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Tui.js" as Tui

// Sign-in, sign-out and "service offline" states for the Orpheus window.
Rectangle {
  id: pane

  property var host: null
  readonly property var api: host ? host.api : null
  readonly property var login: api ? api.login : ({})
  property bool hires: host && host.page.hires === true

  color: Color.background
  focus: true

  function linkSignIn() {
    hires = false
    api.post("/login/link", {}, function(ok, d) { if (ok && d.url) Qt.openUrlExternally(d.url) })
  }
  function hiresSignIn() {
    hires = true
    api.post("/login/pkce/start", {}, function(ok, d) { if (ok && d.url) Qt.openUrlExternally(d.url) })
    Qt.callLater(function() { paste.forceActiveFocus() })
  }
  function finish() {
    api.post("/login/pkce/finish", { url: paste.text }, function(ok, d) {
      pane.finishing = false
      if (ok && d.state === "signed-in") { host.history = []; host.page = host.navItems[0].page }
    })
  }

  // Hi-res sign-in: watch the clipboard for TIDAL's redirect ("Oops" page) URL
  // and finish by itself, so nothing has to be pasted. Only runs while this
  // screen is waiting for it, and ignores anything that isn't that URL.
  readonly property var redirectPattern: /^https:\/\/tidal\.com\/android\/login\/auth\?\S*code=[^\s&]+\S*$/
  property bool finishing: false
  property bool manualPaste: false
  function tryUrl(text) {
    var t = String(text || "").trim()
    if (finishing || !redirectPattern.test(t)) return false
    finishing = true
    paste.text = t
    finish()
    return true
  }
  Timer {
    interval: 1200
    repeat: true
    running: pane.hires && !!pane.api && pane.login.state === "waiting" && pane.login.method === "pkce" && !pane.finishing
    onTriggered: pane.readClipboard()
  }
  // wl-paste works without focus on Wayland; Windows has a plain clipboard.
  function readClipboard() {
    if (Qt.platform.os === "windows") pane.clipboardRead(Quickshell.clipboardText)
    else clip.running = true
  }
  function clipboardRead(text) {
    if (!pane.tryUrl(text) && pane.manualPaste) paste.insert(paste.cursorPosition, text.trim())
    pane.manualPaste = false
  }
  Process {
    id: clip
    command: ["wl-paste", "--no-newline", "--type", "text"]
    stdout: StdioCollector {
      onStreamFinished: pane.clipboardRead(text)
    }
  }

  Keys.onPressed: function(e) {
    if (e.text === "q" || (e.key === Qt.Key_W && (e.modifiers & Qt.ControlModifier))) { host.engine.libraryOpen = false; e.accepted = true; return }
    if (!api || !api.online) return
    if (e.text === "l") { linkSignIn(); e.accepted = true }
    else if (e.text === "h") { hiresSignIn(); e.accepted = true }
    else if (e.text === "o" && api.signedIn) { api.post("/logout"); e.accepted = true }
    else if (e.key === Qt.Key_Escape && api.signedIn) { host.back(); e.accepted = true }
  }
  Component.onCompleted: forceActiveFocus()

  Column {
    anchors.centerIn: parent
    width: Math.min(parent.width - host.cw * 4, host.cw * 64)
    spacing: host.ch * 0.6

    Text {
      text: "╱╱╱╱  O R P H E U S  ╱╱╱╱"
      font.family: host.family; font.pixelSize: Style.font.body + 6; font.bold: true
      color: host.accentText
    }

    // Offline
    Column {
      visible: !pane.api || !pane.api.online
      spacing: host.ch * 0.3
      Text { text: "the player service isn't running"; font.family: host.family; font.pixelSize: Style.font.body; color: host.fg }
      Text { text: "❯ systemctl --user start orpheusd"; font.family: host.family; font.pixelSize: Style.font.body; color: host.dim }
    }

    // Signed in (account page)
    Column {
      visible: !!pane.api && pane.api.online && pane.api.signedIn
      spacing: host.ch * 0.3
      Text {
        text: "● signed in" + (pane.login.user ? " as " + pane.login.user : "") + (pane.login.hires ? " · hi-res unlocked" : " · lossless")
        font.family: host.family; font.pixelSize: Style.font.body; color: host.fg
      }
      Text { visible: !pane.login.hires; text: "[h] sign in again for hi-res (24-bit)"; font.family: host.family; font.pixelSize: Style.font.body; color: host.dim }
      Text { text: "[o] sign out    [esc] back"; font.family: host.family; font.pixelSize: Style.font.body; color: host.dim }
    }

    // Signed out
    Column {
      visible: !!pane.api && pane.api.online && !pane.api.signedIn && !pane.hires
      spacing: host.ch * 0.3
      Text { text: "sign in with your TIDAL account"; font.family: host.family; font.pixelSize: Style.font.body; color: host.fg }
      Text {
        text: "[l] link sign-in        quickest · up to 16/44.1 lossless"
        font.family: host.family; font.pixelSize: Style.font.body; color: lm.containsMouse ? host.accentText : host.dim
        MouseArea { id: lm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pane.linkSignIn() }
      }
      Text {
        text: "[h] hi-res sign-in      one extra step · up to 24/192"
        font.family: host.family; font.pixelSize: Style.font.body; color: hm.containsMouse ? host.accentText : host.dim
        MouseArea { id: hm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pane.hiresSignIn() }
      }
      Text {
        visible: pane.login.state === "waiting" && pane.login.method === "link"
        width: parent.parent.width
        wrapMode: Text.WordWrap
        text: "approve Orpheus in the browser tab that opened\nor visit " + (pane.login.url || "") + "  code " + (pane.login.code || "")
        font.family: host.family; font.pixelSize: Style.font.body; color: host.accentText
        topPadding: host.ch * 0.5
      }
    }

    // Hi-res (PKCE) flow
    Column {
      visible: !!pane.api && pane.api.online && pane.hires
      width: parent.width
      spacing: host.ch * 0.3
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: "1  sign in on the TIDAL page that opened\n2  you'll land on a page that says \"Oops\". That's expected\n3  copy that page's full address (ctrl+l, ctrl+c). Orpheus picks it up by itself"
        font.family: host.family; font.pixelSize: Style.font.body; color: host.fg
      }
      Rectangle {
        width: parent.width
        height: host.ch * 1.6
        color: "transparent"
        border.width: 1
        border.color: paste.activeFocus ? Color.accent : Tui.mix(Color.foreground, Color.background, 0.7)
        Text { id: prompt; x: host.cw; anchors.verticalCenter: parent.verticalCenter; text: "❯"; font.family: host.family; font.pixelSize: Style.font.body; color: host.accentText }
        TextInput {
          id: paste
          anchors.left: prompt.right; anchors.leftMargin: host.cw
          anchors.right: parent.right; anchors.rightMargin: host.cw
          anchors.verticalCenter: parent.verticalCenter
          clip: true
          font.family: host.family; font.pixelSize: Style.font.body
          color: host.fg
          selectionColor: Tui.alpha(Color.accent, 0.35)
          onAccepted: pane.finish()
          Keys.onEscapePressed: { pane.hires = false; pane.forceActiveFocus() }
          Keys.onPressed: function(e) {
            if ((e.key === Qt.Key_V && (e.modifiers & Qt.ControlModifier)) || (e.key === Qt.Key_Insert && (e.modifiers & Qt.ShiftModifier))) {
              pane.manualPaste = true
              pane.readClipboard()
              e.accepted = true
            }
          }
          Text { visible: !parent.text; text: "https://tidal.com/android/login/auth?code=…"; font: parent.font; color: host.dim }
        }
      }
      Text {
        text: pane.finishing ? "signing in…" : "watching the clipboard ·  [⏎] finish manually    [esc] use a link instead"
        font.family: host.family; font.pixelSize: Style.font.caption; color: pane.finishing ? host.accentText : host.dim
      }
    }

    Text {
      visible: !!pane.login.error
      width: parent.width
      wrapMode: Text.WordWrap
      text: "✕ " + (pane.login.error || "")
      font.family: host.family; font.pixelSize: Style.font.body; color: Tui.ensure(Color.urgent, Color.background, 4.5)
    }
  }
}
