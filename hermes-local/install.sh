#!/usr/bin/env bash
# Install the local mjx-hermes-agent checkout as this machine's `hermes`.
#
# Run through `./dev up hermes-local`. Idempotent: re-running re-syncs the venv
# against uv.lock and rewrites the wrappers, which is all an upgrade needs.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -t 1 ]]; then
	B=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; N=$'\e[0m'
else
	B=""; RED=""; GRN=""; YLW=""; N=""
fi

info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
warn() { printf '%s==>%s %s\n' "$YLW" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$N" "$*" >&2; exit 1; }

[[ -f "$HERE/.env" ]] || die "hermes-local/.env is missing. Create it with:
    cp hermes-local/.env.example hermes-local/.env"
set -a; . "$HERE/.env"; set +a

SRC="${HERMES_SOURCE_DIR:?set HERMES_SOURCE_DIR in hermes-local/.env}"
BIN_DIR="${HERMES_BIN_DIR:-$HOME/.local/bin}"

# Wrappers this script replaces are copied here, once, so the previous install
# can be restored by copying them back into BIN_DIR.
REPLACED="$HERE/replaced-bin"

# An inherited PYTHONPATH makes the venv import a different checkout — the same
# guard hermes's own installer and wrappers apply.
unset PYTHONPATH PYTHONHOME VIRTUAL_ENV

[[ -f "$SRC/pyproject.toml" && -f "$SRC/uv.lock" ]] \
	|| die "$SRC is not a hermes-agent checkout (no pyproject.toml or uv.lock)"
command -v uv >/dev/null 2>&1 || die "uv is not installed. Run: sudo pacman -S uv"

# ------------------------------------------------------------------- venv ---

# The venv has to be <source>/venv. `hermes update`, `hermes doctor` and the
# lazy dependency installer all hardcode PROJECT_ROOT/venv, so a venv anywhere
# else works only until the first of those runs.
#
# --locked installs exactly the hash-pinned uv.lock and fails rather than
# re-resolving. Deliberately no UV_NO_CONFIG, which hermes's own installer sets:
# with it, uv reports this lock out of date and that installer silently falls
# back to an unverified resolve.
info "syncing ${B}${SRC}/venv${N} against uv.lock (extra: all)"
(cd "$SRC" && UV_PROJECT_ENVIRONMENT="$SRC/venv" uv sync --extra all --locked) \
	|| die "uv sync failed. If uv.lock is out of date on this branch, run 'uv lock' in $SRC and retry."

# --------------------------------------------------------------- wrappers ---

# Same shape as the wrappers hermes's installer writes: a script rather than a
# symlink, so PYTHONPATH can be cleared before the interpreter starts.
write_wrapper() { # write_wrapper <name> <script> [fixed args...]
	local name="$1" script="$2"; shift 2
	local target="$BIN_DIR/$name" tmp

	if [[ -e "$target" ]] && ! grep -qF "$SRC/" "$target" 2>/dev/null \
	&& [[ ! -e "$REPLACED/$name" ]]; then
		mkdir -p "$REPLACED"
		cp -a "$target" "$REPLACED/$name"
		info "saved the previous ${B}${name}${N} to ${REPLACED}/${name}"
	fi

	tmp="$(mktemp "$BIN_DIR/.$name.XXXXXX")"
	{
		printf '#!/usr/bin/env bash\n'
		printf '# Written by dev_instances/hermes-local/install.sh — runs %s\n' "$SRC"
		printf 'unset PYTHONPATH\nunset PYTHONHOME\n'
		if [[ -n "${HERMES_HOME:-}" ]]; then
			printf 'export HERMES_HOME=%q\n' "$HERMES_HOME"
		fi
		printf 'exec %q %q' "$SRC/venv/bin/python" "$SRC/$script"
		if [[ $# -gt 0 ]]; then
			printf ' %q' "$@"
		fi
		printf ' "$@"\n'
	} > "$tmp"
	chmod 755 "$tmp"
	mv -f "$tmp" "$target"
}

mkdir -p "$BIN_DIR"
info "writing hermes, hermes-agent and hermes-acp into ${B}${BIN_DIR}${N}"
write_wrapper hermes       hermes
write_wrapper hermes-agent run_agent.py
write_wrapper hermes-acp   hermes acp

# ----------------------------------------------------------------- skills ---

# Adds and updates bundled skills in HERMES_HOME/skills, as `hermes update`
# does. It honours the .no-bundled-skills opt-out marker.
info "syncing bundled skills into ${B}${HERMES_HOME:-$HOME/.hermes}/skills${N}"
(cd "$SRC" && "$SRC/venv/bin/python" tools/skills_sync.py) \
	|| warn "skills sync failed; rerun: (cd $SRC && venv/bin/python tools/skills_sync.py)"

# ------------------------------------------------------------------ check ---

resolved="$(command -v hermes || true)"
[[ "$resolved" == "$BIN_DIR/hermes" ]] \
	|| warn "'hermes' on PATH resolves to ${resolved:-nothing}, not $BIN_DIR/hermes"

printf '%s    %s (%s, branch %s)%s\n' "$GRN" \
	"$("$BIN_DIR/hermes" --version 2>&1 | head -1)" "$SRC" \
	"$(git -C "$SRC" branch --show-current 2>/dev/null || echo '?')" "$N"
