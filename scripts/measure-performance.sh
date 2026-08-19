#!/bin/zsh

set -euo pipefail

sample_count="${1:-12}"
aegis_pid="${2:-$(pgrep -f '/build/Aegis.app/Contents/MacOS/Aegis' | head -1)}"
history_root="$HOME/.codex/sessions"

if [[ -z "$aegis_pid" ]]; then
    print -u2 "Aegis is not running from the workspace app bundle."
    exit 1
fi

history_files=$(find "$history_root" -type f -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
history_directories=$(find "$history_root" -type d 2>/dev/null | wc -l | tr -d ' ')
history_kib=$(du -sk "$history_root" 2>/dev/null | awk '{ print $1 }')

lsof_output=$(lsof -p "$aegis_pid" 2>/dev/null)
total_descriptors=$(print -r -- "$lsof_output" | awk 'NR > 1 { count++ } END { print count + 0 }')
session_descriptors=$(print -r -- "$lsof_output" | awk '/\/\.codex\/sessions\// { count++ } END { print count + 0 }')
resident_kib=$(ps -p "$aegis_pid" -o rss= | tr -d ' ')

cpu_samples=$(
    top -l "$sample_count" -s 1 -pid "$aegis_pid" -stats pid,cpu,mem,threads,time,command |
        awk -v pid="$aegis_pid" '$1 == pid { print $2 }'
)
average_cpu=$(print -r -- "$cpu_samples" | awk 'NR > 1 { sum += $1; count++ } END { if (count > 0) printf "%.2f", sum / count; else print "n/a" }')

print "pid=$aegis_pid"
print "samples=$sample_count"
print "average_cpu_percent=$average_cpu"
print "resident_memory_kib=$resident_kib"
print "open_descriptors=$total_descriptors"
print "codex_session_descriptors=$session_descriptors"
print "codex_history_files=$history_files"
print "codex_history_directories=$history_directories"
print "codex_history_kib=$history_kib"
