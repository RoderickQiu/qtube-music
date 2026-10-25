# Changelog

All notable changes to QTube Music. Versions follow [Semantic Versioning](https://semver.org); `Scripts/release.sh`
uses the section for a version as its release notes.

## 0.3.0

Whole artists, your own lyrics, and fixes.

- **Play an artist means all of their songs.** Play and Shuffle on an artist (its page or a search result) used to
  queue only the five top songs. The top songs still start at once, and the artist's whole song list follows.
  Backing tracks (伴奏, Instrumental, Off Vocal, karaoke versions) are left out.
- **Import lyrics.** Controls › Lyrics Source › Import Lyrics… (also in the "No lyrics" view), or drop a file on the
  lyrics. LRC, TTML and plain text work, including Chinese files saved as GBK or Big5. The file shows for that song
  as "Imported", keeps its own timing, and Remove Imported Lyrics takes it away again.
- **Desktop lyrics move again.** Unlocked, the overlay can be dragged anywhere.
- **Hover in song lists.** A row no longer stays highlighted after the pointer has left, the list has scrolled or
  you switched to another app.
- **The end of the queue is reachable.** Its last songs and Save Queue as Playlist no longer sit under the player
  bar.
- **New playlists stay.** A playlist you make (New Playlist or Save Queue as Playlist) no longer disappears from the
  sidebar a moment later, and its page opens instead of saying it couldn't load.

## 0.2.0

Your account, playback you can leave running, and the gaps people kept asking about.

- **Likes and playlists sync.** Signed in, likes, new, renamed, reordered and deleted playlists, songs added or
  removed, subscriptions and albums you add to your library change your YouTube Music account. Changes show at once
  and undo themselves if YouTube refuses them. Turn off **Settings › Account › Sync likes and playlists** to keep
  them on this Mac; turning it back on offers to upload them. Brand accounts switch from Settings or the Account
  menu.
- **Playlist management.** New Playlist (⌘N), Rename, Edit and Delete in the sidebar, remove and drag to reorder
  in your own playlists, an Add to Playlist submenu that shows where a song already is, and Save Queue as Playlist.
- **Playback that keeps going.** The app recovers from a crashed player page, network drops, radio that fails to
  load, sleep and wake, and a song that won't start, usually without you noticing. Play/Pause follows what you asked
  for, even while a song is still loading.
- **Playback speed.** 0.5× to 2× with the pitch kept (Controls › Playback Speed, ⌥⌘. and ⌥⌘,). Ads still play
  at 1×.
- **Uploads.** Music you uploaded to YouTube Music has its own page: songs, albums and artists.
- **Sign-in you can check.** The sign-in window shows the page's address with a lock, says what the app keeps,
  and no longer dead-ends on passkeys. Signing out also signs out at Google. Accounts that can't sign in here
  (passkey-only, Advanced Protection) can use Import Session from Firefox or a cookies.txt file.
- **Wrong lyrics, fixed in one click.** Controls › Lyrics Source lists every version in plain words, Report Wrong
  Lyrics is remembered (with Undo), No Lyrics for This Song hides them for that song, and each version keeps its
  own timing. Sources that serve the same text for every song are caught. NetEase's songwriter credits no longer
  show up as raw text.
- **ListenBrainz** alongside Last.fm, from Settings › Integrations. Scrobbles count music time, so 2× still
  scrobbles. Discord never shows your uploads' links.
- **Global shortcuts.** Settings › Shortcuts sets system-wide keys for play, skip, like and the players, with no
  Accessibility permission and warnings when a key is taken.
- **Help › Report a Problem.** Opens a pre-filled GitHub issue with diagnostics you can read first; personal data
  is removed.
- **About** now says who made the app, with links to r-q.name, the website and the source.

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
