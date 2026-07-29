#!/usr/bin/env bash
# Archive layer for watch-cli.
#
# Every successful watch is written to a record on disk so the expensive
# part — the ASR call — is paid once per source instead of once per run.
# `bin/dl-video` already caches the download and `bin/transcribe` already
# caches the extracted mp3; the transcript was the one thing still being
# re-bought every time.
#
# Layout ($WATCH_ARCHIVE_DIR, default ~/.watch-cli/archive — same home the
# local ASR models live under):
#
#   index.jsonl            one JSON object per record, newest appended last
#   <id>/meta.json         source, title, duration, frames, segments
#   <id>/transcript.txt    flat text
#   <id>/transcript.srt    timestamped, opens in any video player
#   <id>/frames/*.jpg      bin/extract-frames cuts here directly, so the
#                          frames outlive /tmp and a cache hit reports the
#                          same paths the cold run did
#
# Plain files in open formats. No database, no index server, nothing that
# needs watch-cli to read it back: grep and jq are enough, and so is any
# language with a JSON parser. The archive outlives the tool that wrote it.
#
# <id> is sha1(source)[:12] — the same key bin/dl-video uses for its own
# cache, so the two stay aligned instead of drifting apart.

# Guard against double-sourcing.
[[ -n "${WATCH_ARCHIVE_LOADED:-}" ]] && return 0
export WATCH_ARCHIVE_LOADED=1

# WATCH_ARCHIVE_DIR is resolved through the normal env chain (process env →
# ./.env → ~/.config/watch-cli/env) by lib/env.sh, so a user overrides it the
# same way they set any other watch-cli setting.
export WATCH_ARCHIVE_DIR="${WATCH_ARCHIVE_DIR:-$HOME/.watch-cli/archive}"

watch_archive_id() {
  printf '%s' "$1" | shasum | cut -c1-12
}

watch_archive_dir_for() {
  echo "$WATCH_ARCHIVE_DIR/$(watch_archive_id "$1")"
}

# 0 if a usable record exists. "Usable" means the transcript is non-empty:
# a run that failed to transcribe must never be remembered as the answer,
# or one bad network minute poisons that source forever.
watch_archive_has() {
  local rec
  rec="$(watch_archive_dir_for "$1")"
  [[ -s "$rec/meta.json" ]] || return 1
  python3 -c "
import json, sys
try:
    m = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(1)
sys.exit(0 if (m.get('transcript') or {}).get('text') else 1)
" "$rec/meta.json" 2>/dev/null
}

# Print one field from a record. Used by bin/watch to rebuild its output
# block from cache without re-deriving anything.
#   watch_archive_field <source> <video_path|duration|transcript|frame_paths>
watch_archive_field() {
  local rec
  rec="$(watch_archive_dir_for "$1")"
  python3 - "$rec/meta.json" "$2" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
field = sys.argv[2]
if field == "video_path":
    print(m.get("video_path") or "")
elif field == "duration":
    print(int(m.get("duration") or 0))
elif field == "transcript":
    sys.stdout.write((m.get("transcript") or {}).get("text") or "")
    sys.stdout.write("\n")
elif field == "frame_paths":
    for f in m.get("frames") or []:
        print(f["path"])
PY
}

# Replace just the frames array on an existing record, keeping the
# transcript. Used when a cache hit is asked for a different frame count
# than the one that was stored: docs/output-schema.md promises the number of
# frame lines matches what the caller requested, so the frames get recut
# while the expensive transcript is still reused.
#   watch_archive_set_frames <source> <frames-json>
watch_archive_set_frames() {
  local rec
  rec="$(watch_archive_dir_for "$1")"
  [[ -s "$rec/meta.json" ]] || return 1
  python3 - "$rec/meta.json" "$2" <<'PY'
import json, os, sys

meta_path, frames_json = sys.argv[1], sys.argv[2]
try:
    meta = json.load(open(meta_path, encoding="utf-8"))
    frames = json.load(open(frames_json, encoding="utf-8"))
except Exception:
    sys.exit(1)
meta["frames"] = [f for f in frames if os.path.exists(f.get("path") or "")]
json.dump(meta, open(meta_path, "w", encoding="utf-8"),
          ensure_ascii=False, indent=2)
PY
}

# Write a record. Called after a successful run.
#   watch_archive_put <source> <video> <duration> <frames-json> <segments-json> [info-json]
#
# frames-json is the file bin/extract-frames leaves in its out-dir;
# segments-json is what `transcribe --segments-out` produced. Either may be
# missing — the record still gets written as long as there is transcript
# text, because frames alone are worth keeping.
watch_archive_put() {
  local source="$1" video="$2" duration="$3" frames_json="$4" segments_json="$5" info_json="${6:-}"
  local id rec
  id="$(watch_archive_id "$source")"
  rec="$WATCH_ARCHIVE_DIR/$id"
  mkdir -p "$rec/frames" || return 1

  python3 - "$rec" "$id" "$source" "$video" "$duration" \
           "$frames_json" "$segments_json" "$info_json" \
           "$WATCH_ARCHIVE_DIR/index.jsonl" <<'PY'
import json, os, sys, time

(rec, vid_id, source, video_path, duration,
 frames_json, segments_json, info_json, index_path) = sys.argv[1:10]


def load(path, default):
    if path and os.path.exists(path):
        try:
            return json.load(open(path, encoding="utf-8"))
        except Exception:
            return default
    return default


frames = load(frames_json, [])
tr = load(segments_json, {"text": "", "segments": []})
if not isinstance(tr, dict):
    tr = {"text": "", "segments": []}

# Frames were cut into this record's frames/ directory, so there is nothing
# to copy — just drop any entry whose file did not survive.
archived = [f for f in frames if os.path.exists(f.get("path") or "")]

title = uploader = None
info = load(info_json, None)
if isinstance(info, dict):
    title = info.get("title")
    uploader = info.get("uploader") or info.get("channel")
if not title:
    title = os.path.basename(source)

meta = {
    "id": vid_id,
    "source": source,
    "title": title,
    "uploader": uploader,
    "duration": int(float(duration or 0)),
    "video_path": video_path if os.path.exists(video_path) else None,
    "dir": rec,
    "watched_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "frames": archived,
    "transcript": tr,
}

with open(os.path.join(rec, "meta.json"), "w", encoding="utf-8") as fh:
    json.dump(meta, fh, ensure_ascii=False, indent=2)

with open(os.path.join(rec, "transcript.txt"), "w", encoding="utf-8") as fh:
    fh.write((tr.get("text") or "").strip() + "\n")


def srt_time(sec):
    ms = int(round(float(sec) * 1000))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


segs = tr.get("segments") or []
srt_path = os.path.join(rec, "transcript.srt")
if segs:
    with open(srt_path, "w", encoding="utf-8") as fh:
        for i, s in enumerate(segs, 1):
            fh.write(f"{i}\n{srt_time(s['start'])} --> {srt_time(s['end'])}\n"
                     f"{s['text']}\n\n")
elif os.path.exists(srt_path):
    # A re-run that lost timing should not leave a stale .srt claiming it.
    os.remove(srt_path)

os.makedirs(os.path.dirname(index_path), exist_ok=True)
with open(index_path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps({
        "id": vid_id,
        "source": source,
        "title": title,
        "uploader": uploader,
        "duration": meta["duration"],
        "watched_at": meta["watched_at"],
        "dir": rec,
        "has_transcript": bool((tr.get("text") or "").strip()),
        "segments": len(segs),
    }, ensure_ascii=False) + "\n")
PY
}
