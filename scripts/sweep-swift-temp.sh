#!/bin/zsh -f
# Removes the temporary folders the Swift compiler driver leaves behind.
#
# Every swift-driver instance (each `swift build`, `swift test`, and every
# compile SourceKit-LSP runs for an editor) creates TemporaryDirectory.XXXXXX
# in the user temp dir, drops a `.keep-directory` marker in it, sometimes
# writes `supplementaryOutputs-N` file maps into it, and never removes it
# (swiftlang/swift-driver#1720: ArgsResolver creates the folder with
# removeTreeOnDeinit false). A few land per build, so the folder count grows
# without bound on a busy machine.
#
# Usage: scripts/sweep-swift-temp.sh [--dry-run | --list]
#   --dry-run  print what would be removed and what is left alone, remove nothing
#   --list     print the path of every folder that would be removed, remove nothing
#   DIRECTA_SWIFT_TEMP_DIR overrides the swept directory (for testing the
#   script); the default is `getconf DARWIN_USER_TEMP_DIR`, never $TMPDIR.
#
# Scope: a folder is removed only when all of these hold:
#   - it sits directly in the swept directory and is named TemporaryDirectory.*
#   - it is a real directory, not a symlink
#   - it was last modified more than 60 minutes ago (a folder a running driver
#     is still filling has a fresh modification time)
#   - it is not empty, and every entry is a regular file named `.keep-directory`
#     or `supplementaryOutputs-*`
# Every other TemporaryDirectory.* is left alone, including empty ones: other
# tools share the name, and nothing ties an empty one to the driver.
#
# Output: silent when nothing was removed, one line with the count otherwise.
# Fails (exit 1, message on stderr) when the swept directory is missing or a
# folder in scope cannot be removed. A folder that gains a new entry while the
# sweep runs is left in place and not counted as a failure.
#
# Blind spots: the 60-minute window is judged from the folder's own
# modification time, so a long-lived driver process that writes a new file
# into a folder it created more than an hour earlier could see that folder
# disappear first. Files are removed before the folder, so a folder that gains
# an entry between the check and the removal keeps the new entry but loses the
# old ones.
#
# Speed: one in-process pass (zsh globbing plus the zsh/files builtins), no
# subprocess per folder, so a backlog of tens of thousands of folders is
# cleared in one run.
set -euo pipefail
zmodload -F zsh/files b:rm b:rmdir

mode=sweep
case "${1:-}" in
  "") ;;
  --dry-run) mode=dry-run ;;
  --list) mode=list ;;
  *)
    print -u2 "sweep-swift-temp: unknown argument '$1'; run: scripts/sweep-swift-temp.sh [--dry-run | --list]"
    exit 2
    ;;
esac

if [[ -n "${DIRECTA_SWIFT_TEMP_DIR:-}" ]]; then
  root="$DIRECTA_SWIFT_TEMP_DIR"
  fix="unset DIRECTA_SWIFT_TEMP_DIR or point it at an existing directory"
else
  root="$(getconf DARWIN_USER_TEMP_DIR)"
  fix="run: getconf DARWIN_USER_TEMP_DIR, which should name an existing directory"
fi
root="${root%/}"
if [[ -z "$root" || ! -d "$root" ]]; then
  print -u2 "sweep-swift-temp: the temp directory '$root' does not exist; $fix"
  exit 1
fi

all=("$root"/TemporaryDirectory.*(DN))
real=("$root"/TemporaryDirectory.*(DN/))
aged=("$root"/TemporaryDirectory.*(DN/mm+60))

removable=()
empty=0
other=0
for dir in $aged; do
  entries=("$dir"/*(DN))
  if (( ${#entries} == 0 )); then
    (( ++empty ))
    continue
  fi
  inScope=1
  for entry in $entries; do
    name="${entry:t}"
    if [[ -L "$entry" || ! -f "$entry" ]] || [[ "$name" != .keep-directory && "$name" != supplementaryOutputs-* ]]; then
      inScope=0
      break
    fi
  done
  if (( inScope )); then
    removable+=("$dir")
  else
    (( ++other ))
  fi
done

if [[ "$mode" == list ]]; then
  print -rl -- $removable
  exit 0
fi
if [[ "$mode" == dry-run ]]; then
  print "sweep-swift-temp: $root: ${#removable} of ${#all} TemporaryDirectory.* would be removed"
  print "sweep-swift-temp: left alone: $(( ${#all} - ${#real} )) not a real directory, $(( ${#real} - ${#aged} )) modified within 60 minutes, $empty empty, $other with other contents"
  exit 0
fi

removed=0
failed=()
for dir in $removable; do
  files=("$dir"/*(DN))
  rm -f -- $files 2>/dev/null || true
  if rmdir -- "$dir" 2>/dev/null; then
    (( ++removed ))
    continue
  fi
  [[ -e "$dir" ]] || continue
  for file in $files; do
    if [[ -e "$file" || -L "$file" ]]; then
      failed+=("$dir")
      break
    fi
  done
done

if (( ${#failed} )); then
  print -u2 "sweep-swift-temp: could not remove ${#failed} folder(s) in $root, first: ${failed[1]}; check its permissions with: ls -la ${(q)failed[1]}"
  exit 1
fi
if (( removed )); then
  print "sweep-swift-temp: removed $removed leftover Swift compiler temp folder(s) from $root"
fi
