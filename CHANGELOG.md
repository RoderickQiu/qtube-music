# Changelog

All notable changes to QTube Music. Versions follow [Semantic Versioning](https://semver.org); `Scripts/release.sh`
uses the section for a version as its release notes.

## 0.4.3

Suggestions for your playlists, and desktop lyrics that stay where you put them.

- **Suggestions under your playlists.** A playlist of your own now ends with the songs YouTube Music suggests for
  it, picked from what it already holds. The button on a row adds that song to the playlist; Refresh shows other
  songs. Signed in only (#6).
- **Desktop lyrics stay where you drag them.** A lyric dragged towards a screen edge jumped back towards the middle
  when you locked it. It now stays put (#4).
- **Desktop lyrics can be left- or right-aligned.** Settings › Lyrics › Desktop Lyrics › Alignment. With Left, a
  lyric placed at the left edge of the screen grows to the right instead of running off the edge; Right mirrors it.
  The unlock controls sit over the lines, so Lock is always within reach.

## 0.4.2

Small windows, and links from the playing song.

- **Click the playing song's title or artist to go there.** In the player bar, the lyrics panel and Stage, the
  title and the album name open the album page and each artist's name opens that artist's page.
- **Small windows no longer spill over their edges.** With the panel open in a small window, the sidebar and the
  panel were pushed out past the window's sides, and opening the panel shifted the sidebar. The player bar now
  steps down instead: the volume slider, then Mini Player and Stage, step aside (#1, #2).
- **Song lists cope with narrow columns.** A narrow list drops the Album column, then the like column, so Time
  stays in view; Play and Shuffle become icon buttons.
- **The last song in a list is reachable.** Lists now scroll their last row clear of the player bar.
- **Stage: more room for lyrics in a small window.** The cover shrinks before lyric lines start wrapping, and the
  close button no longer sits on the window's zoom button (#3).

## 0.4.1

Signed and notarized.

- **Opens like any other app.** QTube Music is now signed with an Apple Developer ID and notarized by Apple, so the
  first launch no longer needs System Settings › Privacy & Security › Open Anyway. Updating from 0.4.0 is enough.

## 0.4.0

Updates by themselves, radio from anything, a sleep timer, and artists you never want to hear.

- **Automatic updates.** QTube Music now checks for new versions once a day and shows what's new, with Install
  Update right there. QTube Music › Check for Updates… checks at once. Settings › General › Updates has the current
  version, when it last checked, and an option to download and install updates in the background (they're applied
  when you quit). Every update is verified against the project's signing key before it's installed. This is the
  last version you need to download by hand.
- **No password prompts after updates.** Your sign-in and your Last.fm and ListenBrainz keys now live in a private
  file on this Mac instead of the Keychain, which asked for your Mac password after every new version. Only your user
  account can open the file, and Time Machine skips it; other programs you run could read it, as with Firefox's
  cookies. Coming from 0.3.0, macOS asks one last time so your sign-in can move over.
- **Sleep timer.** Controls › Sleep Timer (also in the Dock menu) stops the music after 15, 30, 45, 60 or 90 minutes,
  or at the end of the song. The last 30 seconds fade out, then playback pauses and the Mac can sleep again. A small
  countdown sits in the player bar, the Stage and the menu bar popover while it runs; the next Play starts at your
  usual volume.
- **Don’t Play This Artist.** Right-click a song or an artist, or use Controls for the song that’s playing, to keep
  that artist out. Autoplay, radio, mixes and shuffle skip them, and Home, Explore and search leave them out. Songs
  you pick yourself still play, and so do albums and playlists you play in order, where their songs show dimmed. The
  list stays on this Mac; edit it in **Settings › Playback › Blocked artists**.
- **Start Radio.** An endless station of similar music from any song, album, artist or playlist: right-click it, or
  use Controls › Start Radio (also in the Dock menu) for the song that's playing, which keeps playing. Up Next
  stays, and Autoplay keeps the station going. Works signed in and signed out.

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
