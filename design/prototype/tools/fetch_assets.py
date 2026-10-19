#!/usr/bin/env python3
"""Fetch real artwork, lyrics and music-video stills for the QTube Music prototype.

Writes covers/MV stills to ../assets/ (git-ignored) and the track catalog to ../data.js.
Sources: NetEase Cloud Music public endpoints (search, song detail, lyrics with word
timing + translation) and YouTube Music InnerTube search (official music video ids).
Run:  python3 design/prototype/tools/fetch_assets.py
"""
import json
import re
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124 Safari/537.36"

# (artist, title, netease id or None to search, wants lyrics, lyric-id override)
TRACKS = [
    ("Kim Ny Ngọc", "Đối Với Anh Em Không Còn Cảm Giác", 34516548, True),
    ("Hoàng Thùy Linh", "Hạ Phỏm", None, True),
    ("HKT", "Trú Mưa", None, False),
    ("Trương Quỳnh Anh", "Đơn Côi", None, False),
    ("Sơn Tùng M-TP", "Chúng Ta Của Hiện Tại", 1805346557, True),
    ("李健", "蓝色夜曲", None, False),
    ("李健", "丽江", None, False),
    ("李健", "从黄昏到午夜", None, False),
    ("周杰伦", "晴天", 186016, True),
    ("Ed Sheeran", "Perfect", 460043703, True),
    ("Trúc Nhân", "Ngồi Hát Đỡ Buồn", None, False),
    ("浅影阿", "游子吟", None, False),
]


def get(url, data=None, headers=None):
    h = {"User-Agent": UA, "Referer": "https://music.163.com/"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h)
    return urllib.request.urlopen(req, timeout=25).read()


def ne_json(path, **params):
    return json.loads(get("https://music.163.com" + path + "?" + urllib.parse.urlencode(params)))


def fold(s):
    import unicodedata
    s = unicodedata.normalize("NFKD", s.lower()).replace("đ", "d")
    return re.sub(r"[^\w]+", "", "".join(c for c in s if not unicodedata.combining(c)))


def ne_find(artist, title):
    res = ne_json("/api/cloudsearch/pc", s=f"{artist} {title}", type=1, limit=10)
    songs = res.get("result", {}).get("songs", []) or []
    fa, ft = fold(artist), fold(title)
    for s in songs:  # prefer exact artist + title-prefix match
        if any(fold(a["name"]) == fa for a in s["ar"]) and fold(s["name"]).startswith(ft[:6]):
            return s["id"]
    return songs[0]["id"] if songs else None


def ts(t):
    m = re.match(r"(\d+):(\d+(?:\.\d+)?)", t)
    return int(m.group(1)) * 60 + float(m.group(2))


def parse_lrc(text):
    out = []
    for line in (text or "").splitlines():
        stamps = re.findall(r"\[(\d+:\d+(?:\.\d+)?)\]", line)
        body = re.sub(r"\[[^\]]*\]", "", line).strip()
        for s in stamps:
            out.append((ts(s), body))
    return sorted(out)


def parse_yrc(text):
    """NetEase word-level format: [start,dur](wStart,wDur,0)word..."""
    lines = []
    for raw in (text or "").splitlines():
        m = re.match(r"\[(\d+),(\d+)\](.*)", raw)
        if not m:
            continue
        start, dur, rest = int(m.group(1)), int(m.group(2)), m.group(3)
        words = [
            {"t": int(a) / 1000, "d": int(b) / 1000, "w": w}
            for a, b, w in re.findall(r"\((\d+),(\d+),\d+\)([^(]*)", rest)
        ]
        lines.append({"t": start / 1000, "d": dur / 1000, "text": "".join(w["w"] for w in words), "words": words})
    return lines


def build_lyrics(lid):
    l = ne_json("/api/song/lyric/v1", id=lid, lv=-1, tv=-1, rv=-1, yv=-1, ytv=-1)
    yrc = parse_yrc((l.get("yrc") or {}).get("lyric"))
    lrc = parse_lrc((l.get("lrc") or {}).get("lyric"))
    trans = sorted(set(parse_lrc((l.get("tlyric") or {}).get("lyric")))
                   | set(parse_lrc((l.get("ytlrc") or {}).get("lyric"))))
    lines = yrc or [{"t": t, "text": x, "words": None} for t, x in lrc]
    lines = [ln for ln in lines if ln["text"] and not re.match(r"^(作词|作曲|编曲|制作人|词|曲)\s*[:：]", ln["text"])]
    used = set()
    for i, ln in enumerate(lines):  # end time = next start
        ln.setdefault("d", (lines[i + 1]["t"] - ln["t"]) if i + 1 < len(lines) else 4.0)
        cands = [(abs(tt - ln["t"]), k) for k, (tt, x) in enumerate(trans)
                 if x and not x.startswith("//") and k not in used and abs(tt - ln["t"]) < 1.5]
        if cands:
            k = min(cands)[1]
            used.add(k)
            ln["tr"] = trans[k][1]
    return {"source": "NetEase (yrc)" if yrc else "NetEase (lrc)", "wordSynced": bool(yrc), "lines": lines}


def ytm_video_id(artist, title):
    body = {
        "query": f"{artist} {title}",
        "params": "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D",  # filter: videos
        "context": {"client": {"clientName": "WEB_REMIX", "clientVersion": "1.20251001.01.00", "hl": "en", "gl": "US"}},
    }
    raw = get(
        "https://music.youtube.com/youtubei/v1/search?prettyPrint=false",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Origin": "https://music.youtube.com", "Referer": "https://music.youtube.com/"},
    )
    ids = re.findall(r'"videoId":"([\w-]{11})"', raw.decode())
    return ids[0] if ids else None


def palette(path):
    """Accent (most vivid common colour) + deep base colour, for art-tinted UI."""
    import colorsys
    from PIL import Image
    im = Image.open(path).convert("RGB").resize((64, 64))
    q = im.quantize(colors=12, method=Image.Quantize.MEDIANCUT)
    pal = q.getpalette()[:36]
    counts = sorted(q.getcolors(), reverse=True)
    cols = []
    for n, idx in counts:
        r, g, b = pal[idx * 3: idx * 3 + 3]
        h, l, sat = colorsys.rgb_to_hls(r / 255, g / 255, b / 255)
        cols.append({"rgb": (r, g, b), "n": n, "l": l, "s": sat})
    mids = [c for c in cols if 0.22 < c["l"] < 0.8] or cols
    vivid = max(mids, key=lambda c: (c["s"] + 0.05) * (c["n"] ** 0.5) * (1 - abs(c["l"] - 0.55)))
    deep = min(cols, key=lambda c: c["l"] - c["n"] / 8192)
    hexs = lambda c: "#%02x%02x%02x" % c["rgb"]
    return {"accent": hexs(vivid), "deep": hexs(deep)}


def download(url, path):
    if path.exists():
        return True
    try:
        path.write_bytes(get(url))
        return True
    except Exception as e:  # noqa: BLE001
        print("   ! download failed", url, e)
        return False


def main():
    (ASSETS / "covers").mkdir(parents=True, exist_ok=True)
    (ASSETS / "mv").mkdir(parents=True, exist_ok=True)
    catalog = []
    for artist, title, nid, want_lyrics in TRACKS:
        sid = nid or ne_find(artist, title)
        detail = ne_json("/api/v3/song/detail", c=json.dumps([{"id": sid}]))["songs"][0]
        slug = f"ne{sid}"
        cover = ASSETS / "covers" / f"{slug}.jpg"
        download(detail["al"]["picUrl"] + "?param=800y800", cover)
        track = {
            "id": slug,
            "title": title,
            "artist": artist,
            "album": detail["al"]["name"],
            "duration": round(detail["dt"] / 1000),
            "cover": f"assets/covers/{slug}.jpg",
            "subtitle": (detail.get("tns") or detail.get("alia") or [None])[0],
            "colors": palette(cover),
        }
        try:
            vid = ytm_video_id(artist, title)
            still = ASSETS / "mv" / f"{slug}.jpg"
            if vid and (download(f"https://i.ytimg.com/vi/{vid}/maxresdefault.jpg", still)
                        or download(f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg", still)):
                track["mv"] = {"videoId": vid, "still": f"assets/mv/{slug}.jpg"}
        except Exception as e:  # noqa: BLE001
            print("   ! ytm search failed", e)
        if want_lyrics:
            track["lyrics"] = build_lyrics(sid)
        catalog.append(track)
        lyr = track.get("lyrics")
        print(f"{title} — {artist}: ne={sid} album={track['album']} {track['duration']}s mv={track.get('mv', {}).get('videoId')}"
              + (f" lyrics={len(lyr['lines'])} lines word={lyr['wordSynced']} tr={sum('tr' in l for l in lyr['lines'])}" if lyr else ""))
        time.sleep(0.4)
    (ROOT / "data.js").write_text(
        "// Generated by tools/fetch_assets.py — real catalog data for the prototype.\n"
        "window.QT_DATA = " + json.dumps({"tracks": catalog}, ensure_ascii=False, indent=1) + ";\n",
        encoding="utf-8",
    )
    print("wrote", ROOT / "data.js")


if __name__ == "__main__":
    main()
