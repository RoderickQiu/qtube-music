# QTube Music — prototype

Clickable hi-fi prototype of the redesign in `docs/redesign-draft.md`.

```sh
python3 design/prototype/tools/fetch_assets.py   # covers, MV stills, lyrics → assets/ + data.js (both git-ignored)
cd design/prototype && python3 -m http.server 8765
open "http://127.0.0.1:8765/QTube%20Music.html"
```

Deep-link any state with URL params, e.g. `?surface=stage&stageBackground=vinyl&stageLayout=art-only`,
`?section=liked`, `?theme=light`, `?account=free`. Audio is simulated.
