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
