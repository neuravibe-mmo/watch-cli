# The archive

Every successful `watch` run is written to a record on disk. Watching the
same source again reads that record instead of paying for speech-to-text a
second time.

This is a cost and latency optimization layered *under* the output
contract, not a change to it. The block `watch` prints is byte-identical
whether it came from the network or from a record — see
[`output-schema.md`](output-schema.md), which is unchanged in this release.

---

## Why it exists

`bin/dl-video` already caches the downloaded mp4 by URL, and
`bin/transcribe` already caches the extracted 16kHz mp3 by input hash. The
transcript was the one expensive artifact still being re-bought on every
run: the same video watched three times meant three ASR calls.

Frames had the same problem in a smaller way. `bin/extract-frames` computes
the exact second it seeks to for each frame, and until this release it
deleted those numbers as soon as ffmpeg was done with them. The information
was free and thrown away, which is why a caller could describe a video but
never cite a moment in it.

---

## Where it lives

Default `~/.watch-cli/archive` — the same home directory the local ASR
models use. Override with `WATCH_ARCHIVE_DIR`, resolved through the normal
env chain (process env → `./.env` → `~/.config/watch-cli/env`), so it is
set like any other watch-cli setting.

```
~/.watch-cli/archive/
  index.jsonl                    one JSON object per record, newest last
  <id>/
    meta.json                    source, title, duration, frames, segments
    transcript.txt               flat text
    transcript.srt               timestamped; opens in any video player
    frames/frame_01.jpg …        the extracted frames
    frames/frames.json           [{"index","t","path"}, …]
```

`<id>` is `sha1(source)[:12]` — the same key `bin/dl-video` uses for its own
cache, so the two stay aligned rather than drifting apart.

Frames are cut directly into the record rather than into `/tmp` and copied.
That means they survive `/tmp` being cleared, and a cache hit reports the
same paths the cold run did.

The mp4 is deliberately *not* archived. It is the large, re-downloadable
part; a short video's record is a few hundred kilobytes. If `/tmp` has been
cleared and the mp4 is gone, a cache hit re-downloads it — the `VIDEO:` line
must name a file that exists — but still skips the ASR call.

---

## Reading it without watch-cli

The archive is plain JSON, SRT and JPG. Nothing in this repository is
required to read it back, and that is the point: the records should outlive
the tool that wrote them.

```bash
# every video whose transcript mentions a word
grep -l "kubernetes" ~/.watch-cli/archive/*/transcript.txt

# titles and segment counts
jq -r '"\(.title) — \(.segments) segments"' ~/.watch-cli/archive/index.jsonl

# every line spoken after the ten-minute mark, with its timestamp
jq -r '.transcript.segments[] | select(.start > 600) | "\(.start) \(.text)"' \
  ~/.watch-cli/archive/<id>/meta.json
```

`transcript.srt` drops straight into VLC, IINA, or a YouTube caption upload.

---

## The convenience CLI

`bin/watch-archive` wraps the common queries. It is a convenience, not a
gatekeeper — everything it does is doable with `grep` and `jq`.

```bash
watch-archive ls [limit]     # what's been watched, newest first
watch-archive find <query>   # search every transcript: id, timestamp, line
watch-archive get <id|url>   # reprint one record
watch-archive where          # print the archive root
```

`find` prints the timestamp of the matching segment, so the answer to "where
did they say that" is a seek position, not a whole video to re-watch.

It is a separate binary rather than a set of subcommands on `watch`, because
`watch`'s argument parsing already juggles `--pipe`, `--format` and a
positional frame count, and adding a subcommand layer on top of that would
make a positional URL ambiguous.

---

## What is never cached

A record is written only when the transcript came back non-empty. A run that
failed to transcribe — a timed-out backend, an exhausted quota, the silence
guard in `bin/transcribe` firing on a silent track — leaves no record.

This matters more than it looks. If failures were cached, one bad network
minute would poison that source permanently: every later run would return
the empty result instantly and confidently. Frames extracted during a failed
run do stay on disk, but without `meta.json` the record is not considered a
hit, so the next run makes a real attempt.

`--no-cache` forces a fresh download and transcription regardless of what is
stored, and overwrites the record on success.

---

## Timestamps and backends

`bin/transcribe --segments-out <path>` writes
`{"text": …, "segments": [{"start", "end", "text"}, …]}` alongside its normal
output. `bin/watch` passes this flag and stores the result.

Backend support differs, and the flag never changes which backend runs —
`WATCH_AUDIO_MODE` is a contract, and degrading the output format is not the
same as changing the route:

| Mode | Timestamps | How |
|---|---|---|
| `kyma` | yes | `response_format=verbose_json` |
| `byok` | yes | `response_format=verbose_json` |
| `local` | build-dependent | `--output-json`, used only when the installed whisper.cpp advertises the flag |

A backend that cannot produce timing writes `segments: []`. The transcript is
still stored and still searchable; only the seek position is missing, and
`watch-archive find` reports `[--:--]` for those records rather than
inventing a number.

---

## Housekeeping

There is no `prune` command yet. Records are small — a few hundred kilobytes
for a short video, dominated by the JPGs — but an archive of long videos
will grow. To clear everything:

```bash
rm -rf ~/.watch-cli/archive
```

To drop one record, delete its `<id>/` directory. The stale `index.jsonl`
line is harmless: `watch-archive ls` reads the directory contents, and a
missing record simply stops being a cache hit.
