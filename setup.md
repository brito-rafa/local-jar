# Local JAR setup

Local JAR runs models through Kronk and stores its index in a separate DuckDB service. Start with [requirements](#requirements) and [local setup](#local-setup). For OpenAI-compatible model endpoints, use [JAR](https://github.com/brito-rafa/jar).

Run repository commands from the repository root unless noted otherwise. Keep credentials in the ignored `.env`; do not source it as a shell script.

## Requirements

- Go 1.27.3 or newer and a C compiler for the DuckDB Go client. On macOS, use native ARM64 Go and install Apple command-line tools with `xcode-select --install` if needed.
- Docker running with Compose support (Docker Engine on Linux or Docker Desktop on macOS).
- Disk space and an initial internet connection for dependencies, models, native libraries, the container image, and DuckDB extensions.

### Document converters on Linux

On Debian/Ubuntu, install the local converters:

```sh
sudo apt-get install poppler-utils libreoffice-writer wv
```

PDF extraction uses `pdftotext`. Word extraction uses `wvWare` for DOC when available, then headless LibreOffice for DOC/DOCX. LibreOffice alone handles both Word formats. Scanned PDFs without a text layer still need OCR before indexing; empty documents are skipped with a warning.

### Document converters on macOS

LibreOffice is not required for JAR itself. Some very old Word files, including Word 2.0 documents such as `HSM.DOC`, need it because other converters can return binary data or incorrect text.

| Input | Converter | Installation |
| --- | --- | --- |
| TXT | Go file reading | None |
| PDF | Poppler `pdftotext` | `brew install poppler` |
| DOCX and most DOC | macOS `textutil` | Included with macOS |
| Legacy DOC | `wvWare` fallback | `brew install wv` |
| DOC still unreadable after those converters | LibreOffice fallback | `brew install --cask libreoffice` |

JAR runs converters locally. LibreOffice is detected through `soffice` on PATH or its standard macOS application path, and runs headlessly with temporary output and a separate temporary profile. Source documents are unchanged. Extracted text is sent to your configured DuckDB server for storage. Model inference stays on the application machine.

## Local setup

### Quick start

With Go 1.27.3+, a C compiler, and Docker Desktop running (see [Requirements](#requirements)):

```bash
git clone https://github.com/brito-rafa/local-jar.git
cd local-jar
make local-db-up
make index DOCS="/absolute/path/to/your/documents"
make status
make chat-web
```

Replace `DOCS` with one or more **existing directories separated by `;`** containing your PDF, DOC, DOCX, or TXT files. For PDFs, install Poppler with `brew install poppler`; Word converter options are in [Requirements](#requirements). The first run downloads dependencies and models. `make chat` opens the browser at `http://127.0.0.1:18080`.

`make index` fails immediately if `DOCS` is missing, blank, contains an empty list entry, or any entry is nonexistent or a file rather than a directory. `DOCS` has no default; it can also be explicitly exported in your shell. Chat, help, database setup, status, and metadata commands do not require it.

### Database

`make` uses `config/manifests/compose/compose.yaml` with the repository root as the Compose project directory, preserving relative mount paths. Its default project name is `local-jar`, separate from the original `jar` project; existing containers are not moved or restarted.

Make creates `DB_DATA_DIR` automatically if it is missing, including parent directories. Empty paths, existing files, and directories that cannot be created cause setup to fail. `make local-db-up` creates a private, ignored `.env` with a random token and waits for the database health check. The service publishes **127.0.0.1:9494** and bind-mounts the project’s `./data` directory to `/data`, so the database is stored at **`./data/jar.db` on your host**. Its write-ahead log is stored alongside it. `DB_DATA_DIR` can select another host directory. Change `DB_PORT` in `.env` and rerun `make local-db-up` to select a different host port.

```bash
make local-db-logs                    # Follow database logs
make local-db-down                    # Stop the service, preserving its local database file
make local-db-up                      # Start again with stored data intact
```

Do not delete `jar.db` or its WAL unless you intend to erase the index. `.env` contains the authentication token: do not commit it. Keep the same token for both the server and application commands. The default connection is plain HTTP over loopback TCP; access from another machine requires deliberate port/TLS configuration. The single-user token permits SQL access; chat only issues read queries, but it is not a separate server-enforced read-only role.

To choose another directory, set `DB_DATA_DIR=/absolute/path/to/database` in `.env`, or run:

```bash
make local-db-up DB_DATA_DIR="/absolute/path/to/database"
```

Keep the same directory for later database commands. `make local-db-check` creates it if needed without starting Docker. `local-db-init`, `local-db-up`, `local-db-start`, and `local-db-reset` run this check before proceeding. Running Compose directly requires the directory to exist.

### Local database storage

The container mounts `DB_DATA_DIR` (default `./data`) at `/data`; the active database is **`./data/jar.db`**, with any WAL alongside it. Keep using Quack while the server runs; do not open the same file from another DuckDB process. Back up or copy the database only after stopping the server cleanly.

Earlier installations used a named Docker volume. Changing the mount alone does not migrate that database. Stop the service, preserve any pre-existing local `jar.db`, and copy the stopped volume's database and WAL into `./data` before restarting. Keep the old volume until the migrated index is verified. `data/training/` and backups remain local and Git-ignored.

Integration tests must use a separate temporary `DB_DATA_DIR` and port. A different Compose project name alone does not isolate a bind-mounted database.

## Existing indexes and databases

This repository runs local Kronk inference. [JAR](https://github.com/brito-rafa/jar) runs inference against OpenAI-compatible endpoints and contains Kubernetes deployment examples. Neither repository depends on the other.

The split preserves the database schema, chunking, embedding identity, and corpus fingerprint format. An index can be reused only when the local embedding model has the same weights, preprocessing, dimensions, and identity as the model that created it. The default identity remains `bartowski/granite-embedding-278m-multilingual-GGUF:Q8_0`. Chat reads this identity from index metadata and loads that model locally. Changing embedding models requires intentional reindexing.

Existing `.env` files, databases, document collections, model caches, and running containers stay where they are. Set `DB_URL` and `DB_TOKEN` to connect to an existing DuckDB server. For the loopback Compose service use `DB_DISABLE_SSL=true`; set it to `false` for a TLS-enabled endpoint. Direct CLI flags override the environment default, including `-db-disable-ssl=false`.

To reuse an existing database directory with the new Compose project, first stop its owning server cleanly, then explicitly set `DB_DATA_DIR` to that existing directory and preserve its token. Never run two servers against the same database files. Keeping the old server running and pointing this application at its endpoint avoids a file move.

## Indexing performance and batching

### Batch size and queue capacity

The completed-embedding queue defaults to 16 batches, independently of worker concurrency. With batches of 8, it buffers up to 128 completed chunks while inserts run. Additional chunks may be in flight or awaiting an insert. This bounds memory without forcing a single embedding worker to pause after one queued batch. A larger buffer can reduce temporary backpressure; it cannot overcome a sustained database bottleneck.

```bash
# One local embedding worker, 8 chunks per request, 128-chunk queue.
make index DOCS="/path/to/documents" EMBEDDING_WORKERS=1 EMBEDDING_BATCH_SIZE=8 EMBEDDING_BUFFER_BATCHES=16

# Compare larger requests while retaining a 128-chunk queue.
make index DOCS="/path/to/documents" EMBEDDING_WORKERS=1 EMBEDDING_BATCH_SIZE=16 EMBEDDING_BUFFER_BATCHES=8

```

The direct indexer flag is `--embedding-buffer-batches=16`. Set `EMBEDDING_BUFFER_BATCHES=16` in `.env` to persist it. An already unchanged index is reused; add `FORCE_INDEX=true` only when intentionally rebuilding it for a comparison.

### Indexing metrics

Loading reports embedding batch-request latency (average/maximum and failures), insert-call latency, elapsed time, written chunks per second, and result-queue wait summed across workers. Embedding latency includes local model processing and queueing; insert latency includes serialization and source-metadata writes. These are client timings, not GPU kernel timings. Progress is provisional until the transaction commits; a failed load rolls back its writes. Metrics are also printed on failure.

## Chat timing and model metrics

### Client timings

Chat answers include client timing for query embedding, database vector search, total retrieval (including embedding and result preparation), generation across all attempts, citation/grounding validation, and total handling time. The terminal and web interface also report timing for failed queries. Values include network and server waits; total handling excludes HTTP session-lock wait, browser rendering, and response delivery. Retrieval includes its embedding/search substeps and should not be added to them. Answers are buffered for citation validation, so time to first token is not measured.

## Connection and model settings

| Make variable | Default / purpose |
| --- | --- |
| `GO`, `DOCKER` | Executable overrides; defaults to `go`, `docker` |
| `DB_URL` | `quack:127.0.0.1:9494`, adjusted to `DB_PORT` |
| `DB_PORT` | Published host port; default `9494` |
| `DB_DATA_DIR` | Host directory, default `./data`; contains `jar.db`; created by Make if missing |
| `CHAT_PORT` | Local browser chat TCP port; default `18080` |
| `OPEN_BROWSER` | Open the default browser on `make chat`; default `true` |
| `DB_TOKEN` | Token from `.env`, exported to both commands |
| `DB_DISABLE_SSL` | `true` for loopback Compose; `false` for TLS-enabled DuckDB |
| `DOCS` | Semicolon-separated directories to scan recursively; indexing only |
| `DIMENSIONS` | `768`; must match the embedding model output |
| `EMBEDDING_MODEL` | `bartowski/granite-embedding-278m-multilingual-GGUF:Q8_0` |
| `CHAT_MODEL` | `mistralai/Ministral-3-8B-Instruct-2512-GGUF:Q4_K_M` |

Mistral supplies the chat model; IBM supplies the embedding model, converted to GGUF by bartowski. No Qwen model is selected. Kronk keeps model downloads in its usual `~/.kronk` store, and automatically detects Metal support. Model licenses and converter provenance should be reviewed separately.

### Direct commands

Load the generated database token before using Go commands or binaries directly (Make reads `.env` itself):

```bash
export DB_TOKEN="$(sed -n 's/^DB_TOKEN=//p' .env)"

go run ./cmd/jar-index -docs "/path/to/documents" -db-url quack:127.0.0.1:9494
go run ./cmd/jar-index -status -db-url quack:127.0.0.1:9494
go run ./cmd/jar-chat -db-url quack:127.0.0.1:9494
```

Use `make build` for `bin/jar-index` and `bin/jar-chat`, or `make cli-help` for all flags. Old combined-command flags such as `-db` and `-docs` on chat are no longer accepted.

## Browser chat

```bash
make chat-web                         # Open the browser at localhost:18080
make chat-web CHAT_PORT=8081           # Choose another port
make chat-web OPEN_BROWSER=false       # Start without opening a browser
make chat-terminal                    # Use the terminal instead
```

`make chat` and `make run` are aliases for web chat. The existing index must be ready. The interface has a sticky prompt, Tab completion, a compact live vector-search panel, progress spinner, and cited answers. Enter sends a message; Shift+Enter adds a line. Press Ctrl+C in the server terminal to stop it.

Browser tabs share one conversation, search filter, language setting, and latest references. Reloading the page does not clear server history, but does not restore the visible transcript. `/quit` ends the conversation without stopping the web server.

### Network access

The default listener is `127.0.0.1`. For a reverse proxy such as Tailscale Serve, allow its exact public origin:

```bash
make chat-web CHAT_PUBLIC_URL=https://your-machine.your-tailnet.ts.net
```

To accept any hostname on all IPv4 interfaces:

```bash
make chat-web CHAT_HOST=0.0.0.0 CHAT_ALLOW_ANY_HOST=true
```

These settings can also be saved in `.env`. JAR has **no application login**: anyone who can reach an exposed port can use the shared chat and indexed content. Browser same-origin checks remain enabled. These options do not change firewall, router, or Tailscale permissions.

## Multiple document directories

```bash
make index DOCS="/path/to/books;/path/to/conferences;/path/with spaces"
# Or set this in .env (no shell quotes needed in that file):
# DOCS=/path/to/books;/path/to/conferences;/path/with spaces
```

The same list works with `jar-index -docs "/path/one;/path/two"`. Quote the list on the command line so the shell does not interpret semicolons as commands. Whitespace around entries is trimmed; empty entries (including a trailing `;`) are rejected. A literal semicolon in a directory name is not supported. `.env` is read as Make settings; do not source a file containing an unquoted semicolon list as a shell script. For shell exports, use `export DOCS="/path/one;/path/two"`.

Every directory is validated before indexing starts. Roots are scanned recursively in deterministic order using one shared document-worker pool. Duplicate roots and overlapping file paths are read once. In multi-root imports, source labels include each root's directory name to distinguish identical relative filenames; roots with the same basename get a stable hash suffix. Single-root source labels remain unchanged. All roots feed the same deduplicated database index; include the full desired set of roots on each indexing run.

## Deduplication and concurrent indexing

JAR embeds identical passages once while keeping all their source locations. Translations and passages with different wording remain separate. Index updates are transactional: a failed import preserves the previous index.

Indexing processes documents and embedding requests concurrently, then writes results in batches. These are the defaults:

| Setting | Default | Purpose |
| --- | --- | --- |
| `DOCUMENT_WORKERS` | 20 | Documents processed at once |
| `EMBEDDING_WORKERS` | 1 | Concurrent embedding requests |
| `EMBEDDING_BATCH_SIZE` | 8 | Passages per embedding request |
| `EMBEDDING_BUFFER_BATCHES` | 16 | Completed embedding batches buffered independently of worker count |
| `INSERT_BATCH_SIZE` | 128 | Unique passages per database insert |

Override settings when running indexing:

```bash
make index DOCS="/path/to/documents" DOCUMENT_WORKERS=4 EMBEDDING_WORKERS=2
```

Reduce workers if memory usage is high, especially with LibreOffice. More workers do not always mean faster indexing; compare the reported stage timings on your documents. Use `FORCE_INDEX=true` to benchmark an unchanged corpus, with no chat model running at the same time.

## Reset and erase the database

To permanently erase the local database and start with an empty index:

```bash
make local-db-reset CONFIRM=erase
```

Without `CONFIRM=erase`, the command refuses to proceed. Stop indexing and chat first. This deletes only **`jar.db` and `jar.db.wal` inside `DB_DATA_DIR`**, including their stored passages, embeddings, and index metadata, then restarts DuckDB. Training files, backups, source documents, and the rest of `data/` are preserved. Run `make index DOCS="/path/to/documents"` afterwards to rebuild the index.

The token in `.env`, source documents, cached models, training files, and database backups are preserved. This target resets the local Compose service, regardless of a `DB_URL` override; it does not erase an arbitrary remote endpoint. Normal `make local-db-down` preserves data.

## Index status

The [status command](setup.md#database) also displays the configured local database directory and `jar.db` size in bytes and MiB (or reports that the file is missing). These local file details describe `DB_DATA_DIR`, even when `DB_URL` points to a remote server. Status reports readiness, chunk count, embedding identity, dimensions, and completion timestamp in UTC. It does not count source documents or maintain a per-file skip history. Runtime warnings identify skipped files.

## Metadata maintenance

New indexes include this metadata. To add it to an existing index without regenerating embeddings:

```bash
make metadata
```

## Development and validation

```bash
make test
make vet
```

Converter tests skip when their tools are unavailable. Optional database integration tests must use a disposable server with a dedicated temporary database directory and a nondefault port. Do not enable them against a corpus you want to preserve. The catalog, index, and load tests accept `JAR_METADATA_TEST_URL`, `JAR_INDEX_TEST_URL`, and `JAR_LOAD_TEST_URL` respectively and read its token from `DB_TOKEN`. Ordinary tests do not require a running service. The legacy `JAR_TEST_REMOTE` checks hardcode port 9494; leave them disabled for routine validation and never use them against the main database.

Use fake model callbacks and temporary directories for ordinary tests. Do not load models, reindex a personal collection, or mutate a running corpus as part of routine validation.

For an optional local-model check of an English answer with multilingual context:

```bash
JAR_LIVE_CHAT_TEST=1 go test ./pkg/chat -run TestLiveEnglishMultilingualContext -v
```

This opt-in test loads the local chat model; ordinary tests do not.
