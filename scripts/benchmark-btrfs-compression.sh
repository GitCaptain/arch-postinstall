#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

RUNS=10
WRITE_RUNS=10
SOURCE=""
WORK_PARENT=""
KEEP_TEMP=0
THREAD_POOL_SPECS=("default" "auto" "all")
LEVELS=()

error_handler() {
  local rc=$?
  printf '\nERROR: command failed (exit %d)\n' "$rc" >&2
  printf '  line: %s\n' "${BASH_LINENO[0]:-unknown}" >&2
  printf '  command: %s\n' "$BASH_COMMAND" >&2
  exit "$rc"
}
trap error_handler ERR

usage() {
  cat <<'EOF'
Usage:
  ./benchmark-btrfs-compression.sh [options] [LEVEL ...]

Default synthetic corpus:
  ~246 MiB of small/medium/large files containing:
    - highly compressible structured data
    - medium-compressibility mixed data
    - incompressible random data

Default compression variants:
  none zstd:1 zstd:3 zstd:5 zstd:8

Default thread pools:
  default, auto, all

Where:
  default = min(nproc+2, 8)
  auto    = max(default, ceil(nproc/2))
  all     = nproc

On a 32-thread CPU that means:
  8, 16, 32

Options:
  --source PATH              Use your own file/directory instead.
  --runs N                   Defrag/read runs per compression level (default: 10).
  --write-runs N             Real-write runs per pool+level pair (default: 10).

  --thread-pools SPEC...     Thread pools to benchmark.
                             SPEC may be:
                               default
                               auto
                               all
                               positive integer
                             Values are read until the next option or compression
                             level. Example:
                               --thread-pools 8 16 32
                               --thread-pools default auto all

  --work-parent PATH         Temporary parent directory; must be on Btrfs.
  --keep-temp                Keep benchmark files after exit.
  -h, --help                 Show help.

Examples:
  ./benchmark-btrfs-compression.sh

  ./benchmark-btrfs-compression.sh \
    --thread-pools 8 16 32 \
    -5 -3 -1 1 3

  ./benchmark-btrfs-compression.sh \
    --thread-pools default auto all \
    --write-runs 15 \
    -3 -1 1 3

The benchmark measures:

  1. Forced defrag/recompression cost per compression level.
  2. Physical size after forced compression.
  3. Cold sequential read time per compression level.
  4. REAL buffered-write throughput for every:
         thread_pool x compression level
     combination.

Real-write methodology:
  - source is staged in /dev/shm when enough RAM is available;
  - Btrfs is temporarily remounted for each pool/level pair;
  - the whole corpus is copied normally;
  - no per-file fsync/sync;
  - exactly one `sync -f DEST` after the whole corpus;
  - timing includes that final flush.

sudo is used only for:
  - temporary Btrfs remounts;
  - compsize where TREE_SEARCH_V2 requires privileges;
  - /proc/sys/vm/drop_caches.

The original Btrfs compression/thread_pool behaviour is restored on exit.
EOF
}
while (($#)); do
  case "$1" in
    --source)
      (($# >= 2)) || { echo "--source requires PATH" >&2; exit 2; }
      SOURCE="$2"
      shift 2
      ;;
    --runs)
      (($# >= 2)) || { echo "--runs requires N" >&2; exit 2; }
      RUNS="$2"
      shift 2
      ;;
    --write-runs)
      (($# >= 2)) || { echo "--write-runs requires N" >&2; exit 2; }
      WRITE_RUNS="$2"
      shift 2
      ;;
    --thread-pools)
      shift
      THREAD_POOL_SPECS=()

      while (($#)); do
        case "$1" in
          --*)
            break
            ;;
          -[0-9]*)
            # Negative numeric arguments are Zstd levels, not thread pools.
            break
            ;;
          default|auto|all)
            THREAD_POOL_SPECS+=("$1")
            shift
            ;;
          *)
            if [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
              THREAD_POOL_SPECS+=("$1")
              shift
            else
              break
            fi
            ;;
        esac
      done

      ((${#THREAD_POOL_SPECS[@]})) || {
        echo "--thread-pools requires at least one of: default auto all N" >&2
        exit 2
      }
      ;;
    --work-parent)
      (($# >= 2)) || { echo "--work-parent requires PATH" >&2; exit 2; }
      WORK_PARENT="$2"
      shift 2
      ;;
    --keep-temp)
      KEEP_TEMP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^-?[0-9]+$ ]]; then
        LEVELS+=("$1")
        shift
      elif [[ -z "$SOURCE" && -e "$1" ]]; then
        # Backward compatibility with older versions:
        #   benchmark-btrfs-compression.sh /some/path
        SOURCE="$1"
        shift
      else
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

((${#LEVELS[@]})) || LEVELS=(1 3 5 8)

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || {
  echo "Invalid --runs value: $RUNS" >&2
  exit 2
}

[[ "$WRITE_RUNS" =~ ^[1-9][0-9]*$ ]] || {
  echo "Invalid --write-runs value: $WRITE_RUNS" >&2
  exit 2
}

if [[ -n "$SOURCE" && ! -e "$SOURCE" ]]; then
  echo "Source does not exist: $SOURCE" >&2
  exit 1
fi

missing=()
for cmd in \
  awk btrfs chattr compsize cp date df du find findmnt grep head mktemp mount \
  nproc realpath shuf sort stat sync tar tee wc
do
  command -v "$cmd" >/dev/null || missing+=("$cmd")
done

if ((${#missing[@]})); then
  printf 'Missing required command(s): %s\n' "${missing[*]}" >&2

  if printf '%s\n' "${missing[@]}" | grep -qx compsize; then
    printf 'Install compsize with:\n  sudo pacman -S compsize\n' >&2
  fi

  if printf '%s\n' "${missing[@]}" | grep -qx chattr; then
    printf 'Install chattr with:\n  sudo pacman -S e2fsprogs\n' >&2
  fi

  exit 1
fi

for level in "${LEVELS[@]}"; do
  [[ "$level" =~ ^-?[0-9]+$ ]] || {
    echo "Invalid Zstd level: $level" >&2
    exit 2
  }

  if ((level == 0 || level < -15 || level > 15)); then
    echo "Zstd level must be -15..-1 or 1..15: $level" >&2
    exit 2
  fi
done

# Deduplicate levels while preserving order.
DEDUP_LEVELS=()
for level in "${LEVELS[@]}"; do
  found=0

  for existing in "${DEDUP_LEVELS[@]}"; do
    if [[ "$existing" == "$level" ]]; then
      found=1
      break
    fi
  done

  if ((found == 0)); then
    DEDUP_LEVELS+=("$level")
  fi
done
LEVELS=("${DEDUP_LEVELS[@]}")

is_btrfs_path() {
  [[ "$(findmnt -no FSTYPE -T "$1" 2>/dev/null || true)" == "btrfs" ]]
}

choose_work_parent() {
  local candidate

  if [[ -n "$WORK_PARENT" ]]; then
    mkdir -p -- "$WORK_PARENT"

    if ! is_btrfs_path "$WORK_PARENT"; then
      echo "--work-parent is not on Btrfs: $WORK_PARENT" >&2
      exit 1
    fi

    realpath "$WORK_PARENT"
    return
  fi

  for candidate in /tmp /var/tmp; do
    if [[ -d "$candidate" && -w "$candidate" ]] && is_btrfs_path "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  echo "Neither /tmp nor /var/tmp is on Btrfs." >&2
  echo "Use --work-parent PATH pointing to a directory on Btrfs." >&2
  exit 1
}

WORK_PARENT="$(choose_work_parent)"

CPU_COUNT="$(nproc)"

BTRFS_DEFAULT_POOL=$((CPU_COUNT + 2))
if ((BTRFS_DEFAULT_POOL > 8)); then
  BTRFS_DEFAULT_POOL=8
fi

AUTO_THREAD_POOL=$(((CPU_COUNT + 1) / 2))
if ((AUTO_THREAD_POOL < BTRFS_DEFAULT_POOL)); then
  AUTO_THREAD_POOL="$BTRFS_DEFAULT_POOL"
fi

resolve_pool_spec() {
  case "$1" in
    default)
      printf '%s\n' "$BTRFS_DEFAULT_POOL"
      ;;
    auto)
      printf '%s\n' "$AUTO_THREAD_POOL"
      ;;
    all)
      printf '%s\n' "$CPU_COUNT"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

THREAD_POOLS=()
for spec in "${THREAD_POOL_SPECS[@]}"; do
  resolved="$(resolve_pool_spec "$spec")"

  [[ "$resolved" =~ ^[1-9][0-9]*$ ]] || {
    echo "Invalid thread-pool spec: $spec" >&2
    exit 2
  }

  duplicate=0
  for existing in "${THREAD_POOLS[@]}"; do
    if [[ "$existing" == "$resolved" ]]; then
      duplicate=1
      break
    fi
  done

  if ((duplicate == 0)); then
    THREAD_POOLS+=("$resolved")
  fi
done

((${#THREAD_POOLS[@]})) || {
  echo "No thread pools resolved." >&2
  exit 2
}

ORIGINAL_MOUNT_OPTIONS="$(findmnt -no OPTIONS /)"
ORIGINAL_COMPRESSION_OPTION="compress=no"
ORIGINAL_THREAD_POOL="$BTRFS_DEFAULT_POOL"

IFS=',' read -ra MOUNT_OPTIONS_ARRAY <<< "$ORIGINAL_MOUNT_OPTIONS"

for opt in "${MOUNT_OPTIONS_ARRAY[@]}"; do
  case "$opt" in
    compress=*|compress-force=*)
      ORIGINAL_COMPRESSION_OPTION="$opt"
      ;;
    thread_pool=*)
      ORIGINAL_THREAD_POOL="${opt#thread_pool=}"
      ;;
  esac
done

unset MOUNT_OPTIONS_ARRAY opt

WORK_ROOT="$(mktemp -d "$WORK_PARENT/btrfs-compression-bench.XXXXXXXX")"
GENERATED_SOURCE="$WORK_ROOT/generated-source"
PATTERN_FILE="$WORK_ROOT/pattern.bin"
DATA_ROOT="$WORK_ROOT/defrag-datasets"
RESULT_ROOT="$WORK_ROOT/results"
SCRATCH="$WORK_ROOT/rewrite-scratch"
REAL_WRITE_ROOT="$WORK_ROOT/real-write"

mkdir -p "$DATA_ROOT" "$RESULT_ROOT" "$REAL_WRITE_ROOT"

SUDO_READY=0
MOUNT_TUNING_ACTIVE=0
RAM_SOURCE_ROOT=""

ensure_privilege() {
  if ((SUDO_READY == 0)); then
    printf '\nSudo is required only for benchmark-level privileged operations:\n'
    printf '  - temporary Btrfs remounts (compress/thread_pool)\n'
    printf '  - compsize (TREE_SEARCH_V2 metadata access)\n'
    printf '  - /proc/sys/vm/drop_caches\n'
    sudo -v
    SUDO_READY=1
  fi
}

remount_for_benchmark() {
  local compression="$1"
  local pool="$2"

  ensure_privilege

  sudo mount -o \
    "remount,compress=$compression,thread_pool=$pool" /
  MOUNT_TUNING_ACTIVE=1
}

restore_mount_tuning() {
  if ((MOUNT_TUNING_ACTIVE == 0)); then
    return
  fi

  ensure_privilege

  if ! sudo mount -o \
    "remount,$ORIGINAL_COMPRESSION_OPTION,thread_pool=$ORIGINAL_THREAD_POOL" /;
  then
    printf '\nWARNING: could not restore original Btrfs tuning automatically.\n' >&2
    printf 'Run manually:\n' >&2
    printf '  sudo mount -o remount,%s,thread_pool=%s /\n' \
      "$ORIGINAL_COMPRESSION_OPTION" \
      "$ORIGINAL_THREAD_POOL" >&2
    return 1
  fi

  MOUNT_TUNING_ACTIVE=0
}

cleanup() {
  local rc=$?

  trap - EXIT ERR

  restore_mount_tuning || true

  if [[ -n "$RAM_SOURCE_ROOT" && -d "$RAM_SOURCE_ROOT" ]]; then
    rm -rf -- "$RAM_SOURCE_ROOT" 2>/dev/null || true
  fi

  if ((KEEP_TEMP)); then
    printf '\nTemporary benchmark data kept at:\n  %s\n' "$WORK_ROOT" >&2
  else
    rm -rf -- "$WORK_ROOT" 2>/dev/null || true
  fi

  exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! btrfs filesystem defragment --help 2>&1 | grep -q -- '--nocomp'; then
  echo "This benchmark requires btrfs-progs with defragment --nocomp." >&2
  exit 1
fi

if ! btrfs filesystem defragment --help 2>&1 | grep -Eq -- '(^|[[:space:]])-L|--level'; then
  echo "This benchmark requires btrfs-progs with defragment -L/--level." >&2
  exit 1
fi

drop_fs_caches() {
  ensure_privilege
  sync
  printf '3\n' | sudo tee /proc/sys/vm/drop_caches >/dev/null
}

elapsed_ms() {
  local start="$1"
  local end="$2"

  awk -v s="$start" -v e="$end" \
    'BEGIN { printf "%.3f", (e-s)/1000000 }'
}

stats_file() {
  local file="$1"

  sort -n "$file" | awk '
    {
      values[NR]=$1
      sum+=$1
    }

    END {
      if (NR == 0)
        exit 1

      if (NR % 2)
        median=values[(NR+1)/2]
      else
        median=(values[NR/2] + values[NR/2+1]) / 2

      printf "%.3f %.3f %.3f %.3f", \
        sum/NR, median, values[1], values[NR]
    }
  '
}

variant_key() {
  case "$1" in
    none)
      printf 'none'
      ;;
    zstd:-*)
      printf 'zstd_m%s' "${1#zstd:-}"
      ;;
    zstd:*)
      printf 'zstd_%s' "${1#zstd:}"
      ;;
    *)
      return 1
      ;;
  esac
}

make_pattern_file() {
  awk 'BEGIN { for (i=0; i<8192; i++) printf "ts=2026-09-12T03:%02d:%02dZ service=worker-%02d level=INFO request=%08d status=%03d path=/api/item/%05d tenant=%03d message=processed-record-successfully\n", i%60, (i*7)%60, i%32, i%100000000, 200+(i%8), i%10000, i%128 }' \
    > "$PATTERN_FILE"
}

append_pattern_bytes() {
  local dest="$1"
  local bytes="$2"
  local remaining="$bytes"
  local pattern_size

  pattern_size="$(stat -c '%s' "$PATTERN_FILE")"

  while ((remaining > 0)); do
    if ((remaining >= pattern_size)); then
      cat "$PATTERN_FILE" >> "$dest"
      remaining=$((remaining - pattern_size))
    else
      head -c "$remaining" "$PATTERN_FILE" >> "$dest"
      remaining=0
    fi
  done
}

make_compressible_file() {
  local dest="$1"
  local bytes="$2"

  : > "$dest"
  append_pattern_bytes "$dest" "$bytes"
}

make_random_file() {
  local dest="$1"
  local bytes="$2"

  head -c "$bytes" /dev/urandom > "$dest"
}

make_mixed_file() {
  local dest="$1"
  local bytes="$2"
  local remaining="$bytes"
  local block=$((2 * 1024))
  local part=0
  local n

  : > "$dest"

  while ((remaining > 0)); do
    n="$block"

    if ((remaining < n)); then
      n="$remaining"
    fi

    if ((part % 2 == 0)); then
      append_pattern_bytes "$dest" "$n"
    else
      head -c "$n" /dev/urandom >> "$dest"
    fi

    remaining=$((remaining - n))
    part=$((part + 1))
  done
}

set_nocompress_recursive() {
  chattr -R +m -- "$1"
}

clear_nocompress_recursive() {
  chattr -R -m -- "$1"
}

compression_report() {
  ensure_privilege
  sudo compsize -b "$1"
}

assert_uncompressed() {
  local report

  report="$(compression_report "$1")"

  if grep -Eq '^(zstd|zlib|lzo)[[:space:]]' <<< "$report"; then
    printf '\nERROR: uncompressed baseline contains compressed extents:\n' >&2
    printf '%s\n' "$report" >&2
    printf '\nBenchmark aborted instead of reporting invalid data.\n' >&2
    return 1
  fi
}

assert_zstd_present() {
  local path="$1"
  local variant="$2"
  local report

  report="$(compression_report "$path")"

  if ! grep -Eq '^zstd[[:space:]]' <<< "$report"; then
    printf '\nERROR: %s produced no Zstd extents:\n' "$variant" >&2
    printf '%s\n' "$report" >&2
    printf '\nBenchmark aborted instead of reporting invalid data.\n' >&2
    return 1
  fi
}

copy_source_contents() {
  local source="$1"
  local dest="$2"

  if [[ -d "$source" ]]; then
    cp -R --reflink=never -- "$source"/. "$dest"/
  else
    cp --reflink=never -- "$source" "$dest/input"
  fi
}

make_uncompressed_copy() {
  local dest="$1"

  rm -rf -- "$dest"
  mkdir -p -- "$dest"

  chattr +m -- "$dest"
  copy_source_contents "$SOURCE" "$dest"
  set_nocompress_recursive "$dest"

  sync -f "$dest"
}

rewrite_variant() {
  local variant="$1"
  local path="$2"

  if [[ "$variant" == "none" ]]; then
    btrfs filesystem defragment \
      -r -f \
      --nocomp \
      "$path" >/dev/null
  else
    local level="${variant#zstd:}"

    clear_nocompress_recursive "$path"

    btrfs filesystem defragment \
      -r -f \
      -czstd \
      -L "$level" \
      "$path" >/dev/null
  fi
}

tar_read() {
  local path="$1"
  local parent
  local name

  parent="$(dirname -- "$path")"
  name="$(basename -- "$path")"

  tar -cf /dev/null -C "$parent" -- "$name"
}

generate_synthetic_corpus() {
  mkdir -p \
    "$GENERATED_SOURCE/small/compressible" \
    "$GENERATED_SOURCE/small/mixed" \
    "$GENERATED_SOURCE/small/random" \
    "$GENERATED_SOURCE/medium/compressible" \
    "$GENERATED_SOURCE/medium/mixed" \
    "$GENERATED_SOURCE/medium/random" \
    "$GENERATED_SOURCE/large/compressible" \
    "$GENERATED_SOURCE/large/mixed" \
    "$GENERATED_SOURCE/large/random"

  set_nocompress_recursive "$GENERATED_SOURCE"
  make_pattern_file

  printf 'Generating synthetic Btrfs benchmark corpus...\n'

  # 512 files/class * 4 KiB * 3 classes ~= 6 MiB.
  for ((i=0; i<512; i++)); do
    make_compressible_file \
      "$GENERATED_SOURCE/small/compressible/file-$(printf '%04d' "$i").dat" \
      $((4 * 1024))

    make_mixed_file \
      "$GENERATED_SOURCE/small/mixed/file-$(printf '%04d' "$i").dat" \
      $((4 * 1024))

    make_random_file \
      "$GENERATED_SOURCE/small/random/file-$(printf '%04d' "$i").dat" \
      $((4 * 1024))
  done

  # 32 files/class * 512 KiB * 3 classes ~= 48 MiB.
  for ((i=0; i<32; i++)); do
    make_compressible_file \
      "$GENERATED_SOURCE/medium/compressible/file-$(printf '%03d' "$i").dat" \
      $((512 * 1024))

    make_mixed_file \
      "$GENERATED_SOURCE/medium/mixed/file-$(printf '%03d' "$i").dat" \
      $((512 * 1024))

    make_random_file \
      "$GENERATED_SOURCE/medium/random/file-$(printf '%03d' "$i").dat" \
      $((512 * 1024))
  done

  # 4 files/class * 16 MiB * 3 classes ~= 192 MiB.
  for ((i=0; i<4; i++)); do
    make_compressible_file \
      "$GENERATED_SOURCE/large/compressible/file-$(printf '%02d' "$i").dat" \
      $((16 * 1024 * 1024))

    make_mixed_file \
      "$GENERATED_SOURCE/large/mixed/file-$(printf '%02d' "$i").dat" \
      $((16 * 1024 * 1024))

    make_random_file \
      "$GENERATED_SOURCE/large/random/file-$(printf '%02d' "$i").dat" \
      $((16 * 1024 * 1024))
  done

  sync -f "$GENERATED_SOURCE"
  assert_uncompressed "$GENERATED_SOURCE"

  SOURCE="$GENERATED_SOURCE"

  local apparent_bytes
  local file_count

  apparent_bytes="$(du -sb "$SOURCE" | awk '{print $1}')"
  file_count="$(find "$SOURCE" -type f | wc -l)"

  printf 'Generated %s files, %.1f MiB apparent data.\n' \
    "$file_count" \
    "$(awk -v b="$apparent_bytes" \
      'BEGIN { printf "%.1f", b/1024/1024 }')"
}

stage_real_write_source() {
  local source_bytes
  local shm_avail
  local required

  source_bytes="$(du -sb "$SOURCE" | awk '{print $1}')"

  if [[ -d /dev/shm && -w /dev/shm ]]; then
    shm_avail="$(
      df -B1 --output=avail /dev/shm |
        tail -n 1 |
        tr -d '[:space:]'
    )"

    required=$((source_bytes + source_bytes / 4))

    if [[ "$shm_avail" =~ ^[0-9]+$ ]] && ((shm_avail > required)); then
      RAM_SOURCE_ROOT="$(mktemp -d /dev/shm/btrfs-write-source.XXXXXXXX)"

      printf '\nStaging %.1f MiB source in /dev/shm for real-write tests...\n' \
        "$(awk -v b="$source_bytes" \
          'BEGIN { printf "%.1f", b/1024/1024 }')"

      copy_source_contents "$SOURCE" "$RAM_SOURCE_ROOT"
      REAL_WRITE_SOURCE="$RAM_SOURCE_ROOT"
      return
    fi
  fi

  REAL_WRITE_SOURCE="$SOURCE"

  printf '\nWARNING: insufficient /dev/shm space.\n' >&2
  printf 'Real-write tests will also include source reads from %s.\n' \
    "$(findmnt -no FSTYPE -T "$SOURCE")" >&2
}

real_write_benchmark() {
  local source_bytes
  local round
  local variant
  local pool
  local key
  local pair_key
  local dest
  local result
  local start
  local end
  local ms
  local mib_s

  source_bytes="$(du -sb "$SOURCE" | awk '{print $1}')"

  stage_real_write_source

  printf '\n== Real buffered-write benchmark ==\n'
  printf 'One sync -f after the WHOLE corpus; no per-file flushes.\n'
  printf 'Thread pools: %s\n' "${THREAD_POOLS[*]}"
  printf 'Compression variants: %s\n' "${VARIANTS[*]}"

  for pool in "${THREAD_POOLS[@]}"; do
    printf '\n  thread_pool=%s\n' "$pool"

    for ((round=1; round<=WRITE_RUNS; round++)); do
      printf '    round %d/%d\n' "$round" "$WRITE_RUNS"

      mapfile -t ORDER < <(printf '%s\n' "${VARIANTS[@]}" | shuf)

      for variant in "${ORDER[@]}"; do
        key="$(variant_key "$variant")"
        pair_key="p${pool}-${key}"
        dest="$REAL_WRITE_ROOT/$pair_key"
        result="$RESULT_ROOT/real-write-$pair_key.txt"

        rm -rf -- "$dest"
        mkdir -p -- "$dest"
        chattr -m -- "$dest" 2>/dev/null || true

        if [[ "$variant" == "none" ]]; then
          remount_for_benchmark "no" "$pool"
        else
          remount_for_benchmark "$variant" "$pool"
        fi

        drop_fs_caches

        start="$(date +%s%N)"
        copy_source_contents "$REAL_WRITE_SOURCE" "$dest"
        sync -f "$dest"
        end="$(date +%s%N)"

        ms="$(elapsed_ms "$start" "$end")"
        printf '%s\n' "$ms" >> "$result"

        if [[ "$variant" == "none" ]]; then
          assert_uncompressed "$dest"
        else
          assert_zstd_present "$dest" "$variant"
        fi

        mib_s="$(
          awk -v b="$source_bytes" -v ms="$ms" \
            'BEGIN {
              if (ms <= 0)
                print "inf"
              else
                printf "%.1f", (b/1024/1024)/(ms/1000)
            }'
        )"

        printf '      %-10s %10.3f ms  %8s MiB/s\n' \
          "$variant" "$ms" "$mib_s"
      done
    done
  done

  restore_mount_tuning
}
if [[ -z "$SOURCE" ]]; then
  generate_synthetic_corpus
else
  SOURCE="$(realpath "$SOURCE")"
fi

VARIANTS=("none")
for level in "${LEVELS[@]}"; do
  VARIANTS+=("zstd:$level")
done

printf '\nSource: %s\n' "$SOURCE"
printf 'Source filesystem: %s\n' "$(findmnt -no FSTYPE -T "$SOURCE")"
printf 'Temporary workspace: %s\n' "$WORK_ROOT"
printf 'Defrag/read runs per variant: %d\n' "$RUNS"
printf 'Real-write runs per variant: %d\n' "$WRITE_RUNS"
printf 'CPU count: %d\n' "$CPU_COUNT"
printf 'Thread pools selected: %s\n' "${THREAD_POOLS[*]}"
printf '  Btrfs default formula: %s\n' "$BTRFS_DEFAULT_POOL"
printf '  auto formula:          %s\n' "$AUTO_THREAD_POOL"
printf '  all CPUs:              %s\n' "$CPU_COUNT"
printf 'Original root options: %s\n' "$ORIGINAL_MOUNT_OPTIONS"
printf 'Variants: %s\n' "${VARIANTS[*]}"

cat <<'EOF'

NOTE:
  * mount options such as compress/thread_pool are filesystem-wide in Btrfs;
  * the script temporarily changes them and restores the original behaviour;
  * variant order is randomized each round;
  * drop_caches is global and may temporarily slow other applications.
EOF

# v8: Defrag/read sections are compression-level tests, not thread-pool tests.
# Keep them on the Btrfs default pool; thread-pool comparisons happen in the
# normal real-write matrix below.
ensure_privilege
sudo mount -o \
  "remount,$ORIGINAL_COMPRESSION_OPTION,thread_pool=$BTRFS_DEFAULT_POOL" /
MOUNT_TUNING_ACTIVE=1

printf '\n== Forced defrag/recompression benchmark ==\n'

for ((round=1; round<=RUNS; round++)); do
  printf '  round %d/%d\n' "$round" "$RUNS"

  mapfile -t ORDER < <(printf '%s\n' "${VARIANTS[@]}" | shuf)

  for variant in "${ORDER[@]}"; do
    key="$(variant_key "$variant")"
    result="$RESULT_ROOT/rewrite-$key.txt"

    make_uncompressed_copy "$SCRATCH"
    assert_uncompressed "$SCRATCH"

    drop_fs_caches

    start="$(date +%s%N)"
    rewrite_variant "$variant" "$SCRATCH"
    sync -f "$SCRATCH"
    end="$(date +%s%N)"

    if [[ "$variant" == "none" ]]; then
      assert_uncompressed "$SCRATCH"
    else
      assert_zstd_present "$SCRATCH" "$variant"
    fi

    ms="$(elapsed_ms "$start" "$end")"
    printf '%s\n' "$ms" >> "$result"

    printf '    %-10s %10.3f ms\n' "$variant" "$ms"
  done
done

printf '\n== Preparing forced-compression datasets ==\n'

for variant in "${VARIANTS[@]}"; do
  key="$(variant_key "$variant")"
  path="$DATA_ROOT/$key"

  printf '  %-10s ... ' "$variant"

  make_uncompressed_copy "$path"
  assert_uncompressed "$path"

  if [[ "$variant" != "none" ]]; then
    rewrite_variant "$variant" "$path"
    sync -f "$path"
    assert_zstd_present "$path" "$variant"
  fi

  printf 'OK\n'
done

printf '\n== Forced-compression physical size ==\n'

for variant in "${VARIANTS[@]}"; do
  key="$(variant_key "$variant")"
  path="$DATA_ROOT/$key"
  report_file="$RESULT_ROOT/compsize-$key.txt"

  printf '\n[%s]\n' "$variant"
  compression_report "$path" | tee "$report_file"
done

real_write_benchmark

printf '\n== Cold sequential read benchmark ==\n'

for ((round=1; round<=RUNS; round++)); do
  printf '  round %d/%d\n' "$round" "$RUNS"

  mapfile -t ORDER < <(printf '%s\n' "${VARIANTS[@]}" | shuf)

  for variant in "${ORDER[@]}"; do
    key="$(variant_key "$variant")"
    path="$DATA_ROOT/$key"
    result="$RESULT_ROOT/read-$key.txt"

    drop_fs_caches

    start="$(date +%s%N)"
    tar_read "$path"
    end="$(date +%s%N)"

    ms="$(elapsed_ms "$start" "$end")"
    printf '%s\n' "$ms" >> "$result"

    printf '    %-10s %10.3f ms\n' "$variant" "$ms"
  done
done

printf '\n== Summary: compression characteristics ==\n'

printf '%-10s | %-11s | %-9s | %-34s | %-34s\n' \
  'variant' \
  'disk MiB' \
  'ratio' \
  'defrag ms mean/med/min/max' \
  'read ms mean/med/min/max'

printf '%s\n' \
  '-----------+-------------+-----------+------------------------------------+------------------------------------'

for variant in "${VARIANTS[@]}"; do
  key="$(variant_key "$variant")"

  read -r rw_mean rw_median rw_min rw_max \
    <<< "$(stats_file "$RESULT_ROOT/rewrite-$key.txt")"

  read -r rd_mean rd_median rd_min rd_max \
    <<< "$(stats_file "$RESULT_ROOT/read-$key.txt")"

  read -r disk_bytes uncomp_bytes \
    <<< "$(
      awk '$1=="TOTAL" {print $3, $4; exit}' \
        "$RESULT_ROOT/compsize-$key.txt"
    )"

  disk_mib="$(
    awk -v b="$disk_bytes" \
      'BEGIN { printf "%.1f", b/1024/1024 }'
  )"

  ratio="$(
    awk -v d="$disk_bytes" -v u="$uncomp_bytes" \
      'BEGIN {
        if (u == 0)
          print "n/a"
        else
          printf "%.1f%%", 100*d/u
      }'
  )"

  printf '%-10s | %9s M | %8s | %6.1f/%6.1f/%6.1f/%6.1f | %6.1f/%6.1f/%6.1f/%6.1f\n' \
    "$variant" \
    "$disk_mib" \
    "$ratio" \
    "$rw_mean" "$rw_median" "$rw_min" "$rw_max" \
    "$rd_mean" "$rd_median" "$rd_min" "$rd_max"
done

printf '\n== Summary: REAL write matrix ==\n'
printf '%-11s | %-10s | %-12s | %-12s | %-12s\n' \
  'thread_pool' \
  'variant' \
  'median ms' \
  'MiB/s' \
  'vs none'

printf '%s\n' \
  '------------+------------+--------------+--------------+-------------'

SOURCE_BYTES="$(du -sb "$SOURCE" | awk '{print $1}')"

for pool in "${THREAD_POOLS[@]}"; do
  none_key="p${pool}-none"

  read -r none_mean none_median none_min none_max \
    <<< "$(stats_file "$RESULT_ROOT/real-write-$none_key.txt")"

  for variant in "${VARIANTS[@]}"; do
    key="$(variant_key "$variant")"
    pair_key="p${pool}-${key}"

    read -r wr_mean wr_median wr_min wr_max \
      <<< "$(stats_file "$RESULT_ROOT/real-write-$pair_key.txt")"

    write_mib_s="$(
      awk -v b="$SOURCE_BYTES" -v ms="$wr_median" \
        'BEGIN {
          if (ms <= 0)
            print "inf"
          else
            printf "%.1f", (b/1024/1024)/(ms/1000)
        }'
    )"

    vs_none="$(
      awk -v base="$none_median" -v val="$wr_median" \
        'BEGIN {
          if (base <= 0)
            print "n/a"
          else
            printf "%+.1f%%", 100*(val-base)/base
        }'
    )"

    printf '%-11s | %-10s | %10.1f ms | %10s | %10s\n' \
      "$pool" \
      "$variant" \
      "$wr_median" \
      "$write_mib_s" \
      "$vs_none"
  done
done

printf '\n== Best pool per compression level ==\n'
printf '%-10s | %-11s | %-12s | %-12s\n' \
  'variant' \
  'best pool' \
  'median ms' \
  'MiB/s'

printf '%s\n' \
  '-----------+-------------+--------------+-------------'

for variant in "${VARIANTS[@]}"; do
  key="$(variant_key "$variant")"
  best_pool=""
  best_median=""

  for pool in "${THREAD_POOLS[@]}"; do
    pair_key="p${pool}-${key}"

    read -r _mean median _min _max \
      <<< "$(stats_file "$RESULT_ROOT/real-write-$pair_key.txt")"

    if [[ -z "$best_median" ]] || awk -v a="$median" -v b="$best_median" 'BEGIN { exit !(a < b) }'; then
      best_median="$median"
      best_pool="$pool"
    fi
  done

  best_mib_s="$(
    awk -v b="$SOURCE_BYTES" -v ms="$best_median" \
      'BEGIN {
        if (ms <= 0)
          print "inf"
        else
          printf "%.1f", (b/1024/1024)/(ms/1000)
      }'
  )"

  printf '%-10s | %-11s | %10.1f ms | %10s\n' \
    "$variant" \
    "$best_pool" \
    "$best_median" \
    "$best_mib_s"
done

cat <<'EOF'

Interpretation:
  - Use the REAL write matrix to choose thread_pool and compression together.
  - Compare each compressed row against `none` for the SAME thread_pool.
  - "Best pool per compression level" is useful, but prefer a smaller pool if
    performance differences are within normal run-to-run noise.
  - Forced-defrag cost is algorithmic/recompression cost, not normal write
    latency.
EOF

restore_mount_tuning
