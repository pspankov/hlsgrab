# hlsgrab

Find and download the HLS stream behind a web page.

hlsgrab opens each page in a real Chrome, watches its network traffic for the stream playlist (`.m3u8`, or one
disguised as `master.txt` and similar), captures the Referer and User-Agent it was requested with, and
downloads it with **yt-dlp** or **ffmpeg**. Use it as a self-hosted **web UI** (Docker) or as a **command-line
tool**. Both run the same script.

## Features

- **Finds the stream automatically**, including inside cross-origin player iframes and workers, and playlists
  served without an `.m3u8` extension (detected by content: `#EXTM3U`). Prefers the master playlist.
- **Replays the request correctly**: the Referer, Origin and User-Agent actually sent on the wire.
- **Picks the downloader**: yt-dlp for `.m3u8`, ffmpeg for disguised playlists whose segments are named
  `.js` / `.css` / `.woff`.
- **Segment host check**: probes one real segment per host first; dead hosts are rerouted to a live mirror
  that is verified to serve the same segment.
- **Batch + resume**: a list of page URLs, one at a time, resumable from any position.
- Blocks the `disable-devtool` anti-DevTools script; tries to start the player if it waits for a click.
- Files are named after the last part of the page URL: `https://site.com/show/episode-1/` → `episode-1.mp4`.

## Web UI (Docker)

```bash
git clone <this repo> hlsgrab && cd hlsgrab
mkdir -p downloads data          # create them yourself so they're owned by you, not root
docker compose up -d --build     # → http://localhost:8090
```

Require a login (recommended if the port is reachable from other machines):

```bash
HLSGRAB_AUTH='me:a-long-password' docker compose up -d
```

In the UI:

- **New download**: one URL or many (one per line, `#` comments skipped), or load a `.txt` list.
- **Find stream only**: shows the stream, referer and playlist type, with a button to download that stream.
- **Advanced options**: direct stream mode (playlist URL + referer + name, no browser), downloader
  (auto / yt-dlp / ffmpeg), search timeout, segment host check on/off.
- **Jobs**: live progress, the stream and tool used, host-check result, full log, cancel / retry / pause.
  The queue survives restarts; `docker stop` puts a running job back in the queue.
- **Downloaded files**: play in the browser, save, delete.

| Variable | Default | |
|---|---|---|
| `DOWNLOADS_DIR` | `/downloads` | where files are saved (mounted from `./downloads`) |
| `DATA_DIR` | `/data` | job list `jobs.json` (mounted from `./data`) |
| `CONCURRENCY` | `1` | downloads at a time |
| `AUTH` | empty | `user:password` enables a login (compose reads it from `HLSGRAB_AUTH`) |
| `PORT` | `8090` | port inside the container |

Chrome runs **headful** on a virtual display (Xvfb) inside the container, because many sites block headless
Chrome.

## Command line

Requirements: bash, Node ≥ 22, Google Chrome (or set `$CHROME`), jq, curl, python3, yt-dlp, ffmpeg ≥ 7.1.

```bash
ln -s "$PWD/batch_m3u8.sh" ~/.local/bin/hlsgrab

hlsgrab urls.txt                                   # each page in the list, one by one
hlsgrab urls.txt --from=17 --out=~/Videos          # resume at the 17th URL (or --from=<url>)
hlsgrab "https://site.com/show/episode-1/"         # a single page
hlsgrab --direct "<playlist-url>" "<referer>" "<name>"   # skip the browser
hlsgrab --probe "https://site.com/page/" --headful --requests   # just show what it finds (+ every request)
```

Options: `--out=<dir>`, `--downloader=auto|yt-dlp|ffmpeg`, `--no-host-check`, `--timeout=<s>`,
`--block=<glob>`, `--verbose`, `--requests`. Ctrl+C prints the exact command to resume. Failed URLs are written
to `<list>.failed`. Run `head -40 batch_m3u8.sh` for the full reference.

## Limits

- **No DRM.** Widevine / PlayReady / FairPlay protected streams can't be downloaded, and that won't change.
- DASH (`.mpd`) and plain video files aren't detected yet. Neither are playlists that are built in JavaScript and
  never requested over the network.
- Linux amd64 only for the Docker image (Google Chrome has no arm64 Linux build).
- Chrome runs with `--no-sandbox` inside the container, so only open pages you'd open in your own browser.
- yt-dlp is pinned (`YTDLP_VERSION` build arg); rebuild with a newer one when sites change:
  `docker compose build --build-arg YTDLP_VERSION=<version>`.

## Legal

Only download content you have the right to download. Respect the terms of the sites you use this with.
