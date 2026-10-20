# Changelog

All notable changes to QTube Music. Versions follow [Semantic Versioning](https://semver.org); `Scripts/release.sh`
uses the section for a version as its release notes.

## 0.1.1

Fixes.

- **Stage top bar responds again.** Close, Lyrics options, Appearance and Song | Video sit in the window's title
  bar strip, which was taking clicks for itself. Clicks now go straight to the buttons. Moving the pointer over the
  Stage no longer redraws the whole Stage on every move.
- **No stray frame around the lyrics.** Clicking a lyric line no longer draws a focus ring around the lyrics. The
  ring still shows when you reach the lyrics with Tab.
- **Library tables.** The time no longer touches the edge of a highlighted row.
- **Now Playing panel.** The lyrics options button sits next to Song | Video instead of at the panel's edge.
- **Menu bar.** The song title is vertically centred like the menu bar's own text.

## 0.1.0

The first public release: a native macOS 15+ client for YouTube Music.

- **Window.** Home, Explore and search, plus Liked songs, playlists, albums, artists and history. Library tables
  sort and filter. A docked Now Playing / Queue panel, and song shelves that page sideways with See All.
- **Stage.** A full-screen now-playing view with three layouts and five backgrounds: blur, cover, vinyl, music
  video and an audio-reactive visualizer.
- **Lyrics.** Word-synced karaoke from YouTube Music, LRCLIB and the AMLL TTML DB, with NetEase, Kugou and QQ
  Music as opt-in sources. Free scrolling with a jump back to the current line, and a timing offset. On-device
  translation through the Translation framework, or Apple Intelligence on macOS 26. Chinese lyrics show in
  Simplified or Traditional characters to match your choice (OpenCC).
- **Song ⇄ Video** at the same position, and Picture in Picture.
- **Playback.** YouTube's web player for every account; signed-out listening plays ads, the same as on the web. A
  calm ad state, media keys, Control Center and AirPlay.
- **Native engine (Experimental, Premium only).** Opt-in gapless playback, crossfade and a 10-band EQ, with
  automatic fallback to the web player.
- **Around the Mac.** A mini player, a menu bar player, desktop lyrics, Shortcuts (App Intents), AppleScript, and
  opt-in Last.fm and Discord.
- **Look.** Liquid Glass on macOS 26, light and dark modes, an accent colour taken from the playing song's cover
  (or the system accent), and English and Simplified Chinese.
- Builds are ad-hoc signed, not notarized. See the README for how to open the app the first time.
