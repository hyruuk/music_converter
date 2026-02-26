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
base_w, base_h = 580, 660
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

parallel_var = tk.IntVar(value=0)

# Build cores list: "Max (N)" + every number from max down to 2
cores_values = [f"Max ({max_cores})"] + [str(n) for n in range(max_cores, 1, -1)]
cores_var = tk.StringVar(value=cores_values[0])

def toggle_cores():
    cores_menu.configure(state="normal" if parallel_var.get() == 1 else "disabled")

par_chk = ctk.CTkCheckBox(proc_content, text="Parallel processing",
                            variable=parallel_var, command=toggle_cores)
par_chk.pack(anchor="w", pady=(6, 0))
ToolTip(par_chk, "Process multiple files simultaneously\nusing multiple CPU cores.")

cores_row = ctk.CTkFrame(proc_content, fg_color="transparent")
cores_row.pack(fill="x", pady=(6, 0))
ctk.CTkLabel(cores_row, text="CPU Cores:", width=90).pack(side="left", padx=(24, 8))
cores_menu = ctk.CTkOptionMenu(cores_row, values=cores_values,
                                variable=cores_var, width=220, state="disabled")
cores_menu.pack(side="left")
ToolTip(cores_menu, "Number of CPU cores for parallel processing.\nMore cores = faster but heavier system load.")

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
        cores_sel = cores_var.get()
        if cores_sel.startswith("Max"):
            jobs = str(max_cores)
        else:
            jobs = cores_sel
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
      PARALLEL_JOBS)       PARALLEL_JOBS="$value" ;;
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

update_progress_bar() {
  local processed_files="$1"
  local total_files="$2"
  local color="$3"
  local current_file="$4"

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

  # --- Determine destination path (always .wav) ---
  local rel_path="${file#$SOURCE_DIR/}"
  local dest_file_wav="$DEST_DIR/${rel_path%.*}.wav"
  local dest_dir
  dest_dir=$(dirname "$dest_file_wav")
  mkdir -p "$dest_dir" >/dev/null 2>&1

  # --- Skip logic: if destination exists, is valid, and not in force mode ---
  if [ "$FORCE_MODE" != "true" ] && [ -f "$dest_file_wav" ]; then
    if validate_output "$dest_file_wav" >/dev/null 2>&1; then
      log "Output file '$dest_file_wav' already exists and is valid, skipping..." "WARN" "$C_YELLOW"
      echo "skipped"
      return
    else
      log "Output file '$dest_file_wav' exists but is invalid, re-converting..." "WARN" "$C_YELLOW"
    fi
  fi

  # --- Pass 1: Measure loudness ---
  local measured_values
  if ! measured_values=$(measure_loudness "$file"); then
    log "Loudness measurement failed for $file, skipping" "ERROR" "$C_RED"
    echo "failed"
    return
  fi

  local input_i input_tp input_lra input_thresh target_offset
  IFS=':' read -r input_i input_tp input_lra input_thresh target_offset <<< "$measured_values"

  log "Measured loudness for $(basename "$file"): I=${input_i} LUFS, TP=${input_tp} dBTP" "INFO" "$C_BLUE"

  # --- Pass 2: Convert with normalization ---
  local loudnorm_filter="loudnorm=I=${TARGET_LUFS}:TP=${TARGET_TP}:LRA=11:measured_I=${input_i}:measured_TP=${input_tp}:measured_LRA=${input_lra}:measured_thresh=${input_thresh}:offset=${target_offset}:linear=true"

  local ffmpeg_output
  local sample_fmt="s16"
  if [ "$TARGET_BIT_DEPTH" = "24" ]; then
    sample_fmt="s32"
  fi
  if ffmpeg_output=$(ffmpeg -i "$file" -af "$loudnorm_filter" -ar "$TARGET_SAMPLE_RATE" -sample_fmt "$sample_fmt" -ac "$TARGET_CHANNELS" -c:a "$TARGET_CODEC" -y "$dest_file_wav" 2>&1); then
    touch -r "$file" "$dest_file_wav" >/dev/null 2>&1
    # Validate the output
    if validate_output "$dest_file_wav"; then
      log "Converted $file to $dest_file_wav" "INFO" "$C_GREEN"
      echo "converted"
    else
      log "Converted $file but validation failed, deleting bad output" "ERROR" "$C_RED"
      rm -f "$dest_file_wav"
      echo "failed"
    fi
  else
    log "Failed to convert $file to $dest_file_wav" "ERROR" "$C_RED"
    log "ffmpeg output:\n$ffmpeg_output" "ERROR" "$C_RED"
    rm -f "$dest_file_wav"
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

  # Print initial empty lines for progress bar
  echo "" >&2
  echo "" >&2

  # --- Process files ---
  if [ "$PARALLEL_JOBS" -le 1 ]; then
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
      if [ "$active_jobs" -ge "$PARALLEL_JOBS" ]; then
        wait -n 2>/dev/null || true
        active_jobs=$((active_jobs - 1))
        # Update progress based on completed result files
        local completed
        completed=$(find "$results_dir" -maxdepth 1 -type f | wc -l)
        update_progress_bar "$completed" "$total_files" "$C_YELLOW" "$PARALLEL_JOBS parallel workers"
      fi
    done

    # Wait for all remaining jobs
    wait || true

    # Final progress update
    update_progress_bar "$total_files" "$total_files" "$C_YELLOW" "$PARALLEL_JOBS parallel workers"

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

  # Move cursor to the next line
  echo "" >&2

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
