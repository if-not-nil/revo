#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root_dir/zig-out/bin/revo"

if [ ! -x "$bin" ]; then
  zig build -Drepl=none >/dev/null
fi

for path in "$root_dir"/examples/*.rv; do
  name="$(basename "$path")"
  echo "== ${path#"$root_dir/"} =="

  case "$name" in
    comp.rv|errors.rv)
      "$bin" "$path" || true
      ;;
    tests.rv)
      "$bin" --test "$path"
      ;;
    *)
      timeout -v 2s "$bin" "$path" || rc=$?
      rc="${rc:-0}"
      if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
        exit "$rc"
      fi
      unset rc
      ;;
  esac

  echo
done
