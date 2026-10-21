# QTInnerTubeTests fixtures

Anonymous, read-only WEB_REMIX responses from `music.youtube.com/youtubei/v1`, recorded 2026-10-18 from a US IP
(client version 1.20261013.15.00). No cookies, no account, no lyrics text.

They are trimmed by `FixtureTrimmer` (Support/FixtureSupport.swift): tracking/logging/accessibility payloads and
menus are dropped (except the "song credits" entry that carries the Song⇄Video id), item lists are capped at six
(plus any trailing continuation item), long texts are cut at 200 characters, and `responseContext` keeps only
`logged_in` with the visitor id replaced by `QTFIXTUREVISITOR`.

| File | Request | Used for |
|---|---|---|
| `home-en`, `home-zh` | `browse FEmusic_home` (hl en / zh-CN) | shelves, quick picks, mood chips (Podcasts chip dropped) |
| `home-continuation-en` | home continuation page 1 | continuation parsing |
| `home-continuation-podcasts-en` | the home page holding "Podcasts to get you started" | music-only filter drops the shelf |
| `explore-en`, `new-releases-en`, `charts-en`, `moods-en` | `browse FEmusic_explore` / `_new_releases` / `_charts` / `_moods_and_genres` | Explore (episodes + podcast destination dropped), charts (podcast chart dropped) |
| `search-trumua-en` | `search "Trú Mưa"` | top result, typed rows, episodes/podcasts/profiles dropped |
| `search-trumua-{songs,videos,playlists}-en` | filtered searches (videos uses `EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D`) | filters |
| `search-trumua-songs-continuation-en` | next page of the songs filter | search paging |
| `search-qingtian-zh`, `search-qingtian-albums-zh` | `search "晴天 周杰伦"` (hl zh-CN) | Chinese labels never leak into artists |
| `album-qilixiang-zh` | `browse MPREb_ScDJHCiomAo` | album header/tracks, playlist id |
| `album-hkt-en` | `browse MPREb_JR856gupBGZ` | official-video rows → Song counterpart (credits menu) |
| `artist-hkt-en`, `artist-jay-zh` | `browse UCjF7hNeaqArVJmijVgz-bjg` / `UCL2MDNdwEtV6aYUgNjFQGZA` | songs, albums, singles, videos row, related |
| `playlist-jay-zh` | `browse VLRDCLAK5uy_l12ynH8dyLsBmE11ToAHLm9P04NS2i9ME` | playlist header + rows |
| `playlist-classic-rock-en` (+ `-continuation-en`) | `browse VLPL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX` (248 tracks) | continuation paging |
| `next-trumua-en` | `next AeXLsAPORb4` | lyrics (`MPLY…`) / related (`MPTR…`) tabs, automix |
| `next-radio-trumua-en` (+ `-continuation-en`) | `next` with `RDAMVMAeXLsAPORb4` | radio queue + paging |
| `next-loiyeudo-{song,video}-en` | `next wmw4rkwsA90` / `QtP9V_G24QM` (same song, audio + official video) | counterpart wrapper test |
| `queue-loiyeudo-en` | `music/get_queue` | queue rows |
| `player-loiyeudo-en` | `player wmw4rkwsA90` | playability + metadata |

Re-record (review the diff; live content changes, so some test expectations may need updating):

```sh
QT_LIVE=1 QT_RECORD=1 swift test --scratch-path .build/<you> --filter QTInnerTubeTests.LiveTests/recordFixtures
```

## Hand-built signed-in fixtures

`handbuilt-*.json` were written by hand (2026-10-20), never recorded: no account was used and every id, name and URL
is made up. Their shapes follow ytmusicapi (`mixins/playlists.py`, `parsers/playlists.py`, `parsers/albums.py`) and
Kaset (`PlaylistParser`, `AccountsListParser` and their tests). Replace them with recorded ones only after an
owner-approved signed-in recording run.

| File | Shape of | Used for |
|---|---|---|
| `handbuilt-playlist-owned` | `browse VL…` of a playlist the account owns (`musicEditablePlaylistDetailHeaderRenderer`) | `isEditable`, privacy, description, `setVideoId`, `likeStatus` |
| `handbuilt-playlist-saved` | someone else's playlist with the save toggle on | `isSaved` |
| `handbuilt-edit-playlist-add` | `browse/edit_playlist` add answer | new `setVideoId`s |
| `handbuilt-add-to-playlist` | `playlist/get_add_to_playlist` | Add to Playlist options + checkmarks |
| `handbuilt-accounts-list` | `account/accounts_list` (with one spoofed switch link) | brand accounts |

The uploads ones (2026-10-20) follow ytmusicapi `mixins/uploads.py` / `parsers/uploads.py` and Metrolist's
`YouTube.kt` / `LibraryPage.kt` (upload album pages keep the older `musicDetailHeaderRenderer`); titles and names are
invented, ids are fake.

| File | Shape of | Used for |
|---|---|---|
| `handbuilt-uploads-songs` | `browse FEmusic_library_privately_owned_tracks` (sort dropdown, "Shuffle all" row with a video id but no menu, a row playable only through its menu's `queueAddEndpoint`, a row with an unlinked artist and no album / artwork, a continuation) | shuffle row dropped, menu `videoId`, `isPrivatelyOwned`, upload links without a page type |
| `handbuilt-uploads-songs-continuation` | `musicShelfContinuation` page of the above (also answers the artist page's continuation) | paging keeps the mark |
| `handbuilt-uploads-albums` | `browse …_privately_owned_releases` (grid in an `itemSectionRenderer`) | upload album cards |
| `handbuilt-uploads-artists` | `browse …_privately_owned_artists` (rows without a menu) | upload artist rows |
| `handbuilt-uploads-album` | `browse …_release_detail…` (`musicDetailHeaderRenderer`, rows without artist or artwork) | album page by prefix, header Play → playlist id |
| `handbuilt-uploads-artist` | `browse …_artist_detail…` (`musicHeaderRenderer`, shuffle row, continuation) | artist page by prefix, every page read |
| `handbuilt-uploads-empty` | an account without uploads (`messageRenderer` only) | empty list |
