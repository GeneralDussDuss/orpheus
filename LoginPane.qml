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

  color: Color.glass === true ? "transparent" : Color.background   // under glass the window paints the tint
  focus: true

  function signOut() { api.post("/logout") }
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
    else if (e.text === "o" && api.signedIn) { signOut(); e.accepted = true }
    else if (e.key === Qt.Key_Escape && api.signedIn) { host.back(); e.accepted = true }
  }
  Component.onCompleted: forceActiveFocus()

  // Which state is on screen: they crossfade in one place, not reflow.
  readonly property bool offline: !api || !api.online
  readonly property bool accountOn: !!api && api.online && api.signedIn
  readonly property bool signedOutOn: !!api && api.online && !api.signedIn && !hires
  readonly property bool hiresOn: !!api && api.online && hires && !api.signedIn
  readonly property color urgent: Tui.ensure(Color.urgent, host.textBg || Color.background, 4.5)

  component StateColumn: Column {
    property bool on: false
    width: parent.width
    spacing: pane.host.ch * 0.3
    opacity: on ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: Tui.STATE; easing.type: Tui.EASE } }
  }

  Column {
    anchors.centerIn: parent
    width: Math.min(parent.width - host.cw * 4, host.cw * 64)
    spacing: host.ch * 0.6

    // ╱╱╱╱ ORPHEUS ╱╱╱╱: the mark, set in display type with a held halo
    Row {
      spacing: host.cw * 1.5
      bottomPadding: host.ch * 0.3
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "╱╱╱╱"
        font.family: host.family; font.pixelSize: Tui.px("display", Style.font.body)
        color: host.accentText
      }
      GlowText {
        anchors.verticalCenter: parent.verticalCenter
        text: "ORPHEUS"
        font.family: host.family; font.pixelSize: Tui.px("display", Style.font.body); font.bold: true; font.letterSpacing: Tui.TRACK.display
        color: host.accentText
        glow: Tui.bloom(host.engine) * 0.6
        glowLive: glow > 0
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "╱╱╱╱"
        font.family: host.family; font.pixelSize: Tui.px("display", Style.font.body)
        color: host.accentText
      }
    }

    Item {
      id: stack
      width: parent.width
      height: pane.offline ? offlineCol.implicitHeight : pane.accountOn ? accountCol.implicitHeight
            : pane.hiresOn ? hiresCol.implicitHeight : signedOutCol.implicitHeight
      Behavior on height { NumberAnimation { duration: Tui.STATE; easing.type: Tui.EASE } }

      // Offline
      StateColumn {
        id: offlineCol
        on: pane.offline
        Text {
          text: pane.api && pane.api.connecting ? "starting the player service…"
                : pane.api && pane.api.reconnecting ? "lost the player service, reconnecting…"
                : "the player service isn't running"
          font.family: host.family; font.pixelSize: Tui.px("body", Style.font.body); color: host.fg
        }
        // On Windows the app restarts the daemon itself, so there is nothing to tell
        // the user to do unless that has given up (connecting stops after 12 tries).
        Text {
          visible: Qt.platform.os !== "windows" || !(pane.api && (pane.api.connecting || pane.api.reconnecting))
          text: Qt.platform.os === "windows" ? "❯ quit Orpheus from the tray and open it again"
                                             : "❯ systemctl --user start orpheusd"
          font.family: host.family; font.pixelSize: Tui.px("body", Style.font.body); color: host.dim
        }
        // it is already trying again on its own; say so, so the page isn't a dead end
        Text {
          topPadding: host.ch * 0.4
          textFormat: Text.StyledText
          text: Tui.busy(host.clock, "reconnecting by itself", Tui.hex(host.accentText))
          font.family: host.family; font.pixelSize: Tui.px("caption", Style.font.body); color: host.dim
        }
      }

      // Signed in (account page)
      StateColumn {
        id: accountCol
        on: pane.accountOn
        Text {
          // masked like the rail's account line: this page ends up in screenshots too
          text: "● signed in" + (pane.login.user ? " as " + host.maskAccount(pane.login.user) : "") + (pane.login.hires ? " · hi-res unlocked" : " · lossless")
          font.family: host.family; font.pixelSize: Tui.px("body", Style.font.body); color: host.fg
          bottomPadding: host.ch * 0.3
        }
        HintBar {
          pixelSize: Tui.px("body", Style.font.body)
          keyColor: host.accentText; labelColor: host.dim; hoverColor: host.accentText
          items: (pane.login.hires ? [] : [{ k: "h", l: "sign in again for hi-res (24-bit)", run: function() { pane.hiresSignIn() }, tip: "a second sign-in unlocks 24-bit" }])
                 .concat([{ k: "o", l: "sign out", run: function() { pane.signOut() }, tip: "sign out of TIDAL" },
                          { k: "esc", l: "back", run: function() { host.back() } }])
        }
      }

      // Signed out
      StateColumn {
        id: signedOutCol
        on: pane.signedOutOn
        Text { text: "sign in with your TIDAL account"; font.family: host.family; font.pixelSize: Tui.px("body", Style.font.body); color: host.fg; bottomPadding: host.ch * 0.2 }
        Repeater {
          model: [{ k: "l", l: "link sign-in", d: "quickest · up to 16/44.1 lossless", run: function() { pane.linkSignIn() }, tip: "sign in through a link in the browser" },
                  { k: "h", l: "hi-res sign-in", d: "one extra step · up to 24/192", run: function() { pane.hiresSignIn() }, tip: "sign in for 24-bit" }]
          Row {
            required property var modelData
            Item {
              width: host.cw * 22; height: optBar.height
              HintBar {
                id: optBar
                pixelSize: Tui.px("body", Style.font.body)
                keyColor: host.accentText; labelColor: host.fg; hoverColor: host.accentText
                items: [modelData]
              }
            }
            Text { text: modelData.d; font.family: host.family; font.pixelSize: Tui.px("body", Style.font.body); color: host.dim }
          }
        }
        Text {
          visible: pane.login.state === "waiting" && pane.login.method === "link"
          width: parent.width
          wrapMode: Text.WordWrap
          text: "approve Orpheus in the browser tab that opened\nor visit " + (pane.login.url || "") + "  code " + (pane.login.code || "")
          font.family: host.family; font.pixelSize: Tui.px("body", Style.font.body); color: host.accentText
          topPadding: host.ch * 0.5
        }
      }

      // Hi-res (PKCE) flow
      StateColumn {
        id: hiresCol
        on: pane.hiresOn
        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: "1  sign in on the TIDAL page that opened\n2  you'll land on a page that says \"Oops\". That's expected\n3  copy that page's full address (ctrl+l, ctrl+c). Orpheus picks it up by itself"
          font.family: host.family; font.pixelSize: Tui.px("body", Style.font.body); color: host.fg
        }
        Rectangle {
          width: parent.width
          height: host.ch * 1.6
          color: "transparent"
          border.width: 1
          // the frame eases toward the accent when the field takes the keys
          property real focusIn: paste.activeFocus ? 1 : 0
          Behavior on focusIn { NumberAnimation { duration: Tui.HOVER; easing.type: Tui.EASE } }
          border.color: Tui.mix(host.dim, host.accent, focusIn)
          Text { id: prompt; x: host.cw; anchors.verticalCenter: parent.verticalCenter; text: "❯"; font.family: host.family; font.pixelSize: Tui.px("body", Style.font.body); color: host.accentText }
          TextInput {
            id: paste
            anchors.left: prompt.right; anchors.leftMargin: host.cw
            anchors.right: parent.right; anchors.rightMargin: host.cw
            anchors.verticalCenter: parent.verticalCenter
            clip: true
            font.family: host.family; font.pixelSize: Tui.px("body", Style.font.body)
            color: host.fg
            selectionColor: Tui.alpha(Color.accent, Tui.A.select)
            cursorDelegate: TuiCaret { host: pane.host; visible: paste.activeFocus }
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
            // an I-beam over the field: it is a place to type
            MouseArea { anchors.fill: parent; acceptedButtons: Qt.NoButton; cursorShape: Qt.IBeamCursor }
          }
        }
        Row {
          spacing: host.cw * 2
          Text {
            textFormat: Text.StyledText
            text: pane.finishing ? Tui.busy(host.clock, "signing in", Tui.hex(host.accentText)) : "watching the clipboard ·"
            font.family: host.family; font.pixelSize: Tui.px("caption", Style.font.body); color: host.dim
          }
          HintBar {
            visible: !pane.finishing
            keyColor: host.accentText; labelColor: host.dim; hoverColor: host.accentText
            items: [{ k: "⏎", l: "finish manually", run: function() { pane.finish() }, tip: "finish with what is in the field" },
                    { k: "esc", l: "use a link instead", run: function() { pane.hires = false; pane.forceActiveFocus() } }]
          }
        }
      }
    }

    Row {
      visible: !!pane.login.error
      width: parent.width
      spacing: host.cw
      Text { id: errMark; text: "✕"; font.family: host.family; font.pixelSize: Tui.px("body", Style.font.body); color: pane.urgent }
      Text {
        width: parent.width - errMark.width - host.cw
        wrapMode: Text.WordWrap
        text: pane.login.error || ""
        font.family: host.family; font.pixelSize: Tui.px("body", Style.font.body); color: host.fg
      }
    }
  }
}
