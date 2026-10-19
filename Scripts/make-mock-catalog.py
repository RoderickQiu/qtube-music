#!/usr/bin/env python3
"""Build the M1 mock catalog from the prototype's real-track data.

Input  (git-ignored, main checkout only): design/prototype/data.js + design/prototype/assets/{covers,mv}/
       (create them with design/prototype/tools/fetch_assets.py).
Output (git-ignored): Generated/MockCatalog/catalog.json + covers/ + mv/ in the MAIN checkout by default,
       so every worktree and Scripts/build-app.sh share one copy.

The JSON is the on-disk format decoded by QTCore's `QTMockCatalog.load(from:)`: tracks once, everything else by id,
image paths relative to the catalog folder. It holds copyrighted covers/lyrics: never commit it.

Usage: Scripts/make-mock-catalog.py [--source <prototype dir>] [--out <folder>]
"""
import argparse
import json
import random
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Mirrors design/prototype/player.jsx and window.jsx.
NO_MV = {"ne3372368359", "ne3392546056"}  # Hi-Res audio uploads, not music videos
UNAVAILABLE = {"ne570019977": "regionLocked"}  # greyed row, like a region-locked track
USER_PLAYLISTS = ["Sugar", "你喜欢的歌曲重新上架", "2025 Sel 1", "rodrii的2024年度歌单", "2024 Sel 1",
                  "@rodrii的十年精选辑", "rodrii的2022年度歌单"]
MOODS = ["Relax", "Energize", "Focus", "Commute", "Romance", "Sleep", "Feel good"]
SOURCES = {
    "netease": {"id": "netease", "name": "NetEase", "isUnofficial": True},
    "lrclib": {"id": "lrclib", "name": "LRCLIB", "isUnofficial": False},
    "youtube": {"id": "youtubeMusic", "name": "YouTube Music", "isUnofficial": False},
}


def main_checkout() -> Path:
    here = Path(__file__).resolve().parent
    try:
        out = subprocess.run(["git", "-C", str(here), "worktree", "list", "--porcelain"],
                             capture_output=True, text=True, check=True).stdout
        return Path(out.splitlines()[0].split(" ", 1)[1])
    except Exception:
        return here.parent


def load_data_js(path: Path) -> dict:
    s = path.read_text(encoding="utf-8")
    start = s.index("{")
    end = s.rstrip().rstrip(";").rindex("}") + 1
    return json.loads(s[start:end])


def image_entry(rel: str, root: Path) -> dict:
    entry = {"url": rel}
    try:
        from PIL import Image  # optional
        with Image.open(root / rel) as im:
            entry["width"], entry["height"] = im.size
    except Exception:
        pass
    return entry


def detect_language(lines) -> str:
    s = " ".join(l["text"] for l in lines[:12])
    if re.search(r"[぀-ヿ]", s):
        return "ja"
    if re.search(r"[가-힯]", s):
        return "ko"
    if re.search(r"[一-鿿]", s):
        return "zh-Hans"
    if re.search(r"[ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ]", s, re.I):
        return "vi"
    return "en"


def convert_lyrics(L: dict) -> dict:
    provider = L.get("source", "")
    key = "netease" if provider.lower().startswith("netease") else "lrclib" if "lrclib" in provider.lower() else "youtube"
    lines = []
    for ln in L["lines"]:
        out = {"start": ln["t"], "text": ln["text"]}
        if ln.get("d") is not None:
            out["duration"] = ln["d"]
        if ln.get("words"):
            out["words"] = [{"start": w["t"], "duration": w["d"], "text": w["w"]} for w in ln["words"]]
        if ln.get("tr"):
            out["translation"] = ln["tr"]
        lines.append(out)
    has_tr = any(l.get("translation") for l in lines)
    doc = {
        "lines": lines,
        "syncKind": "word" if L.get("wordSynced") else "line",
        "source": SOURCES[key],
        "language": detect_language(L["lines"]),
        "confidence": 1.0,
        "offset": 0.0,
    }
    if has_tr:
        doc["translationLanguage"] = "zh-Hans"
        doc["translationSource"] = SOURCES[key]
    return doc


def main() -> int:
    root = main_checkout()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", type=Path, default=root / "design" / "prototype")
    ap.add_argument("--out", type=Path, default=root / "Generated" / "MockCatalog")
    args = ap.parse_args()

    data_js = args.source / "data.js"
    if not data_js.exists():
        print(f"error: {data_js} not found — run design/prototype/tools/fetch_assets.py first", file=sys.stderr)
        return 1
    data = load_data_js(data_js)

    out = args.out
    if out.exists():
        shutil.rmtree(out)
    (out / "covers").mkdir(parents=True)
    (out / "mv").mkdir(parents=True)

    tracks, lyrics = [], {}
    for t in data["tracks"]:
        tid = t["id"]
        cover_rel = f"covers/{tid}.jpg"
        shutil.copy2(args.source / t["cover"], out / cover_rel)
        track = {
            "videoId": tid,
            "title": t["title"],
            "artists": [{"name": t["artist"]}],
            "album": {"title": t["album"]},
            "duration": t["duration"],
            "artwork": [image_entry(cover_rel, out)],
            "musicVideoType": "MUSIC_VIDEO_TYPE_ATV",
            "isExplicit": False,
            "availability": UNAVAILABLE.get(tid, "playable"),
            "palette": {"accent": t["colors"]["accent"], "deep": t["colors"]["deep"]},
        }
        if t.get("subtitle"):
            track["subtitle"] = t["subtitle"]
        mv = t.get("mv")
        if mv and tid not in NO_MV:
            still_rel = f"mv/{tid}.jpg"
            shutil.copy2(args.source / mv["still"], out / still_rel)
            track["counterpart"] = {"videoId": mv["videoId"], "musicVideoType": "MUSIC_VIDEO_TYPE_OMV",
                                    "artwork": [image_entry(still_rel, out)]}
        if t.get("lyrics"):
            lyrics[tid] = convert_lyrics(t["lyrics"])
            track["lyricsHint"] = lyrics[tid]["syncKind"]
        tracks.append(track)

    ids = [t["videoId"] for t in tracks]
    playable = [t["videoId"] for t in tracks if t["availability"] == "playable"]
    with_video = [t["videoId"] for t in tracks if t["availability"] == "playable" and "counterpart" in t]
    cover_of = {t["videoId"]: t["artwork"] for t in tracks}

    playlists = []
    for i, name in enumerate(USER_PLAYLISTS):
        rng = random.Random(name)  # deterministic per playlist
        picked = rng.sample(ids, rng.randint(5, 10))
        playlists.append({"id": f"pl-{i + 1}", "title": {"verbatim": name}, "kind": "user", "owner": "rodrii",
                          "artwork": cover_of[picked[0]], "trackIDs": picked})

    catalog = {
        "version": 1,
        "tracks": tracks,
        "lyrics": lyrics,
        "liked": {"id": "LM", "title": {"key": "Liked Songs"}, "kind": "liked", "trackIDs": ids},
        "playlists": playlists,
        "home": {
            "moods": [{"id": f"mood-{m.lower().replace(' ', '-')}", "title": {"key": m}} for m in MOODS],
            "shelves": [
                {"id": "listen-again", "title": {"key": "Listen again"}, "style": "cards",
                 "items": [{"track": i} for i in playable]},
                {"id": "quick-picks", "title": {"key": "Quick picks"}, "style": "quickPicks",
                 "items": [{"track": i} for i in playable[:9]]},
                {"id": "music-videos", "title": {"key": "Music videos"}, "style": "videos",
                 "items": [{"video": i} for i in with_video]},
                {"id": "your-playlists", "title": {"key": "Your playlists"}, "style": "cards",
                 "items": [{"playlist": "LM"}] + [{"playlist": p["id"]} for p in playlists]},
            ],
        },
    }
    (out / "catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{out}: {len(tracks)} tracks, {len(lyrics)} lyrics, {len(playlists)} playlists")
    return 0


if __name__ == "__main__":
    sys.exit(main())
