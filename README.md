# Music Converter

Batch-converts audio files to **16-bit / 44.1 kHz / stereo WAV** with **loudness normalization** — the universal format supported by CDJs, car stereos, and virtually all consumer audio devices. All tracks are normalized to a consistent loudness level so you never have to ride the volume knob between songs.

## Prerequisites

- **ffmpeg** (with ffprobe) — install via your package manager:
  ```bash
  sudo apt install ffmpeg    # Debian/Ubuntu
  sudo pacman -S ffmpeg      # Arch
  brew install ffmpeg         # macOS
  ```
- **zenity** (optional, for GUI mode) — install via your package manager:
  ```bash
  sudo apt install zenity    # Debian/Ubuntu
  sudo pacman -S zenity      # Arch
  brew install zenity         # macOS
  ```

## Usage

### GUI mode (no arguments)

```bash
./convert.sh
```

When launched without any arguments, a graphical wizard (powered by Zenity) guides you through the configuration:

1. **Source directory** — pick the folder containing your audio files
2. **Destination directory** — pick where converted files will be saved
3. **Settings** — configure target loudness, true peak, sample rate, bit depth, and force mode via dropdown menus with inline descriptions. Recommended values are pre-selected.
4. **Confirmation** — review all settings before starting

Cancelling any dialog exits gracefully.

### CLI mode

```bash
./convert.sh -s <source_dir> -d <dest_dir> [-l <log_file>] [--force]
```

### Options

| Flag | Description |
|---|---|
| `-s`, `--source` | Source directory containing audio files (required) |
| `-d`, `--destination` | Destination directory for converted WAV files (required) |
| `-l`, `--log-file` | Custom log file path (default: `<dest_dir>/conversion_YYYYMMDD_HHMMSS.log`) |
| `-f`, `--force` | Re-convert all files, even if valid output already exists |
| `-h`, `--help` | Display help message |

### Examples

```bash
# Basic conversion
./convert.sh -s ~/Music/Playlists -d ~/Music/Converted

# Force re-conversion of everything
./convert.sh -s ~/Music/Playlists -d ~/Music/Converted --force

# Custom log file
./convert.sh -s ~/Music/Playlists -d ~/Music/Converted -l ~/conversion.log
```

## Target Output Format

All output files are WAV with these exact parameters:

| Property | Value |
|---|---|
| Codec | `pcm_s16le` (16-bit signed little-endian PCM) |
| Sample rate | 44100 Hz |
| Bit depth | 16-bit |
| Channels | 2 (stereo) |
| Loudness | -11 LUFS integrated, -1 dBTP true peak |

**Why this format?** 24-bit and high sample rate WAV files are rejected by many CDJs (especially older Pioneer models), car stereos, portable players, and other consumer devices. 16-bit/44.1kHz is CD-quality and universally supported.

## Loudness Normalization

All files are normalized to **-11 LUFS** using ffmpeg's `loudnorm` filter with a **two-pass** approach:

1. **Pass 1 (measure)**: Analyzes the entire file to measure integrated loudness, true peak, and loudness range
2. **Pass 2 (apply)**: Applies precise normalization using the measured values with `linear=true` (simple gain when possible, avoiding dynamic compression artifacts)

| Parameter | Value | Rationale |
|---|---|---|
| Target loudness | -11 LUFS | Hotter than streaming (-14), good for club/car playback |
| True peak limit | -1 dBTP | Prevents clipping with a small safety margin |
| Mode | linear=true | Prefers simple gain over dynamic compression |

**Why -11 LUFS?** Streaming services target -14 LUFS, but for DJ and car use a hotter level gives a better baseline without requiring the volume knob to be maxed out. The true peak limiter prevents digital clipping.

**Note**: Two-pass normalization takes roughly 2x longer than a simple conversion since each file is read twice, but the result is significantly more accurate than single-pass.

## Behavior by File Type

| Source format | Behavior |
|---|---|
| **WAV** | Converted through ffmpeg (resampled + normalized) |
| **FLAC** | Converted through ffmpeg |
| **MP3** | Converted through ffmpeg |
| **AIF / AIFF** | Converted through ffmpeg |
| **M4A** | Converted through ffmpeg |

All files go through the two-pass loudnorm pipeline regardless of source format, ensuring consistent loudness across your entire library. Every output file is validated with `ffprobe` after conversion. Files that fail validation are deleted and reported.

## Skip Logic

- If the destination file already exists **and** passes format validation, it is skipped
- Use `--force` to override this and re-convert everything
- If the destination exists but has the wrong format (e.g., from a previous 24-bit run), it is automatically re-converted

## Directory Structure

The source directory structure is fully preserved in the destination. For example:

```
Source:       ~/Music/Playlists/House/track.flac
Destination:  ~/Music/Converted/House/track.wav
```

## Log File

The log file (auto-created in the destination directory unless overridden) contains:

- Timestamped entries for every file processed
- Errors with ffmpeg output for failed conversions
- A final **Conversion Report** section with:
  - Total files processed, converted, copied, skipped, and failed
  - Detailed info for each failed file (source path and format info from ffprobe)
