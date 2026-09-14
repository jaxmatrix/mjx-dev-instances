# hermes-local

The **mjx-hermes-agent** checkout at `HERMES_SOURCE_DIR`
(`~/Documents/Projects/mjx-hermes-agent`), installed **on the host** as the
`hermes`, `hermes-agent` and `hermes-acp` commands. No Docker.

[`hermes/`](../hermes/) runs the same tree in a container with a data
directory of its own. This instance instead replaces the machine's stock Hermes
install, and runs against the same `~/.hermes` that install used.

## Setup

```bash
cp .env.example .env
$EDITOR .env                     # source dir, bin dir, optional HERMES_HOME
../dev up hermes-local
```

`./dev up` recognises `KIND=host` in `instance.env` and runs
[`install.sh`](install.sh) instead of Compose. The installer:

1. Runs `uv sync --extra all --locked` into `<source>/venv`: the project installed
   editable, and every dependency hash-verified against `uv.lock`. Python 3.11
   comes from the tree's `.python-version`.
2. Writes the three wrapper scripts into `~/.local/bin`. The first time it
   replaces a wrapper that points elsewhere, it copies the original into
   `replaced-bin/` (gitignored).
3. Syncs bundled skills into `~/.hermes/skills`. Skills you have customised are
   left alone, and a `.no-bundled-skills` marker opts out entirely.
4. Prints `hermes --version`, and warns if something else named `hermes` comes
   earlier on `PATH`.

It is idempotent. The install is editable, so source edits and `git pull`s take
effect the next time you run `hermes`. Re-run `../dev up hermes-local` only when
`uv.lock` changes.

The dashboard SPA (`hermes_cli/web_dist/`) and the terminal UI
(`ui-tui/dist/`) are not prebuilt. Hermes builds each on first use with the
host's Node, which must be ≥ 22.22.

`./dev status` lists this instance as `host`. `down`, `restart`, `logs` and
`pull` do not apply to it and say so.

## Why the venv is inside the source tree

`hermes update`, `hermes doctor` and the lazy dependency installer all hardcode
`PROJECT_ROOT/venv`. A venv anywhere else works only until the first of those
runs, which then builds a second one beside it. The venv leaks into neither
git nor the `hermes/` image build: the tree's `.gitignore` and `.dockerignore`
both exclude `venv/`.

The installer deliberately does not set `UV_NO_CONFIG`, which Hermes's own
installer does. With it set, uv reports this lock as out of date, and that
installer silently falls back to an unverified resolve.

## Data: shared with the stock install

Config, credentials, sessions, memories and `state.db` all stay in `~/.hermes`,
now read and written by the fork. If the fork migrates a schema forward, the
stock install may no longer read that data.

A full copy was taken before the first install, at
`~/.hermes.bak-2026-09-13`. To give the fork a data directory of its own
instead, set `HERMES_HOME` in `.env` and re-run `../dev up hermes-local`; the
wrappers then export it.

## Do not run `hermes update`

It treats `PROJECT_ROOT` as a managed install. Here that is your working
checkout, on a feature branch with uncommitted changes. It autostashes those
changes with `git stash` and updates the tree in place. Update with `git`
yourself, then re-run `../dev up hermes-local` if `uv.lock` moved.

## Uninstall: back to the stock install

```bash
cp replaced-bin/* ~/.local/bin/          # wrappers -> ~/.hermes/hermes-agent again
```

The stock checkout at `~/.hermes/hermes-agent` is never touched, so this alone
restores the old commands. Restoring the data as well is a separate step, and it
discards everything written since the backup:

```bash
rm -rf ~/.hermes && cp -a ~/.hermes.bak-2026-09-13 ~/.hermes
```
