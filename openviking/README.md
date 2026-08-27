# OpenViking

[OpenViking](https://github.com/volcengine/OpenViking) is a context database for AI
agents — it unifies agent memory, knowledge RAG and skills behind a `viking://`
virtual filesystem. This instance is configured with **Gemini embedding 2** for
vectors and a **LiteLLM** route for the VLM.

## Setup

```bash
cp .env.example .env
$EDITOR .env                       # GOOGLE_API_KEY + OPENVIKING_ROOT_API_KEY

mkdir -p data
cp config/ov.conf.example data/ov.conf
```

`data/ov.conf` is the live config. It is intentionally *not* tracked — it lives in
the bind-mounted state directory alongside the workspace and vector index. It
refers to secrets as `${GOOGLE_API_KEY}` / `${OPENVIKING_ROOT_API_KEY}`, which
OpenViking expands from the environment at load time, so nothing sensitive is
written into it.

```bash
../dev up openviking
```

- API + Web Studio: <https://openviking.dev.internal/studio> (or `http://127.0.0.1:1933`)
- Health: `curl http://127.0.0.1:1933/health` → `{"status": "ok"}`

## Model configuration

### Embedding — Gemini embedding 2

```json
"dense": {
  "provider": "gemini",
  "model": "gemini-embedding-2-preview",
  "dimension": 3072
}
```

`gemini-embedding-2-preview` takes up to 8192 input tokens and produces
Matryoshka (MRL) vectors of 1–3072 dimensions. 3072 is the default; 1536 and 768
are the other recommended values and cut index size proportionally.

**Changing `dimension` invalidates the existing index.** Vectors already written
at one width cannot be compared against another, so re-embed by clearing
`data/data/` and re-ingesting.

`query_param` / `document_param` set the Gemini task type per call
(`RETRIEVAL_QUERY` vs `RETRIEVAL_DOCUMENT`), which is what makes asymmetric
retrieval work properly rather than embedding queries and documents identically.

The `gemini` provider needs `google-genai`; the official image already ships it
(its Dockerfile builds with `uv sync --extra bot --extra gemini`), so no custom
image is required.

### VLM — LiteLLM

The VLM generates the L0/L1 semantic summaries during ingestion. It is routed
through LiteLLM specifically so other models can be swapped in without touching
the config shape — change `OV_VLM_MODEL` in `.env`:

| Provider | `OV_VLM_MODEL` | Notes |
|---|---|---|
| Gemini (default) | `gemini/gemini-2.5-flash` | reuses `GOOGLE_API_KEY` |
| Anthropic | `anthropic/claude-sonnet-5` | set `api_key` in `ov.conf` to the Anthropic key |
| OpenAI | `openai/gpt-5` | likewise |
| Ollama | `ollama/llama3.1` | also add `"api_base": "http://host.docker.internal:11434"` |

Verify a Gemini model id is live before the first ingest — a wrong id only
surfaces when something is actually ingested:

```bash
curl -s "https://generativelanguage.googleapis.com/v1beta/models?key=$GOOGLE_API_KEY" \
  | grep -o '"name": "models/[^"]*"'
```

## Storage

Everything persists under `./data` (gitignored):

```
data/ov.conf        live config
data/ovcli.conf     CLI connection settings (optional)
data/data/          workspace: RAGFS content, vector index, sqlite queue
```

Both the vector DB (`backend: local`) and QueueFS (sqlite) are file-based, which
is why this instance does not use the shared Postgres/Valkey stack.

## CLI access

```bash
cat > data/ovcli.conf <<'JSON'
{ "url": "http://localhost:1933", "api_key": "<OPENVIKING_ROOT_API_KEY>" }
JSON

docker compose exec openviking ov ls viking://resources/
```

Or over HTTP:

```bash
curl 'http://127.0.0.1:1933/api/v1/fs/ls?uri=viking://' \
  -H "X-API-Key: $OPENVIKING_ROOT_API_KEY"
```

## Notes

- The image also starts the `vikingbot` gateway by default. It is harmless if
  unused; to run only the HTTP server, override the container command.
- `OPENVIKING_VERSION=latest` is convenient but not reproducible. Pin a release
  tag in `.env` if a restart picking up a new image would be disruptive.
