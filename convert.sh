#!/bin/bash

# A script to convert audio files to WAV format (16-bit/44.1kHz/stereo).
# Ensures universal compatibility with CDJs, car stereos, and consumer devices.
# It preserves the directory structure and metadata.

set -e
set -o pipefail

# --- Target format constants ---
TARGET_SAMPLE_RATE=44100
TARGET_BIT_DEPTH=16
TARGET_CODEC=pcm_s16le
TARGET_CHANNELS=2

# --- Loudness normalization constants ---
TARGET_LUFS=-11      # Integrated loudness target (LUFS)
TARGET_TP=-1         # True peak limit (dBTP) — small headroom to prevent clipping

# --- Default values ---
SOURCE_DIR=""
DEST_DIR=""
LOG_FILE=""
FORCE_MODE=false
PARALLEL_JOBS=1    # 1 = sequential (default); >1 = parallel workers (GUI only)
ANALYZE_BPM=false
ANALYZE_KEY=false
KEY_FORMAT="standard"       # standard | camelot | openkey
VERIFY_INTEGRITY=false
CLEAN_METADATA=false
PROGRESS_FIFO=""     # Path to progress-window FIFO (empty = no GUI progress window)
PROGRESS_PID=""      # PID of background Python progress window
PROGRESS_SCRIPT=""   # Path to temp Python script for progress window

# --- Help message ---
usage() {
  echo "Usage: $0 -s <source_dir> -d <dest_dir> [-l <log_file>] [--force]"
  echo ""
  echo "Options:"
  echo "  -s, --source      The source directory containing audio files."
  echo "  -d, --destination The destination directory for WAV files."
  echo "  -l, --log-file    The path to a log file. If not provided, a log file is created in the destination directory."
  echo "  -f, --force       Re-convert all files even if output exists and is valid."
  echo "  -h, --help        Display this help message."
  echo ""
}

# --- Argument parsing ---
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -s|--source)
      SOURCE_DIR="$2"
      shift
      ;;
    -d|--destination)
      DEST_DIR="$2"
      shift
      ;;
    -l|--log-file)
      LOG_FILE="$2"
      shift
      ;;
    -f|--force)
      FORCE_MODE=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown parameter passed: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

# --- ANSI Color Codes ---
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_NC='\033[0m' # No Color

# --- Helper: extract leading number from a label string ---
extract_number() { echo "$1" | grep -oP '^-?[0-9]+(\.[0-9]+)?'; }

# --- Tkinter GUI (launched when no CLI args are provided) ---
launch_gui() {
  # Resolve script directory for default folders
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local default_input="$script_dir/input"
  local default_output="$script_dir/output"

  # Detect CPU core count for parallel options
  local max_cores
  max_cores=$(nproc 2>/dev/null || echo 4)

  # Ensure default folders exist
  mkdir -p "$default_input" "$default_output"

  # Auto-install customtkinter for modern GUI (silent, no-op if already present)
  python3 -c "import customtkinter" 2>/dev/null || python3 -m pip install customtkinter -q 2>/dev/null

  # Launch single-window Tkinter GUI via embedded Python
  local gui_output
  gui_output=$(python3 - "$default_input" "$default_output" "$max_cores" << 'PYTHON_GUI'
import sys
import os
import re
import tkinter as tk
from tkinter import filedialog
import customtkinter as ctk

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("blue")

default_input = sys.argv[1]
default_output = sys.argv[2]
max_cores = int(sys.argv[3])

cancelled = True  # Assume cancel unless Start is clicked

app = ctk.CTk()
app.title("\u266b Music Converter")

# Auto-scale UI to screen resolution (normalize to 1080p baseline)
screen_h = app.winfo_screenheight()
ui_scale = max(1.0, screen_h / 1080)
ctk.set_widget_scaling(ui_scale)

# Set window size scaled to resolution, allow vertical resize
base_w, base_h = 580, 840
win_w = int(base_w * ui_scale)
win_h = int(base_h * ui_scale)
app.geometry(f"{win_w}x{win_h}")
app.minsize(win_w, win_h)
app.resizable(False, True)

# --- Tooltip helper ---
class ToolTip:
    def __init__(self, widget, text):
        self.widget = widget
        self.text = text
        self.tw = None
        widget.bind("<Enter>", self._show)
        widget.bind("<Leave>", self._hide)

    def _show(self, e=None):
        if self.tw:
            return
        x = self.widget.winfo_rootx() + 20
        y = self.widget.winfo_rooty() + self.widget.winfo_height() + 4
        self.tw = tk.Toplevel(self.widget)
        self.tw.wm_overrideredirect(True)
        self.tw.wm_geometry(f"+{x}+{y}")
        self.tw.configure(bg="#333333")
        tk.Label(self.tw, text=self.text, bg="#333333", fg="#e0e0e0",
                 padx=10, pady=6, font=("sans-serif", 10),
                 wraplength=320, justify="left").pack()

    def _hide(self, e=None):
        if self.tw:
            self.tw.destroy()
            self.tw = None

# --- Header ---
hdr = ctk.CTkFrame(app, fg_color="transparent")
hdr.pack(fill="x", padx=24, pady=(20, 0))

ctk.CTkLabel(hdr, text="\u266b Music Converter",
             font=ctk.CTkFont(size=22, weight="bold")).pack(anchor="w")
ctk.CTkLabel(hdr,
    text="Batch-convert audio files to WAV with loudness normalization.\n"
         "Supported formats: FLAC \u00b7 WAV \u00b7 MP3 \u00b7 AIF/AIFF \u00b7 M4A",
    font=ctk.CTkFont(size=12), text_color="gray55").pack(anchor="w", pady=(4, 0))

# --- Folders section ---
fold_sec = ctk.CTkFrame(app, corner_radius=10)
fold_sec.pack(fill="x", padx=20, pady=(16, 4))

ctk.CTkLabel(fold_sec, text="Folders",
             font=ctk.CTkFont(size=13, weight="bold")).pack(anchor="w", padx=14, pady=(12, 4))

fold_grid = ctk.CTkFrame(fold_sec, fg_color="transparent")
fold_grid.pack(fill="x", padx=14, pady=(0, 12))

ctk.CTkLabel(fold_grid, text="Source:", anchor="w", width=90).grid(
    row=0, column=0, sticky="w")
source_var = tk.StringVar(value=default_input)
src_entry = ctk.CTkEntry(fold_grid, textvariable=source_var, width=340)
src_entry.grid(row=0, column=1, padx=(0, 8), sticky="ew")
ctk.CTkButton(fold_grid, text="Browse", width=80,
    command=lambda: (lambda d: source_var.set(d) if d else None)(
        filedialog.askdirectory(title="Select Source Directory",
                                initialdir=source_var.get()))
    ).grid(row=0, column=2)
ToolTip(src_entry, "Folder containing your audio files to convert.")

ctk.CTkLabel(fold_grid, text="Destination:", anchor="w", width=90).grid(
    row=1, column=0, sticky="w", pady=(8, 0))
dest_var = tk.StringVar(value=default_output)
dst_entry = ctk.CTkEntry(fold_grid, textvariable=dest_var, width=340)
dst_entry.grid(row=1, column=1, padx=(0, 8), sticky="ew", pady=(8, 0))
ctk.CTkButton(fold_grid, text="Browse", width=80,
    command=lambda: (lambda d: dest_var.set(d) if d else None)(
        filedialog.askdirectory(title="Select Destination Directory",
                                initialdir=dest_var.get()))
    ).grid(row=1, column=2, pady=(8, 0))
ToolTip(dst_entry, "Folder where converted WAV files will be saved.\nDirectory structure is preserved.")

fold_grid.columnconfigure(1, weight=1)

# --- Audio Settings section ---
audio_sec = ctk.CTkFrame(app, corner_radius=10)
audio_sec.pack(fill="x", padx=20, pady=4)

ctk.CTkLabel(audio_sec, text="Audio Settings",
             font=ctk.CTkFont(size=13, weight="bold")).pack(anchor="w", padx=14, pady=(12, 4))

audio_grid = ctk.CTkFrame(audio_sec, fg_color="transparent")
audio_grid.pack(fill="x", padx=14, pady=(0, 12))

lufs_values = [
    "-11 LUFS \u2014 Club/DJ playback",
    "-14 LUFS \u2014 Streaming standard",
    "-9 LUFS \u2014 Hot, less dynamic range",
    "-16 LUFS \u2014 Broadcast (EBU R128)",
]
tp_values = [
    "-1 dBTP \u2014 Standard headroom",
    "-2 dBTP \u2014 Extra safe",
    "-0.5 dBTP \u2014 Aggressive",
]
sr_values = [
    "44100 Hz \u2014 CD quality",
    "48000 Hz \u2014 Video/broadcast",
]
bd_values = [
    "16-bit \u2014 Universal support",
    "24-bit \u2014 Higher quality",
]

def make_option(parent, label, values, row, tooltip):
    ctk.CTkLabel(parent, text=label, anchor="w", width=120).grid(
        row=row, column=0, sticky="w", pady=4)
    var = tk.StringVar(value=values[0])
    menu = ctk.CTkOptionMenu(parent, values=values, variable=var, width=300)
    menu.grid(row=row, column=1, sticky="ew", pady=4)
    ToolTip(menu, tooltip)
    return var

lufs_var = make_option(audio_grid, "Target Loudness:", lufs_values, 0,
    "Target integrated loudness level.\n-11 LUFS is ideal for DJ/club playback.")
tp_var = make_option(audio_grid, "True Peak Limit:", tp_values, 1,
    "Maximum true peak level to prevent\ndigital clipping on playback.")
sr_var = make_option(audio_grid, "Sample Rate:", sr_values, 2,
    "Output sample rate.\n44100 Hz is CD standard, universally compatible.")
bd_var = make_option(audio_grid, "Bit Depth:", bd_values, 3,
    "Output bit depth.\n16-bit works on all devices including older CDJs.")

audio_grid.columnconfigure(1, weight=1)

# --- Tag Analysis section ---
tag_sec = ctk.CTkFrame(app, corner_radius=10)
tag_sec.pack(fill="x", padx=20, pady=4)

ctk.CTkLabel(tag_sec, text="Tag Analysis",
             font=ctk.CTkFont(size=13, weight="bold")).pack(anchor="w", padx=14, pady=(12, 4))

tag_content = ctk.CTkFrame(tag_sec, fg_color="transparent")
tag_content.pack(fill="x", padx=14, pady=(0, 12))

bpm_var = tk.IntVar(value=0)
bpm_chk = ctk.CTkCheckBox(tag_content, text="Analyze & write BPM tag", variable=bpm_var)
bpm_chk.pack(anchor="w")
ToolTip(bpm_chk, "Detects BPM and writes TBPM tag to the output WAV.\nRequires: pip install aubio")

key_format_values = [
    "standard — Am, C, F#m  (Traktor default)",
    "camelot — 8A, 8B  (DJ notation)",
    "openkey — 6m, 6d",
]
key_format_var = tk.StringVar(value=key_format_values[0])

def toggle_key_format():
    key_format_menu.configure(state="normal" if key_var.get() == 1 else "disabled")

key_var = tk.IntVar(value=0)
key_chk = ctk.CTkCheckBox(tag_content, text="Analyze & write Key tag",
                           variable=key_var, command=toggle_key_format)
key_chk.pack(anchor="w", pady=(6, 0))
ToolTip(key_chk, "Detects musical key and writes TKEY tag to the output WAV.\nRequires: keyfinder-cli (falls back to aubio if not found)")

key_row = ctk.CTkFrame(tag_content, fg_color="transparent")
key_row.pack(fill="x", pady=(6, 0))
ctk.CTkLabel(key_row, text="Key format:", width=90).pack(side="left", padx=(24, 8))
key_format_menu = ctk.CTkOptionMenu(key_row, values=key_format_values,
                                    variable=key_format_var, width=280, state="disabled")
key_format_menu.pack(side="left")
ToolTip(key_format_menu, "Key notation format written to the TKEY tag.")

clean_var = tk.IntVar(value=0)
clean_chk = ctk.CTkCheckBox(tag_content, text="Clean metadata", variable=clean_var)
clean_chk.pack(anchor="w", pady=(6, 0))
ToolTip(clean_chk,
    "Triangulates Artist & Title from existing tags and filename.\n"
    "Renames the output file to \u201cArtist \u2013 Title.wav\u201d and writes\n"
    "Artist, Title, Album, and Track Number tags.")

# --- Processing section ---
proc_sec = ctk.CTkFrame(app, corner_radius=10)
proc_sec.pack(fill="x", padx=20, pady=4)

ctk.CTkLabel(proc_sec, text="Processing",
             font=ctk.CTkFont(size=13, weight="bold")).pack(anchor="w", padx=14, pady=(12, 4))

proc_content = ctk.CTkFrame(proc_sec, fg_color="transparent")
proc_content.pack(fill="x", padx=14, pady=(0, 12))

force_var = tk.IntVar(value=0)
force_chk = ctk.CTkCheckBox(proc_content, text="Force re-conversion", variable=force_var)
force_chk.pack(anchor="w")
ToolTip(force_chk, "Re-convert all files even if valid output\nalready exists in the destination folder.")

_cpu = os.cpu_count() or 4
_worker_presets = [
    ("4 workers", 4),
    ("8 workers", 8),
    (f"Half capacity  ({_cpu // 2})", max(_cpu // 2, 4)),
    (f"Full capacity  ({_cpu})", max(_cpu, 4)),
]
_worker_labels = [lbl for lbl, _ in _worker_presets]
_worker_map    = {lbl: cnt for lbl, cnt in _worker_presets}
workers_var    = tk.StringVar(value=_worker_labels[0])

def toggle_parallel():
    workers_row.pack(fill="x", pady=(4, 0)) if parallel_var.get() == 1 else workers_row.pack_forget()

parallel_var = tk.IntVar(value=0)
parallel_chk = ctk.CTkCheckBox(proc_content, text="Parallel processing",
                                variable=parallel_var, command=toggle_parallel)
parallel_chk.pack(anchor="w", pady=(6, 0))
ToolTip(parallel_chk, "Process multiple files simultaneously.\nFaster on multi-core machines.")

workers_row = ctk.CTkFrame(proc_content, fg_color="transparent")
# workers_row is shown/hidden by toggle_parallel; hidden by default
ctk.CTkLabel(workers_row, text="Workers:", width=90).pack(side="left", padx=(24, 8))
workers_menu = ctk.CTkOptionMenu(workers_row, values=_worker_labels,
                                  variable=workers_var, width=220)
workers_menu.pack(side="left")
ToolTip(workers_menu, "Total parallel workers. 1 is always\nreserved for the UI \u2014 the rest process files.")

integrity_var = tk.IntVar(value=0)
integrity_chk = ctk.CTkCheckBox(proc_content, text="Verify file integrity",
                                 variable=integrity_var)
integrity_chk.pack(anchor="w", pady=(6, 0))
ToolTip(integrity_chk, "Compare output waveform against source:\nchecks duration, RMS level, clipping, and corrupt samples.")

# --- Buttons ---
btn_frame = ctk.CTkFrame(app, fg_color="transparent")
btn_frame.pack(fill="x", padx=20, pady=(12, 18))

def extract_number(s):
    m = re.search(r"-?[0-9]+(?:\.[0-9]+)?", s)
    return m.group(0) if m else ""

def on_start():
    global cancelled
    cancelled = False

    lufs = extract_number(lufs_var.get())
    tp = extract_number(tp_var.get())
    sample_rate = extract_number(sr_var.get())
    bit_depth = extract_number(bd_var.get())
    codec = "pcm_s24le" if bit_depth == "24" else "pcm_s16le"
    force = "true" if force_var.get() == 1 else "false"

    if parallel_var.get() == 1:
        jobs = str(_worker_map[workers_var.get()])
    else:
        jobs = "1"

    print(f"SOURCE_DIR={source_var.get()}")
    print(f"DEST_DIR={dest_var.get()}")
    print(f"TARGET_LUFS={lufs}")
    print(f"TARGET_TP={tp}")
    print(f"TARGET_SAMPLE_RATE={sample_rate}")
    print(f"TARGET_BIT_DEPTH={bit_depth}")
    print(f"TARGET_CODEC={codec}")
    print(f"FORCE_MODE={force}")
    print(f"PARALLEL_JOBS={jobs}")
    print(f"ANALYZE_BPM={'true' if bpm_var.get() else 'false'}")
    print(f"ANALYZE_KEY={'true' if key_var.get() else 'false'}")
    print(f"KEY_FORMAT={key_format_var.get().split()[0].lower()}")
    print(f"VERIFY_INTEGRITY={'true' if integrity_var.get() else 'false'}")
    print(f"CLEAN_METADATA={'true' if clean_var.get() else 'false'}")
    app.destroy()

def on_cancel():
    app.destroy()

ctk.CTkButton(btn_frame, text="Cancel", width=100,
              fg_color="transparent", border_width=1,
              hover_color=("gray70", "gray30"),
              command=on_cancel).pack(side="right", padx=(8, 0))
ctk.CTkButton(btn_frame, text="Start Conversion", width=160,
              command=on_start).pack(side="right")

app.protocol("WM_DELETE_WINDOW", on_cancel)
app.mainloop()

sys.exit(0 if not cancelled else 1)
PYTHON_GUI
  ) || exit 0

  # Parse KEY=VALUE output from the Python GUI
  while IFS='=' read -r key value; do
    case "$key" in
      SOURCE_DIR)          SOURCE_DIR="$value" ;;
      DEST_DIR)            DEST_DIR="$value" ;;
      TARGET_LUFS)         TARGET_LUFS="$value" ;;
      TARGET_TP)           TARGET_TP="$value" ;;
      TARGET_SAMPLE_RATE)  TARGET_SAMPLE_RATE="$value" ;;
      TARGET_BIT_DEPTH)    TARGET_BIT_DEPTH="$value" ;;
      TARGET_CODEC)        TARGET_CODEC="$value" ;;
      FORCE_MODE)          FORCE_MODE="$value" ;;
      PARALLEL_JOBS)        PARALLEL_JOBS="$value" ;;
      ANALYZE_BPM)          ANALYZE_BPM="$value" ;;
      ANALYZE_KEY)          ANALYZE_KEY="$value" ;;
      KEY_FORMAT)           KEY_FORMAT="$value" ;;
      VERIFY_INTEGRITY)     VERIFY_INTEGRITY="$value" ;;
      CLEAN_METADATA)       CLEAN_METADATA="$value" ;;
      MAX_SILENCE_DURATION) ;; # deprecated, ignored
    esac
  done <<< "$gui_output"
}

# --- If no source/dest provided, launch GUI; otherwise validate ---
if [ -z "$SOURCE_DIR" ] && [ -z "$DEST_DIR" ]; then
  launch_gui
elif [ -z "$SOURCE_DIR" ] || [ -z "$DEST_DIR" ]; then
  echo "Error: Both source and destination directories are required."
  usage
  exit 1
fi

# --- Logging ---
log() {
  local message="$1"
  local log_level="$2"
  local color="$3"
  local console_output="$4"

  if [ -n "$LOG_FILE" ]; then
    (
      flock 200
      echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ${log_level} - ${message}"
    ) 200>>"$LOG_FILE"
  fi

  if [ "$log_level" = "ERROR" ] || [ "$console_output" = "force" ]; then
    echo -e "${color}${log_level}: ${message}${C_NC}" >&2
  fi
}

# --- Atomically flush per-file temp log into the main log ---
# Uses flock on a .lock sidecar file so _flush_log and log() don't interleave.
_flush_log() {
  local tmp_log="$1" main_log="$2"
  [ -n "$main_log" ] && [ -s "$tmp_log" ] && \
    ( flock 9; cat "$tmp_log" >> "$main_log" ) 9>"${main_log}.lock"
  rm -f "$tmp_log"
}

# --- Compute the clean destination filename from source tags + filename ---
# Prints "{Artist} - {Title}.wav" (or "{Title}.wav" if no artist found).
compute_clean_filename() {
  local src="$1"
  python3 - "$src" 2>/dev/null << 'PYCLEAN'
import sys, os, re
from pathlib import Path

src = sys.argv[1]

def ensure_mutagen():
    try:
        import mutagen
    except ImportError:
        import subprocess
        subprocess.run([sys.executable, "-m", "pip", "install", "mutagen", "-q"],
                       capture_output=True)

def read_tags(path):
    ensure_mutagen()
    try:
        from mutagen import File as MutagenFile
        audio = MutagenFile(path, easy=True)
        if not audio:
            return {}
        r = {}
        for k in ('title', 'artist', 'album', 'tracknumber'):
            v = audio.get(k)
            if v:
                r[k] = str(v[0]).strip()
        return r
    except Exception:
        return {}

def parse_fn(stem):
    name = stem
    r = {}
    m = re.match(r'^[(\[]?(\d{1,3})[)\]]?[\s.\-_]+', name)
    if m:
        r['track_num'] = int(m.group(1))
        name = name[m.end():].strip()
    parts = re.split(r'\s+[-\u2013\u2014]\s+', name)
    if len(parts) >= 2:
        r['artist'] = parts[0].strip()
        r['title'] = ' - '.join(parts[1:]).strip()
    else:
        r['title'] = name.strip()
    return r

def sanitize(s):
    s = s.replace('/', '-').replace('\\', '-').replace(':', ' -')
    s = re.sub(r'[<>"|?*\x00-\x1f]', '', s)
    s = re.sub(r'\s+', ' ', s).strip()
    return s

tags = read_tags(src)
fn   = parse_fn(Path(src).stem)

artist = (tags.get('artist') or fn.get('artist') or '').strip()
title  = (tags.get('title')  or fn.get('title')  or Path(src).stem).strip()

ca = sanitize(artist)
ct = sanitize(title)

if ca and ct:
    print(f"{ca} - {ct}.wav")
elif ct:
    print(f"{ct}.wav")
else:
    print(Path(src).stem + ".wav")
PYCLEAN
}

# --- Check whether an output WAV already has complete tags ---
# Returns 0 (complete) or 1 (incomplete/missing).
# Checks: TCON (genre, always required) + TXXX:Description (required when BPM or Key is on).
_tags_complete() {
  local wav="$1"
  python3 - "$wav" "$ANALYZE_BPM" "$ANALYZE_KEY" "$CLEAN_METADATA" 2>/dev/null << 'PYTAGCHECK'
import sys
try:
    from mutagen.wave import WAVE
    audio = WAVE(sys.argv[1])
    want_desc  = sys.argv[2].lower() == "true" or sys.argv[3].lower() == "true"
    want_clean = sys.argv[4].lower() == "true" if len(sys.argv) > 4 else False
    tags = audio.tags
    if tags is None:
        sys.exit(1)
    tcon = tags.get("TCON")
    if not tcon or not tcon.text[0].strip():
        sys.exit(1)
    if want_desc:
        txxx = tags.get("TXXX:Description")
        if not txxx or not txxx.text[0].strip():
            sys.exit(1)
    if want_clean:
        tpe1 = tags.get("TPE1")
        if not tpe1 or not tpe1.text[0].strip():
            sys.exit(1)
        tit2 = tags.get("TIT2")
        if not tit2 or not tit2.text[0].strip():
            sys.exit(1)
    sys.exit(0)
except Exception:
    sys.exit(1)
PYTAGCHECK
}

# --- Analyze output WAV: detect BPM and/or musical key, write ID3 tags ---
analyze_and_tag() {
  local file="$1"      # output WAV
  local src_file="$2"  # original source file (for metadata triangulation)
  python3 - "$file" "$ANALYZE_BPM" "$ANALYZE_KEY" "$KEY_FORMAT" "$SOURCE_DIR" "${src_file:-}" "$CLEAN_METADATA" << 'PYEOF'
import sys
import subprocess
import os
import re
from pathlib import Path

file      = sys.argv[1]
do_bpm    = sys.argv[2].lower() == "true"
do_key    = sys.argv[3].lower() == "true"
key_fmt   = sys.argv[4].lower()
src_dir   = sys.argv[5] if len(sys.argv) > 5 else ""
src_file  = sys.argv[6] if len(sys.argv) > 6 else ""
do_clean  = sys.argv[7].lower() == "true" if len(sys.argv) > 7 else False

# Genre = immediate parent folder of the file, always
genre = os.path.basename(os.path.dirname(file)) or None

def ensure_pkg(pkg):
    try:
        __import__(pkg)
    except ImportError:
        subprocess.run([sys.executable, "-m", "pip", "install", pkg, "-q"],
                       capture_output=True)

if do_bpm or do_key or genre or do_clean:
    ensure_pkg("mutagen")

bpm_val     = None
key_val     = None
standard_key = None

# --- BPM detection via aubio ---
if do_bpm:
    try:
        ensure_pkg("aubio")
        import aubio
        import statistics
        win_s = 1024
        hop_s = 512
        src = aubio.source(file, 0, hop_s)
        samplerate = src.samplerate
        tempo = aubio.tempo("default", win_s, hop_s, samplerate)
        beats = []
        while True:
            samples, read = src()
            if tempo(samples):
                beats.append(tempo.get_bpm())
            if read < hop_s:
                break
        if beats:
            bpm_val = round(statistics.median(beats))
            print(f"INFO: BPM detected: {bpm_val}")
        else:
            print("WARN: BPM detection returned no beats")
    except Exception as e:
        print(f"WARN: BPM detection failed: {e}")

# --- Key detection: keyfinder-cli first, aubio fallback ---
if do_key:
    try:
        result = subprocess.run(
            ["keyfinder-cli", file],
            capture_output=True, text=True, timeout=60
        )
        raw_key = result.stdout.strip()
        if not raw_key:
            raise ValueError("keyfinder-cli returned empty output")
        standard_key = raw_key
        print(f"INFO: Key detected (keyfinder-cli): {standard_key}")
    except FileNotFoundError:
        print("WARN: keyfinder-cli not found, falling back to aubio key detection")
        try:
            ensure_pkg("aubio")
            import aubio
            win_s = 4096
            hop_s = 512
            src = aubio.source(file, 0, hop_s)
            samplerate = src.samplerate
            pitch_o = aubio.pitch("yin", win_s, hop_s, samplerate)
            pitch_hist = [0.0] * 12
            while True:
                samples, read = src()
                p = pitch_o(samples)[0]
                if p > 0:
                    pitch_hist[int(round(p)) % 12] += 1
                if read < hop_s:
                    break
            major_p = [6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88]
            minor_p = [6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17]
            notes   = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
            total   = sum(pitch_hist) or 1
            norm    = [x / total for x in pitch_hist]
            best_corr = -1
            for root in range(12):
                for profile, suffix in [(major_p, ""), (minor_p, "m")]:
                    rot  = profile[root:] + profile[:root]
                    corr = sum(a * b for a, b in zip(norm, rot))
                    if corr > best_corr:
                        best_corr = corr
                        standard_key = notes[root] + suffix
            print(f"INFO: Key detected (aubio fallback): {standard_key}")
        except Exception as e:
            print(f"WARN: Key detection failed: {e}")
    except Exception as e:
        print(f"WARN: Key detection failed: {e}")

    if standard_key:
        std_to_camelot = {
            "C":"8B","G":"9B","D":"10B","A":"11B","E":"12B","B":"1B",
            "F#":"2B","C#":"3B","G#":"4B","D#":"5B","A#":"6B","F":"7B",
            "Am":"8A","Em":"9A","Bm":"10A","F#m":"11A","C#m":"12A",
            "G#m":"1A","D#m":"2A","A#m":"3A","Fm":"4A","Cm":"5A",
            "Gm":"6A","Dm":"7A",
        }
        std_to_openkey = {
            "C":"1d","G":"2d","D":"3d","A":"4d","E":"5d","B":"6d",
            "F#":"7d","C#":"8d","G#":"9d","D#":"10d","A#":"11d","F":"12d",
            "Am":"1m","Em":"2m","Bm":"3m","F#m":"4m","C#m":"5m",
            "G#m":"6m","D#m":"7m","A#m":"8m","Fm":"9m","Cm":"10m",
            "Gm":"11m","Dm":"12m",
        }
        if key_fmt == "camelot":
            key_val = std_to_camelot.get(standard_key, standard_key)
        elif key_fmt == "openkey":
            key_val = std_to_openkey.get(standard_key, standard_key)
        else:
            key_val = standard_key

# --- Helpers for clean metadata ---
def _read_src_tags(path):
    """Read easy-mode tags from any mutagen-supported format."""
    if not path or not os.path.exists(path):
        return {}
    try:
        from mutagen import File as MutagenFile
        audio = MutagenFile(path, easy=True)
        if not audio:
            return {}
        r = {}
        for k in ('title', 'artist', 'album', 'tracknumber'):
            v = audio.get(k)
            if v:
                r[k] = str(v[0]).strip()
        return r
    except Exception:
        return {}

def _parse_fn(stem):
    """Parse artist, title, optional track_num from a filename stem."""
    name = stem
    r = {}
    m = re.match(r'^[(\[]?(\d{1,3})[)\]]?[\s.\-_]+', name)
    if m:
        r['track_num'] = int(m.group(1))
        name = name[m.end():].strip()
    parts = re.split(r'\s+[-\u2013\u2014]\s+', name)
    if len(parts) >= 2:
        r['artist'] = parts[0].strip()
        r['title']  = ' - '.join(parts[1:]).strip()
    else:
        r['title'] = name.strip()
    return r

# --- Write ID3 tags to WAV ---
if bpm_val is not None or key_val is not None or genre is not None or do_clean:
    try:
        from mutagen.wave import WAVE
        from mutagen.id3 import TBPM, TKEY, TXXX, TCON, TPE1, TIT2, TALB, TRCK
        audio = WAVE(file)
        if audio.tags is None:
            audio.add_tags()
        if bpm_val is not None:
            audio.tags.add(TBPM(encoding=3, text=[str(bpm_val)]))
        if key_val is not None:
            audio.tags.add(TKEY(encoding=3, text=[key_val]))
        # Build Description field (TXXX:Description — shows as "Description" in MediaInfo/Nemo)
        desc_parts = []
        if bpm_val is not None:
            desc_parts.append(f"BPM: {bpm_val}")
        if key_val is not None:
            desc_parts.append(f"Key: {key_val}")
        if desc_parts:
            desc_text = " | ".join(desc_parts)
            audio.tags.add(TXXX(encoding=3, desc="Description", text=[desc_text]))
        # Write genre from immediate parent folder
        if genre:
            audio.tags.add(TCON(encoding=3, text=[genre]))
        # --- Clean metadata: triangulate Artist/Title/Album/Track ---
        if do_clean:
            src_tags = _read_src_tags(src_file)
            fn_info  = _parse_fn(Path(src_file).stem) if src_file else {}
            artist = (src_tags.get('artist') or fn_info.get('artist') or '').strip()
            title  = (src_tags.get('title')  or fn_info.get('title')  or '').strip()
            album  = src_tags.get('album', '').strip()
            # Track number: prefer source tag (handles "1/12" format), fall back to filename
            trk_raw = src_tags.get('tracknumber', '')
            if trk_raw:
                try:
                    track_num = str(int(trk_raw.split('/')[0].strip()))
                except Exception:
                    track_num = str(fn_info['track_num']) if fn_info.get('track_num') else ''
            else:
                track_num = str(fn_info['track_num']) if fn_info.get('track_num') else ''
            if artist:
                audio.tags.add(TPE1(encoding=3, text=[artist]))
            if title:
                audio.tags.add(TIT2(encoding=3, text=[title]))
            if album:
                audio.tags.add(TALB(encoding=3, text=[album]))
            if track_num:
                audio.tags.add(TRCK(encoding=3, text=[track_num]))
            info_parts = []
            if artist:    info_parts.append(f"artist={artist!r}")
            if title:     info_parts.append(f"title={title!r}")
            if album:     info_parts.append(f"album={album!r}")
            if track_num: info_parts.append(f"track={track_num!r}")
            print(f"INFO: Metadata cleaned: {', '.join(info_parts)}")
        audio.save()
        print(f"INFO: Tags written to {os.path.basename(file)}")
    except Exception as e:
        print(f"ERROR: Failed to write tags: {e}")
PYEOF
}

# --- Verify output WAV: compare waveform stats between source and output ---
# Uses astats on both files so we directly compare the two waveforms.
verify_integrity() {
  local src_file="$1"
  local out_file="$2"

  # ── 1. Duration integrity ─────────────────────────────────────────────────
  local src_dur out_dur
  src_dur=$(ffprobe -v error -show_entries format=duration \
    -of csv=p=0 "$src_file" 2>/dev/null || echo "")
  out_dur=$(ffprobe -v error -show_entries format=duration \
    -of csv=p=0 "$out_file" 2>/dev/null || echo "")

  if [ -n "$src_dur" ] && [ -n "$out_dur" ]; then
    local diff_int
    diff_int=$(awk -v s="$src_dur" -v o="$out_dur" \
      'BEGIN{d=s-o; if(d<0)d=-d; printf "%d", d+0.5}')
    if [ "$diff_int" -gt 2 ]; then
      echo "WARN: Duration mismatch: source=${src_dur}s output=${out_dur}s (diff=${diff_int}s)"
    fi
  fi

  # ── 2. Waveform comparison via astats on source and output ─────────────────
  # Run astats + volumedetect on source
  local src_analysis
  src_analysis=$(ffmpeg -i "$src_file" \
    -af "astats,volumedetect" \
    -f null /dev/null 2>&1 || true)
  # Run astats + volumedetect on output (single pass)
  local out_analysis
  out_analysis=$(ffmpeg -i "$out_file" \
    -af "astats,volumedetect" \
    -f null /dev/null 2>&1 || true)

  # Extract RMS levels from both (astats reports "RMS level dB")
  local rms_src rms_out
  rms_src=$(echo "$src_analysis" | grep -oP 'RMS level dB:\s*\K[-0-9.]+' | head -1 || echo "")
  rms_out=$(echo "$out_analysis" | grep -oP 'RMS level dB:\s*\K[-0-9.]+' | head -1 || echo "")

  # Warn if RMS difference between source and output exceeds 3 dB
  # (accounts for loudness normalisation which intentionally changes levels,
  #  but a larger gap may indicate a processing error)
  if [ -n "$rms_src" ] && [ -n "$rms_out" ]; then
    local rms_diff_int
    rms_diff_int=$(awk -v s="$rms_src" -v o="$rms_out" \
      'BEGIN{d=o-s; if(d<0)d=-d; printf "%d", d+0.5}')
    if [ "$rms_diff_int" -gt 15 ]; then
      echo "WARN: Large RMS level difference between source and output (${rms_src} dB → ${rms_out} dB, diff=${rms_diff_int} dB) — possible encoding issue"
    fi
  fi

  # ── 3. Near-silence / clipping (volumedetect) ────────────────────────────
  local max_vol mean_vol
  max_vol=$(echo "$out_analysis" | grep -oP 'max_volume: \K[-0-9.]+' | head -1 || echo "")
  mean_vol=$(echo "$out_analysis" | grep -oP 'mean_volume: \K[-0-9.]+' | head -1 || echo "")

  # Mean ≤ -50 dBFS → output is essentially mute (encoding failure)
  if [ -n "$mean_vol" ]; then
    local is_mute
    is_mute=$(awk -v v="$mean_vol" 'BEGIN{printf "%d", v <= -50}')
    if [ "$is_mute" = "1" ]; then
      echo "WARN: Output appears near-silent (mean: ${mean_vol} dBFS) — possible mute or encoding failure"
    fi
  fi

  # Max ≥ -0.1 dBFS → possible clipping
  if [ -n "$max_vol" ]; then
    local is_clip
    is_clip=$(awk -v v="$max_vol" 'BEGIN{printf "%d", v >= -0.1}')
    if [ "$is_clip" = "1" ]; then
      local clipped_n
      clipped_n=$(echo "$out_analysis" | grep -oP 'histogram_0db: \K[0-9]+' | head -1 || echo "?")
      echo "WARN: Possible clipping in output (max: ${max_vol} dBFS; samples at 0dBFS: ${clipped_n})"
    fi
  fi

  # ── 4. Corrupt samples: NaN / Inf (astats) ───────────────────────────────
  # Sum across all channels (stereo = two lines per metric)
  local nan_n inf_n
  nan_n=$(echo "$out_analysis" | grep -oP 'Number of NaNs:\s*\K[0-9]+' | \
    awk '{s+=$1} END{print s+0}' || echo "0")
  inf_n=$(echo "$out_analysis"  | grep -oP 'Number of Infs:\s*\K[0-9]+' | \
    awk '{s+=$1} END{print s+0}' || echo "0")
  [ -z "$nan_n" ] && nan_n=0
  [ -z "$inf_n" ] && inf_n=0
  if [ "$nan_n" -gt 0 ]; then
    echo "ERROR: Output contains ${nan_n} NaN sample(s) — file may be corrupt"
  fi
  if [ "$inf_n" -gt 0 ]; then
    echo "ERROR: Output contains ${inf_n} Inf sample(s) — file may be corrupt"
  fi

  # DC offset > 5% of full scale → audible hum risk
  local dc_off
  dc_off=$(echo "$out_analysis" | grep -oP 'DC offset:\s*\K[-0-9.e+]+' | head -1 || echo "")
  if [ -n "$dc_off" ]; then
    local dc_warn
    dc_warn=$(awk -v d="$dc_off" 'BEGIN{if(d<0)d=-d; printf "%d", d > 0.05}')
    if [ "$dc_warn" = "1" ]; then
      echo "WARN: Significant DC offset in output: ${dc_off} (>5% of full scale)"
    fi
  fi

  # ── 5. File-size sanity: WAV must be ≥ 50% of expected uncompressed size ──
  if [ -n "$out_dur" ] && [ -f "$out_file" ]; then
    local file_bytes expected_min
    file_bytes=$(stat -c%s "$out_file" 2>/dev/null || echo 0)
    expected_min=$(awk -v d="$out_dur" -v sr="$TARGET_SAMPLE_RATE" \
      -v ch="$TARGET_CHANNELS" -v bd="$TARGET_BIT_DEPTH" \
      'BEGIN{printf "%d", d * sr * ch * (bd/8) * 0.5}')
    if [ "$file_bytes" -lt "$expected_min" ]; then
      echo "WARN: File is suspiciously small (${file_bytes} bytes) for ${out_dur}s audio — minimum expected: ${expected_min} bytes"
    fi
  fi

  return 0
}

# --- GUI progress window (shown during conversion) ---
# Launched after file discovery; communicates via a FIFO.
# Falls back silently when no display or customtkinter is available.
launch_progress_window() {
  local total_files="$1"
  local parallel_jobs="$2"

  [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && return
  python3 -c "import customtkinter" 2>/dev/null || return

  PROGRESS_FIFO=$(mktemp -u /tmp/mc_progress_XXXXXX)
  PROGRESS_SCRIPT=$(mktemp /tmp/mc_pgui_XXXXXX.py)
  mkfifo "$PROGRESS_FIFO" || { PROGRESS_FIFO="" PROGRESS_SCRIPT=""; return; }

  cat > "$PROGRESS_SCRIPT" << 'PROGRESS_GUI'
import sys, os, threading, queue
try:
    import customtkinter as ctk
    import tkinter as tk
except ImportError:
    sys.exit(0)

total        = int(sys.argv[1]) if len(sys.argv) > 1 else 1
jobs         = int(sys.argv[2]) if len(sys.argv) > 2 else 1
file_workers = max(jobs - 1, 1)  # 1 worker is reserved for this UI process

STEPS     = [("measuring","Measure"),("converting","Convert"),
             ("validating","Validate"),("tagging","Tag"),("integrity","Integrity")]
STEP_KEYS = [k for k,_ in STEPS]
C_PENDING = "gray40"
C_ACTIVE  = "#60A5FA"
C_DONE    = "#4ADE80"
C_FAIL    = "#F87171"
C_SEP     = "gray35"

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("blue")

try:
    app = ctk.CTk()
except Exception:
    sys.exit(0)

app.title("\u266b Music Converter \u2014 Converting\u2026")
screen_h = app.winfo_screenheight()
ui_scale = max(1.0, screen_h / 1080)
ctk.set_widget_scaling(ui_scale)

F_TITLE = ctk.CTkFont(size=22, weight="bold")
F_SUB   = ctk.CTkFont(size=12)
F_SEC   = ctk.CTkFont(size=13, weight="bold")
F_CARD  = ctk.CTkFont(size=12, weight="bold")
F_STEP  = ctk.CTkFont(size=11)
F_LOG   = ctk.CTkFont(size=11)

CARD_H = 82
win_w  = 640
win_h  = min(920, 240 + max(file_workers, 1) * (CARD_H + 8) + 185)
app.geometry(f"{int(win_w * ui_scale)}x{int(win_h * ui_scale)}")
app.resizable(False, True)

scroll = ctk.CTkScrollableFrame(app, fg_color="transparent")
scroll.pack(fill="both", expand=True, padx=0, pady=0)

# Header
hdr = ctk.CTkFrame(scroll, fg_color="transparent")
hdr.pack(fill="x", padx=24, pady=(20, 0))
title_lbl = ctk.CTkLabel(hdr, text="\u266b Music Converter", font=F_TITLE)
title_lbl.pack(anchor="w")
suffix = f"  \u00b7  {file_workers} processing + 1 UI" if jobs > 1 else ""
sub_lbl = ctk.CTkLabel(hdr,
    text=f"Converting {total} file{'s' if total != 1 else ''}{suffix}\u2026",
    font=F_SUB, text_color="gray55")
sub_lbl.pack(anchor="w", pady=(4, 0))

# Overall progress
prog_sec = ctk.CTkFrame(scroll, corner_radius=10)
prog_sec.pack(fill="x", padx=20, pady=(16, 4))
ctk.CTkLabel(prog_sec, text="Overall Progress", font=F_SEC).pack(anchor="w", padx=14, pady=(12, 4))
pg = ctk.CTkFrame(prog_sec, fg_color="transparent")
pg.pack(fill="x", padx=14, pady=(0, 12))
prog_bar = ctk.CTkProgressBar(pg, height=18)
prog_bar.set(0)
prog_bar.pack(fill="x", pady=(0, 6))
stats_lbl = ctk.CTkLabel(pg, text=f"0 / {total}", font=F_SUB, text_color="gray55")
stats_lbl.pack(anchor="w")

# Worker cards — one per parallel job
workers_sec = ctk.CTkFrame(scroll, corner_radius=10)
workers_sec.pack(fill="x", padx=20, pady=4)
ctk.CTkLabel(workers_sec,
    text="Workers" if file_workers > 1 else "Progress",
    font=F_SEC).pack(anchor="w", padx=14, pady=(12, 6))

slots = []
for _ in range(max(file_workers, 1)):
    card = ctk.CTkFrame(workers_sec, corner_radius=8, fg_color=("#1e1e1e","#1e1e1e"))
    card.pack(fill="x", padx=10, pady=(0, 6))
    r1 = ctk.CTkFrame(card, fg_color="transparent")
    r1.pack(fill="x", padx=10, pady=(8, 2))
    icon_lbl = ctk.CTkLabel(r1, text="\u2014", font=F_CARD, text_color="gray55", width=20)
    icon_lbl.pack(side="left")
    name_lbl = ctk.CTkLabel(r1, text="\u2014", font=F_CARD, text_color="gray55", anchor="w")
    name_lbl.pack(side="left", padx=(6, 0), fill="x", expand=True)
    r2 = ctk.CTkFrame(card, fg_color="transparent")
    r2.pack(fill="x", padx=10, pady=(0, 2))
    step_lbls = {}
    for si, (skey, sname) in enumerate(STEPS):
        lbl = ctk.CTkLabel(r2, text=sname, font=F_STEP, text_color=C_PENDING)
        lbl.pack(side="left")
        step_lbls[skey] = lbl
        if si < len(STEPS) - 1:
            ctk.CTkLabel(r2, text=" \u2192 ", font=F_STEP, text_color=C_SEP).pack(side="left")
    r3 = ctk.CTkFrame(card, fg_color="transparent")
    r3.pack(fill="x", padx=10, pady=(2, 8))
    prog = ctk.CTkProgressBar(r3, height=6, mode="indeterminate", indeterminate_speed=0.8)
    prog.pack(fill="x")
    prog.set(0)
    slots.append({"file": None, "icon": icon_lbl, "name": name_lbl,
                  "steps": step_lbls, "cur": None, "done": set(), "failed": False,
                  "bar": prog})

def _slot_for(path):
    for s in slots:
        if s["file"] == path:
            return s
    return None

def _free_slot():
    for s in slots:
        if s["file"] is None:
            return s
    return slots[0]

def _refresh(s):
    if s["file"] is None:
        s["icon"].configure(text="\u2014", text_color="gray55")
        s["name"].configure(text="\u2014", text_color="gray55")
        for lbl in s["steps"].values():
            lbl.configure(text_color=C_PENDING, font=F_STEP)
        return
    if s["failed"]:
        s["icon"].configure(text="\u2717", text_color=C_FAIL)
    elif s["cur"]:
        s["icon"].configure(text="\u25b6", text_color=C_ACTIVE)
    else:
        s["icon"].configure(text="\u2713", text_color=C_DONE)
    s["name"].configure(text_color="white")
    for skey, lbl in s["steps"].items():
        if skey == s["cur"]:
            lbl.configure(text_color=C_ACTIVE, font=ctk.CTkFont(size=11, weight="bold"))
        elif skey in s["done"]:
            lbl.configure(text_color=C_DONE, font=F_STEP)
        else:
            lbl.configure(text_color=C_PENDING, font=F_STEP)

# Recent activity log
log_sec = ctk.CTkFrame(scroll, corner_radius=10)
log_sec.pack(fill="x", padx=20, pady=4)
ctk.CTkLabel(log_sec, text="Recent Activity", font=F_SEC).pack(anchor="w", padx=14, pady=(12, 4))
log_box = ctk.CTkTextbox(log_sec, height=110, font=F_LOG, state="disabled")
log_box.pack(fill="x", padx=14, pady=(0, 12))

# Close button (enabled when done)
btn_row = ctk.CTkFrame(scroll, fg_color="transparent")
btn_row.pack(fill="x", padx=20, pady=(4, 18))
close_btn = ctk.CTkButton(btn_row, text="Close", width=120, command=app.destroy, state="disabled")
close_btn.pack(side="right")

# State & IPC
done = conv = fail = skip = 0
finished = False
eq = queue.Queue()

def _reader():
    try:
        for line in sys.stdin:
            eq.put(line.rstrip())
    except Exception:
        pass
    eq.put("__EOF__")

threading.Thread(target=_reader, daemon=True).start()

ICONS = {"converted": "\u2713", "failed": "\u2717", "skipped": "\u25a0"}

def _log(text):
    log_box.configure(state="normal")
    log_box.insert("end", text + "\n")
    log_box.see("end")
    log_box.configure(state="disabled")

def _on_start(path):
    s = _slot_for(path)
    if s is None:
        s = _free_slot()
        s["file"] = path
        s["cur"] = None
        s["done"] = set()
        s["failed"] = False
        s["name"].configure(text=os.path.basename(path))
        s["bar"].set(0.0)
    _refresh(s)

def _on_step(path, step):
    s = _slot_for(path)
    if s is None:
        return
    if s["cur"] in STEP_KEYS:
        s["done"].add(s["cur"])
    s["cur"] = step
    _refresh(s)
    s["bar"].stop()
    s["bar"].start()

def _on_done(path, status):
    global done, conv, fail, skip
    done += 1
    if status == "converted": conv += 1
    elif status == "failed":  fail += 1
    elif status == "skipped": skip += 1
    s = _slot_for(path)
    if s:
        if s["cur"]:
            if status == "converted":
                s["done"].add(s["cur"])
            elif status == "failed":
                s["failed"] = True
        s["cur"] = None
        _refresh(s)
        s["bar"].stop()
        s["bar"].set(1.0 if status == "converted" else 0.0)
        app.after(1500, lambda sv=s, fv=path: _clear(sv, fv))
    prog_bar.set(done / total if total else 1)
    stats_lbl.configure(text=f"{done} / {total} files  \u2014  "
        f"\u2713\u202f{conv}  \u2717\u202f{fail}  \u25a0\u202f{skip}")
    icon = ICONS.get(status, "?")
    _log(f"  {icon}  {os.path.basename(path)}  ({status})")

def _clear(s, path):
    if s["file"] == path:
        s["file"] = None
        _refresh(s)
        s["bar"].set(0.0)

def _on_finish():
    global finished
    finished = True
    prog_bar.set(1.0)
    title_lbl.configure(text="\u266b Music Converter \u2014 Done!")
    sub_lbl.configure(text=f"Completed  \u2014  "
        f"\u2713\u202f{conv} converted   \u2717\u202f{fail} failed   \u25a0\u202f{skip} skipped")
    for s in slots:
        s["file"] = None
        s["bar"].stop()
        s["bar"].set(0.0)
        _refresh(s)
    _log(f"\n  All done: {conv} converted, {fail} failed, {skip} skipped.")
    close_btn.configure(state="normal")
    app.title("\u266b Music Converter \u2014 Done!")

def _poll():
    try:
        while True:
            msg = eq.get_nowait()
            if msg == "__EOF__":
                if not finished:
                    _on_finish()
                return
            elif msg.startswith("FILE_START:"):
                _on_start(msg[11:])
            elif msg.startswith("FILE_STEP:"):
                body = msg[10:]
                colon = body.rfind(":")
                if colon > 0:
                    _on_step(body[:colon], body[colon + 1:])
            elif msg.startswith("FILE_DONE:"):
                body = msg[10:]
                colon = body.rfind(":")
                if colon > 0:
                    _on_done(body[:colon], body[colon + 1:])
            elif msg.startswith("DONE:") and not finished:
                _on_finish()
    except queue.Empty:
        pass
    app.after(150, _poll)

app.after(150, _poll)
app.protocol("WM_DELETE_WINDOW", app.destroy)
app.mainloop()
PROGRESS_GUI

  # Open FIFO O_RDWR so it stays "connected" without blocking
  exec 8<>"$PROGRESS_FIFO"
  # Launch progress window; its stdin reads from the FIFO
  python3 "$PROGRESS_SCRIPT" "$total_files" "$parallel_jobs" < "$PROGRESS_FIFO" &
  PROGRESS_PID=$!
}

send_progress_event() {
  [ -n "$PROGRESS_FIFO" ] || return 0
  echo "$1" >&8 2>/dev/null || true
}

close_progress_window() {
  [ -n "$PROGRESS_FIFO" ] || return 0
  send_progress_event "DONE:"
  exec 8>&-  # Close write end → Python stdin sees EOF → window auto-closes
  [ -n "$PROGRESS_PID" ] && wait "$PROGRESS_PID" 2>/dev/null || true
  rm -f "$PROGRESS_FIFO" "$PROGRESS_SCRIPT"
  PROGRESS_FIFO="" PROGRESS_PID="" PROGRESS_SCRIPT=""
}

update_progress_bar() {
  local processed_files="$1"
  local total_files="$2"
  local color="$3"
  local current_file="$4"

  # GUI progress window is active — no terminal output needed
  [ -n "$PROGRESS_FIFO" ] && return

  local percentage=$((processed_files * 100 / total_files))
  local progress_bar_length=50
  local filled_length=$((percentage * progress_bar_length / 100))
  local empty_length=$((progress_bar_length - filled_length))
  local progress_bar=$(printf "[%*s%*s]" "$filled_length" "" "$empty_length" "")
  progress_bar=${progress_bar// /#} # Fill with '#'
  progress_bar=${progress_bar/#[/#} # Remove first '#'

  echo -ne "\033[2A" >&2 # Move cursor up two lines
  echo -ne "\r\033[K" >&2 # Clear current line
  echo -e "${color}Total progress: ${percentage}% ${progress_bar} (${processed_files}/${total_files})${C_NC}" >&2
  echo -ne "\r\033[K" >&2 # Clear current line
  echo -e "${color}Current file: $(basename "$current_file")${C_NC}" >&2
}

# --- Validation function ---
# Uses ffprobe to verify an output file matches the target format exactly.
# Returns 0 (success) if valid, 1 (failure) if not.
validate_output() {
  local file="$1"

  if [ ! -f "$file" ]; then
    log "Validation failed: file does not exist: $file" "ERROR" "$C_RED"
    return 1
  fi

  local probe_output
  probe_output=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name,sample_rate,channels,bits_per_sample \
    -of csv=p=0 "$file" 2>&1) || {
    log "Validation failed: ffprobe error on $file: $probe_output" "ERROR" "$C_RED"
    return 1
  }

  local codec sample_rate channels bits_per_sample
  IFS=',' read -r codec sample_rate channels bits_per_sample <<< "$probe_output"

  if [ "$codec" != "$TARGET_CODEC" ] || \
     [ "$sample_rate" != "$TARGET_SAMPLE_RATE" ] || \
     [ "$channels" != "$TARGET_CHANNELS" ] || \
     [ "$bits_per_sample" != "$TARGET_BIT_DEPTH" ]; then
    log "Validation failed for $file: got codec=$codec, sample_rate=$sample_rate, channels=$channels, bits=$bits_per_sample (expected $TARGET_CODEC, $TARGET_SAMPLE_RATE, $TARGET_CHANNELS, $TARGET_BIT_DEPTH)" "ERROR" "$C_RED"
    return 1
  fi

  return 0
}

# --- Get source format info for error reporting ---
get_source_info() {
  local file="$1"
  ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name,sample_rate,channels,bits_per_sample,bit_rate \
    -of default=noprint_wrappers=1 "$file" 2>&1 || echo "ffprobe failed"
}

# --- Two-pass loudness normalization ---
# Pass 1: Measure loudness and return the measured values as colon-separated string.
# Returns: input_i:input_tp:input_lra:input_thresh:target_offset
# Prints the values to stdout; logs errors.
measure_loudness() {
  local file="$1"

  local loudnorm_output
  loudnorm_output=$(ffmpeg -i "$file" -af "loudnorm=I=${TARGET_LUFS}:TP=${TARGET_TP}:LRA=11:print_format=json" -f null /dev/null 2>&1) || {
    log "Loudness measurement failed for $file" "ERROR" "$C_RED"
    return 1
  }

  local input_i input_tp input_lra input_thresh target_offset
  input_i=$(echo "$loudnorm_output" | grep '"input_i"' | sed 's/.*: "//;s/".*//')
  input_tp=$(echo "$loudnorm_output" | grep '"input_tp"' | sed 's/.*: "//;s/".*//')
  input_lra=$(echo "$loudnorm_output" | grep '"input_lra"' | sed 's/.*: "//;s/".*//')
  input_thresh=$(echo "$loudnorm_output" | grep '"input_thresh"' | sed 's/.*: "//;s/".*//')
  target_offset=$(echo "$loudnorm_output" | grep '"target_offset"' | sed 's/.*: "//;s/".*//')

  if [ -z "$input_i" ] || [ -z "$input_tp" ] || [ -z "$input_lra" ] || [ -z "$input_thresh" ] || [ -z "$target_offset" ]; then
    log "Failed to parse loudnorm measurements for $file" "ERROR" "$C_RED"
    return 1
  fi

  echo "${input_i}:${input_tp}:${input_lra}:${input_thresh}:${target_offset}"
}

process_file() {
  local file="$1"
  local SOURCE_DIR="$2"
  local DEST_DIR="$3"
  local LOG_FILE="$4"
  local FORCE_MODE="$5"

  # Per-file temp log — buffered so the whole block flushes atomically (no parallel interleaving)
  local tmp_log
  tmp_log=$(mktemp /tmp/mc_XXXXXX.log)

  # plog: write timestamped line to tmp_log; echo errors/forced lines to stderr immediately
  plog() {
    local msg="$1" lvl="$2" col="$3" console="$4"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ${lvl} - ${msg}" >> "$tmp_log"
    if [ "$lvl" = "ERROR" ] || [ "$console" = "force" ]; then
      echo -e "${col}${lvl}: ${msg}${C_NC}" >&2
    fi
  }

  # Notify progress window that this file has started
  send_progress_event "FILE_START:$file"

  # --- Determine destination path (always .wav) ---
  local rel_path="${file#$SOURCE_DIR/}"
  local dest_file_wav="$DEST_DIR/${rel_path%.*}.wav"
  local dest_dir
  dest_dir=$(dirname "$dest_file_wav")
  mkdir -p "$dest_dir" >/dev/null 2>&1

  # If clean metadata is on, rename destination to "{Artist} - {Title}.wav"
  if [ "$CLEAN_METADATA" = "true" ]; then
    local clean_name
    clean_name=$(compute_clean_filename "$file")
    if [ -n "$clean_name" ]; then
      dest_file_wav="$dest_dir/$clean_name"
    fi
  fi

  # --- Skip logic: if destination exists, is valid, and not in force mode ---
  if [ "$FORCE_MODE" != "true" ] && [ -f "$dest_file_wav" ]; then
    if validate_output "$dest_file_wav" >/dev/null 2>&1; then
      if _tags_complete "$dest_file_wav"; then
        plog "Skipping '$(basename "$dest_file_wav")': already valid with complete tags" "INFO" "$C_YELLOW"
        _flush_log "$tmp_log" "$LOG_FILE"
        send_progress_event "FILE_DONE:$file:skipped"
        echo "skipped"
        return
      else
        plog "Output exists but tags incomplete, re-tagging: $(basename "$dest_file_wav")" "WARN" "$C_YELLOW"
        send_progress_event "FILE_STEP:$file:tagging"
        while IFS= read -r tag_line; do
          local ta_lvl="${tag_line%%:*}"
          local ta_msg="${tag_line#*: }"
          local ta_col="$C_BLUE"
          [ "$ta_lvl" = "WARN" ]  && ta_col="$C_YELLOW"
          [ "$ta_lvl" = "ERROR" ] && ta_col="$C_RED"
          plog "$ta_msg" "$ta_lvl" "$ta_col"
        done < <(analyze_and_tag "$dest_file_wav" "$file" 2>/dev/null)
        _flush_log "$tmp_log" "$LOG_FILE"
        send_progress_event "FILE_DONE:$file:converted"
        echo "converted"
        return
      fi
    else
      plog "Output file '$dest_file_wav' exists but is invalid, re-converting..." "WARN" "$C_YELLOW"
    fi
  fi

  # --- Pass 1: Measure loudness ---
  send_progress_event "FILE_STEP:$file:measuring"
  local measured_values
  if ! measured_values=$(measure_loudness "$file"); then
    plog "Loudness measurement failed for $file, skipping" "ERROR" "$C_RED"
    _flush_log "$tmp_log" "$LOG_FILE"
    send_progress_event "FILE_DONE:$file:failed"
    echo "failed"
    return
  fi

  local input_i input_tp input_lra input_thresh target_offset
  IFS=':' read -r input_i input_tp input_lra input_thresh target_offset <<< "$measured_values"

  plog "Measured loudness for $(basename "$file"): I=${input_i} LUFS, TP=${input_tp} dBTP" "INFO" "$C_BLUE"

  # --- Pass 2: Convert with normalization ---
  send_progress_event "FILE_STEP:$file:converting"
  local loudnorm_filter="loudnorm=I=${TARGET_LUFS}:TP=${TARGET_TP}:LRA=11:measured_I=${input_i}:measured_TP=${input_tp}:measured_LRA=${input_lra}:measured_thresh=${input_thresh}:offset=${target_offset}:linear=true"

  local ffmpeg_output
  local sample_fmt="s16"
  if [ "$TARGET_BIT_DEPTH" = "24" ]; then
    sample_fmt="s32"
  fi
  if ffmpeg_output=$(ffmpeg -i "$file" -af "$loudnorm_filter" -ar "$TARGET_SAMPLE_RATE" -sample_fmt "$sample_fmt" -ac "$TARGET_CHANNELS" -c:a "$TARGET_CODEC" -y "$dest_file_wav" 2>&1); then
    touch -r "$file" "$dest_file_wav" >/dev/null 2>&1
    send_progress_event "FILE_STEP:$file:validating"
    if validate_output "$dest_file_wav"; then
      plog "Converted $file to $dest_file_wav" "INFO" "$C_GREEN"

      # --- Tagging (genre always; BPM/Key when enabled) ---
      send_progress_event "FILE_STEP:$file:tagging"
      while IFS= read -r tag_line; do
        local ta_lvl="${tag_line%%:*}"
        local ta_msg="${tag_line#*: }"
        local ta_col="$C_BLUE"
        [ "$ta_lvl" = "WARN" ]  && ta_col="$C_YELLOW"
        [ "$ta_lvl" = "ERROR" ] && ta_col="$C_RED"
        plog "$ta_msg" "$ta_lvl" "$ta_col"
      done < <(analyze_and_tag "$dest_file_wav" "$file" 2>/dev/null)

      # --- Integrity verification ---
      if [ "$VERIFY_INTEGRITY" = "true" ]; then
        send_progress_event "FILE_STEP:$file:integrity"
        while IFS= read -r vi_line; do
          local vi_lvl="${vi_line%%:*}"
          local vi_msg="${vi_line#*: }"
          local vi_col="$C_YELLOW"
          [ "$vi_lvl" = "ERROR" ] && vi_col="$C_RED"
          plog "$vi_msg" "$vi_lvl" "$vi_col"
        done < <(verify_integrity "$file" "$dest_file_wav" 2>/dev/null)
      fi

      _flush_log "$tmp_log" "$LOG_FILE"
      send_progress_event "FILE_DONE:$file:converted"
      echo "converted"
    else
      plog "Converted $file but validation failed, deleting bad output" "ERROR" "$C_RED"
      rm -f "$dest_file_wav"
      _flush_log "$tmp_log" "$LOG_FILE"
      send_progress_event "FILE_DONE:$file:failed"
      echo "failed"
    fi
  else
    plog "Failed to convert $file to $dest_file_wav" "ERROR" "$C_RED"
    plog "ffmpeg output:\n$ffmpeg_output" "ERROR" "$C_RED"
    rm -f "$dest_file_wav"
    _flush_log "$tmp_log" "$LOG_FILE"
    send_progress_event "FILE_DONE:$file:failed"
    echo "failed"
  fi
}



# --- Conversion parameters ---
display_conversion_parameters() {
  log "--- Conversion parameters ---" "INFO" "$C_BLUE" "force"
  log "ffmpeg version: $(ffmpeg -version | head -n 1)" "INFO" "$C_BLUE" "force"
  log "Output format: WAV ($TARGET_CODEC, ${TARGET_SAMPLE_RATE} Hz, ${TARGET_BIT_DEPTH}-bit, stereo)" "INFO" "$C_BLUE" "force"
  log "Loudness normalization: ${TARGET_LUFS} LUFS (two-pass, TP=${TARGET_TP} dBTP)" "INFO" "$C_BLUE" "force"
  if [ "$FORCE_MODE" = "true" ]; then
    log "Force mode: ENABLED (re-converting all files)" "INFO" "$C_YELLOW" "force"
  fi
  if [ "$PARALLEL_JOBS" -gt 1 ]; then
    log "Parallel: Yes, $PARALLEL_JOBS workers" "INFO" "$C_BLUE" "force"
  else
    log "Parallel: No (sequential)" "INFO" "$C_BLUE" "force"
  fi
  if [ "$ANALYZE_BPM" = "true" ] || [ "$ANALYZE_KEY" = "true" ]; then
    local tag_info="BPM=${ANALYZE_BPM}, Key=${ANALYZE_KEY}"
    [ "$ANALYZE_KEY" = "true" ] && tag_info="${tag_info} (format: ${KEY_FORMAT})"
    log "Tag analysis: ${tag_info}" "INFO" "$C_BLUE" "force"
  fi
  if [ "$VERIFY_INTEGRITY" = "true" ]; then
    log "Integrity check: ENABLED (waveform comparison)" "INFO" "$C_BLUE" "force"
  fi
  if [ "$CLEAN_METADATA" = "true" ]; then
    log "Clean metadata: ENABLED (Artist/Title/Album/Track from tags+filename; output renamed to Artist - Title.wav)" "INFO" "$C_BLUE" "force"
  fi
  log "-----------------------------" "INFO" "$C_BLUE" "force"
}

# --- Main logic ---
main() {
  # --- Absolute paths ---
  SOURCE_DIR=$(realpath "$SOURCE_DIR")
  DEST_DIR=$(realpath "$DEST_DIR")

  # --- Create destination directory ---
  mkdir -p "$DEST_DIR"

  # --- Log file ---
  if [ -z "$LOG_FILE" ]; then
    LOG_FILE="$DEST_DIR/conversion_$(date '+%Y%m%d_%H%M%S').log"
  fi
  touch "$LOG_FILE"

  log "Starting conversion process" "INFO" "$C_GREEN" "force"
  log "Source directory: $SOURCE_DIR" "INFO" "$C_BLUE" "force"
  log "Destination directory: $DEST_DIR" "INFO" "$C_BLUE" "force"
  log "Log file: $LOG_FILE" "INFO" "$C_BLUE" "force"

  display_conversion_parameters

  # --- Find files (including .aif) ---
  local files_to_process=()
  while IFS= read -r file; do
    files_to_process+=("$file")
  done < <(find "$SOURCE_DIR" -type f \( -iname "*.flac" -o -iname "*.mp3" -o -iname "*.m4a" -o -iname "*.aiff" -o -iname "*.aif" -o -iname "*.wav" \))

  local total_files=${#files_to_process[@]}
  local processed_files=0
  local converted_files=0
  local copied_files=0
  local failed_files=0
  local skipped_files=0
  local failed_files_list=()
  local failed_files_info=()

  log "Found $total_files files to process" "INFO" "$C_GREEN" "force"

  # Launch GUI progress window (no-op when headless or customtkinter absent)
  [ "$total_files" -gt 0 ] && launch_progress_window "$total_files" "$PARALLEL_JOBS"

  # When GUI is active, 1 worker is dedicated to the progress window
  local file_workers="$PARALLEL_JOBS"
  [ -n "$PROGRESS_FIFO" ] && file_workers=$(( PARALLEL_JOBS > 1 ? PARALLEL_JOBS - 1 : 1 ))

  # Initial blank lines only needed for the terminal progress bar
  if [ -z "$PROGRESS_FIFO" ]; then
    echo "" >&2
    echo "" >&2
  fi

  # --- Process files ---
  if [ "$file_workers" -le 1 ]; then
    # === Sequential mode (original behavior) ===
    for file in "${files_to_process[@]}"; do
      processed_files=$((processed_files + 1))

      status=$(process_file "$file" "$SOURCE_DIR" "$DEST_DIR" "$LOG_FILE" "$FORCE_MODE")

      case $status in
        "copied")
          copied_files=$((copied_files + 1))
          update_progress_bar "$processed_files" "$total_files" "$C_YELLOW" "$file"
          ;;
        "converted")
          converted_files=$((converted_files + 1))
          update_progress_bar "$processed_files" "$total_files" "$C_YELLOW" "$file"
          ;;
        "failed")
          failed_files=$((failed_files + 1))
          failed_files_list+=("$file")
          failed_files_info+=("$(get_source_info "$file")")
          update_progress_bar "$processed_files" "$total_files" "$C_RED" "$file"
          ;;
        "skipped")
          skipped_files=$((skipped_files + 1))
          update_progress_bar "$processed_files" "$total_files" "$C_YELLOW" "$file"
          ;;
      esac

    done
  else
    # === Parallel mode ===
    local results_dir
    results_dir=$(mktemp -d)
    trap "rm -rf '$results_dir'" EXIT

    local active_jobs=0

    for i in "${!files_to_process[@]}"; do
      local file="${files_to_process[$i]}"

      # Launch worker in background subshell
      (
        result=$(process_file "$file" "$SOURCE_DIR" "$DEST_DIR" "$LOG_FILE" "$FORCE_MODE")
        echo "$result" > "$results_dir/$i"
      ) &

      active_jobs=$((active_jobs + 1))

      # When job pool is full, wait for one to finish
      if [ "$active_jobs" -ge "$file_workers" ]; then
        wait -n 2>/dev/null || true
        active_jobs=$((active_jobs - 1))
        # Update progress based on completed result files
        local completed
        completed=$(find "$results_dir" -maxdepth 1 -type f | wc -l)
        update_progress_bar "$completed" "$total_files" "$C_YELLOW" "$file_workers parallel workers"
      fi
    done

    # Wait for all remaining jobs
    wait || true

    # Final progress update
    update_progress_bar "$total_files" "$total_files" "$C_YELLOW" "$file_workers parallel workers"

    # Tally results from result files
    for i in "${!files_to_process[@]}"; do
      local file="${files_to_process[$i]}"
      local result_file="$results_dir/$i"

      if [ -f "$result_file" ]; then
        local status
        status=$(cat "$result_file")
        case $status in
          "copied")    copied_files=$((copied_files + 1)) ;;
          "converted") converted_files=$((converted_files + 1)) ;;
          "failed")
            failed_files=$((failed_files + 1))
            failed_files_list+=("$file")
            failed_files_info+=("$(get_source_info "$file")")
            ;;
          "skipped")   skipped_files=$((skipped_files + 1)) ;;
          *)
            # Unexpected result (e.g. contaminated stdout) — treat as failure
            failed_files=$((failed_files + 1))
            failed_files_list+=("$file")
            failed_files_info+=("$(get_source_info "$file")")
            ;;
        esac
      else
        # No result file means the subshell crashed
        failed_files=$((failed_files + 1))
        failed_files_list+=("$file")
        failed_files_info+=("$(get_source_info "$file")")
      fi
    done

    # Clean up temp dir
    rm -rf "$results_dir"
    trap - EXIT
  fi

  # Close progress window (sends DONE, waits for Python to exit)
  close_progress_window

  # Move cursor to the next line (terminal progress bar only)
  [ -z "$PROGRESS_FIFO" ] && echo "" >&2

  # --- Final summary (console) ---
  log "Conversion process finished" "INFO" "$C_GREEN" "force"
  log "Total processed: $total_files | Converted: $converted_files | Copied (already valid): $copied_files | Skipped: $skipped_files | Failed: $failed_files" "INFO" "$C_GREEN" "force"

  if [ ${#failed_files_list[@]} -gt 0 ]; then
    log "--- Failed files ---" "ERROR" "$C_RED" "force"
    for failed_file in "${failed_files_list[@]}"; do
      log "$failed_file" "ERROR" "$C_RED" "force"
    done
    log "--------------------" "ERROR" "$C_RED" "force"
  fi

  # --- Enhanced report in log file ---
  if [ -n "$LOG_FILE" ]; then
    {
      echo ""
      echo "============================================"
      echo "  CONVERSION REPORT"
      echo "============================================"
      echo "Date:          $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Source:        $SOURCE_DIR"
      echo "Destination:   $DEST_DIR"
      echo "Target format: WAV ($TARGET_CODEC, ${TARGET_SAMPLE_RATE} Hz, ${TARGET_BIT_DEPTH}-bit, stereo)"
      echo "Loudness:      ${TARGET_LUFS} LUFS (two-pass, TP=${TARGET_TP} dBTP)"
      echo "Force mode:    $FORCE_MODE"
      if [ "$PARALLEL_JOBS" -gt 1 ]; then
        echo "Parallel:      $PARALLEL_JOBS jobs"
      else
        echo "Parallel:      No (sequential)"
      fi
      if [ "$ANALYZE_BPM" = "true" ] || [ "$ANALYZE_KEY" = "true" ]; then
        echo "BPM tagging:   $ANALYZE_BPM"
        echo "Key tagging:   $ANALYZE_KEY (format: $KEY_FORMAT)"
      fi
      if [ "$VERIFY_INTEGRITY" = "true" ]; then
        echo "Integrity:     Enabled (waveform comparison)"
      fi
      if [ "$CLEAN_METADATA" = "true" ]; then
        echo "Clean metadata: Enabled"
      fi
      echo ""
      echo "--- Results ---"
      echo "Total files:   $total_files"
      echo "Converted:     $converted_files"
      echo "Copied:        $copied_files (source WAV already in target format)"
      echo "Skipped:       $skipped_files (output already exists and valid)"
      echo "Failed:        $failed_files"
      echo ""

      if [ ${#failed_files_list[@]} -gt 0 ]; then
        echo "--- Failed Files Detail ---"
        for i in "${!failed_files_list[@]}"; do
          echo ""
          echo "  File: ${failed_files_list[$i]}"
          echo "  Source info:"
          echo "    ${failed_files_info[$i]}" | sed 's/^/    /'
        done
        echo ""
        echo "----------------------------"
      fi

      echo "============================================"
    } >> "$LOG_FILE"
  fi
}

main
