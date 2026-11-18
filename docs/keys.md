# Keys

Press `?` in the player or the visualizer window for the same list, live. On Linux the sheet also
asks Hyprland what the global keys are bound to right now, so it follows a rebind.

## Global keys

### Linux (Hyprland, from `hypr/orpheus.lua`)

| key | |
|---|---|
| `Super+Shift+M` | the player (takes over Omarchy's music key, Spotify by default) |
| `Super+Ctrl+M` | the visualizer window |
| `Super+Alt+M` | the desktop widget on / off |
| `Ctrl+Shift+O` | sign in |

To bring your own keys, put `orpheus_bindings = false` in `hyprland.lua` above the
`require("hypr.orpheus")` line. The window rules stay. Some binds worth adding yourself:

```lua
o.bind("SUPER + CTRL + T", "Music tape deck", "omarchy-shell -q orpheus cassette")
o.bind("SUPER + SHIFT + C", "Copy song link", "orpheus share")
```

### Windows (rebindable in settings)

`Win+Alt+M` player, `Win+Alt+V` visualizer, `Win+Alt+P` mini player, `Win+Alt+W` widget,
`Win+Alt+Space` play / pause, `Win+Alt+←` / `→` previous / next, `Win+Alt+N` the HUD,
`Win+Alt+Q` the tape deck, and more. The `?` sheet lists the ones your run actually registered, and why
any did not. Media keys and the Windows media overlay work too.

## In the player

| keys | |
|---|---|
| `ctrl+k` | command palette |
| `?` | key sheet |
| `,` | settings |
| `/` | search |
| `1`-`9` | sections: home, search, mixes, playlists, albums, tracks, artists, video, stats |
| `e` · `L` | equalizer · lyrics |
| `esc` `⌫` | back |
| `q` `ctrl+w` | close the player |
| `space` | play / pause |
| `n` `p` | next / previous track |
| `l` `h` `→` `←` | seek ± 10 s |
| `+` `-` | volume ± 5 |
| `s` · `r` | shuffle · repeat (off, all, one) |
| `F` | like what is playing |
| `y` `Y` | copy a TIDAL link / a universal song.link |
| `v` | cycle the player's visualizer rail |
| `V` | open / close the visualizer window |
| `t` | tape deck on / off |

Lists: `j` `k` `↓` `↑` move, `pgdn` `pgup` move 10, `g` `G` top / bottom, `⏎` open or play,
`a` play the row next, `f` like the row, `P` `S` play / shuffle the page.

Search box: type to search, `↓` or `esc` to the results, `⏎` opens the selected one.

## In the visualizer window

| keys | |
|---|---|
| `l` `h` `→` `←` | next / previous style; in the deck, shuttle ± 10 s |
| `1`-`9` `0` `⇧1`-`⇧9` | pick a style (leaves the deck) |
| `J` · `N` | style journey on / off · its next leg |
| `t` | tape deck / visualizer |
| `E` | eject (tape deck only) |
| `f` | fullscreen show / window |
| `m` | mini player on / off |
| `F` | like what is playing |
| `space` | play / pause |
| `?` · `esc` | key sheet · close |

## Widget (floating or tiled window)

`space` play / pause, `n` `p` next / previous, `F` like, `V` the visualizer window. The decks print
these keys on their controls when the window can take the keyboard. The corner widget is a layer
surface with no keyboard, so it uses the mouse only.

## Mouse

Player: click a row to select, double-click to play or open, right-click for queue, radio and link.
Click the picture for the next rail visual (right-click goes back), scroll it to step through.
Click art or artist to go there, click up-next to play it now. Drag the seek bar to scrub (hover shows
the time). The volume takes click, drag or scroll. Drag the top edge to move the window. The eq
readout opens on click and bypasses on right-click. Key hints are buttons too, and hovering anything
says what it does and its key.

Visualizer and widget: click for the next style, right-click back, scroll to step through. Double-click
the fullscreen show to get a window back. Drag the title to move the floating widget or the
visualizer's window card; double-click the card's title to centre it again. On the tape deck, drag
a reel to scrub (one turn is 30 s, scroll for ± 5 s) and click a j-card track to play it. Drop a
`.frag` on the visualizer to import it as a style.

Bar: click for the visualizer, right-click or scroll for the next style, middle-click for the mini player.

## Panes

- **Web page**: `⇥` next provider, `⏎` watch, `a` listen instead, `c` hand over to Curd, `space`
  pause, `l` `h` seek, `F` fullscreen, `x` close the video.
- **Equalizer**: `h` `l` pick a band, `k` `j` up / down half a decibel, `K` `J` coarse, `0` zero the band,
  `z` zero all, `>` `<` next / previous preset, `b` bypass, `]` `[` preamp, `\` auto headroom, `A` find
  headphones (AutoEQ), `x` AutoEQ on / off, `X` forget it. Mouse: click or drag a band, scroll to nudge,
  middle-click zeroes, right-click bypasses.
- **AutoEQ picker**: type to filter, `⏎` apply, `↑` `↓` move, `pgup` `pgdn` page, `ctrl+r` refresh the
  index, `esc` back to the bars.
- **Lyrics**: `]` `[` sync later / earlier (a quarter second), `\` reset the sync, `m` entrance (wave,
  rain, plain), `j` `k` scroll, `g` `G` top / bottom, click a line to seek there.
- **Stats**: `⇥` `⇧⇥` `]` `[` or `l` `h` change range, `w` wrapped, `R` reload, `j` `k` `pgdn` `pgup`
  `g` `G` scroll.
- **Settings**: `⇥` `⇧⇥` `]` `[` section, `j` `k` move, `pgdn` `pgup` move 8, `g` `G` first / last,
  `l` `h` change a value, `⏎` set, edit or rebind, `d` back to default, `x` `del` hotkey off / clear a
  text, `/` `ctrl+f` search every setting, `esc` clear the search, then back. Mouse: click steps,
  right-click goes back, double-click edits.
- **Sign in**: `l` link sign-in, `h` hi-res sign-in, `o` sign out, `esc` back once signed in.
- **Menus**: `j` `k` `⇥` `⇧⇥` move, `⏎` `space` run, `g` `G` `home` `end` first / last, `esc` `q` close.
- **Command palette**: type to filter, `↓` `↑` or `ctrl+j/k` `ctrl+n/p` pick, `pgdn` `pgup` move 8,
  `⏎` or click runs, `esc` `ctrl+k` close.
- **This sheet**: it opens on the current window's keys (`keys · equalizer`, …); `a` swaps to every key and back. `j` `k` scroll, `space` `pgdn` `pgup` a page, `g` `G` top / bottom, `esc` `?` `q` close.

## Sharing

`y` copies a TIDAL link for the row under the cursor, not necessarily what is playing, since what you
want to send is usually what you are looking at. `Y` copies a [song.link](https://song.link) instead,
which opens on whatever service your friend uses; a bare TIDAL link is no use to someone on Spotify.
Tracks and albums have a universal form, artists and playlists do not, and a mix has no link at all:
its id means nothing outside your account.

`orpheus share` does the same from a keybind with nothing open (`-u` for the universal link). It asks
the daemon rather than the shell, because the window's status poll only runs while a window is on screen.

## Command line

`orpheus [open|stage|close|toggle|status|share [-u]|tape]` is idempotent: `open` and `close` check
state first, `toggle` flips the player, `status` prints the shell's status JSON, `tape` toggles the
tape deck. Apart from `share`, everything is an IPC call; nothing is launched or kept alive. That
is what makes it safe for a `.desktop` entry, which a launcher may fire twice.

For everything else, call the shell directly. See [config.md](config.md#ipc) for the methods.
