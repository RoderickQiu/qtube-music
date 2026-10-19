Fixtures for QTLyricsTests

Recorded 2026-10-18 from the live, anonymous, read-only endpoints (US IP) for the 7-song test set
(EN, ZH, 3×VI, JA, HI — see `songs/songs.json`), then **trimmed** before committing:

- Every lyric payload keeps only the lines that start inside one ~24 s window per song (`window` in
  `songs.json`), at most 8 lines per file, the same window for every provider — so each song contributes one
  short excerpt, never full lyrics. Search responses keep metadata only (ids, titles, artists, durations, aliases).
- Huge InnerTube responses are reduced to the paths the parser reads (`next` → lyrics tab `browseId`,
  `browse` → `timedLyricsModel` / `musicMessageModel`).
- Encrypted formats were decrypted, trimmed and **re-encrypted with independent reference implementations**
  (Python: Kugou XOR + zlib; QQ triple-DES variant + zlib). `kugou_plain.krc` and `qq_plain_*.txt` are the
  matching plaintexts, so `CodecTests` checks the Swift decrypters against an independent oracle.
- `amll_index_excerpt.jsonl`: a few lines of the AMLL TTML DB metadata index (CC0).

What the safe chain (YouTube Music + LRCLIB + AMLL, the default) returns for the hero track
"Đối Với Anh Em Không Còn Cảm Giác" / Kim Ny Ngọc: **nothing** — YouTube Music answers "Lyrics not available
at this time." (ATV `0sDXWfkljn4`), LRCLIB search is empty, and AMLL has no file for it (NetEase id 34516548 → 404).
With NetEase enabled it resolves to NetEase YRC (word-synced Vietnamese) + `ytlrc`/`tlyric` (Chinese translation).

Live re-check (not run by default): `QT_LIVE=1 swift test --scratch-path .build/<you> --filter LiveLyricsTests`.
