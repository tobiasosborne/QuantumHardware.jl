# quantum-hardware — Living Database of Quantum Computing Devices

## What This Is

A comprehensive, public-sources-only database of quantum computing hardware — past, present, and projected — across commercial vendors **and** academic / national-lab experimental testbeds, across every modality. Designed to feed `Sturm.jl`'s `compile(ch, target=…)` and related circuit-viability assessments.

Estimated corpus: **~280 devices** at launch (Apr 2026), growing.

**Source-of-truth:** one TOML file per `DeviceRevision` under `devices/<org>/<slug>.toml`. Git-tracked. PR-friendly.

**Compiled query artefact:** DuckDB (primary) + SQLite (fallback), built from the TOML corpus by `scripts/build_db.jl`. Never hand-edited.

**Julia consumer:** the `QuantumHardware` Julia package in `src/`. `using QuantumHardware; target_spec("ibm-heron-r2")` returns a typed struct. Sturm.jl will depend on this.

**Raw source archives:** every ingested public source (paper PDF, Braket JSON, IBM calibration dump, press release HTML) is saved alongside the DB as `sources/YYYY/MM/DD/<source-slug>.<ext>` with a SHA-256. Provenance records in each device TOML point to both the reference URL AND the local archive. See §DUAL SOURCE-OF-TRUTH below.

## Implementation Principles

These are NON-NEGOTIABLE. Every agent, every session, every commit.

0. **MAINTAIN THE WORKLOG.** Every step, every session: update `WORKLOG.md` with gotchas, schema surprises, source-mismatch discoveries, ingestion quirks, values that disagreed across sources, anything a future agent would wish it knew. This is the project's institutional memory. If you hit something non-obvious, write it down before moving on.

1. **FAIL FAST, FAIL LOUD.** Assertions, not silent returns. Crashes, not corrupted rows. A TOML file that fails schema validation MUST abort the build, not silently produce a partial DB. `error()` with a clear message pointing to the offending file and field.

2. **CORE CHANGES REQUIRE 3+1 AGENTS.** Any change to the schema (`schema/device.schema.json`, `schema/SCHEMA.md`), the Julia types (`src/schema.jl`), the ingestion protocol, or the DB build pipeline requires: 2 proposer subagents (independent designs), 1 implementer, 1 orchestrator/reviewer. Proposers must not see each other's output. The reviewer checks for: (a) backwards-compatibility of the schema, (b) provenance integrity, (c) modality-agnostic coverage, (d) Sturm.jl consumer impact.

3. **GROUND TRUTH = PUBLIC SOURCE.** Every numeric or categorical value in a device TOML must be derivable from a publicly accessible source. Not vendor NDAs. Not leaked calibration. Not "I saw it in a talk once." If a value cannot be pinned to a public source, leave it null. Never fabricate a plausible number.

4. **DUAL SOURCE-OF-TRUTH: REFERENCE + LOCAL ARCHIVE.** For every `Provenance[]` record attached to a field, both MUST exist:
   - `source_url` — canonical public URL / DOI / arXiv id, and
   - `local_path` — datestamped local archive at `sources/YYYY/MM/DD/<slug>.<ext>`, with `sha256` recorded in the provenance record.

   At ingestion time, fetch-and-save is atomic: the raw bytes are saved BEFORE the TOML is written, and the TOML references the stored archive. URLs rot; archives don't. Never delete old archives — longitudinal drift IS the data.

5. **LITERATE CURATION.** Every device TOML carries a top-of-file comment block naming the primary source(s), the ingest method (manual vs. `braket-pull.jl` vs. …), and any judgement calls made (e.g. "IonQ's `#AQ` spec vs qubit count — we record both"). Think of each device file as a little paper.

6. **ANOMALIES ARE DEEP AND INTERLOCKED.** A disagreement between two sources on the same device is never "pick one and move on." Record both values in `Provenance[]`, flag with `conflict: true`, and investigate: vendors sometimes update specs silently after a press release. A conflict is a data point, not a nuisance.

7. **GET FEEDBACK FAST.** Run `julia --project test/runtests.jl` or `scripts/validate_all.jl` after every device TOML edit. The schema validator is cheap — use it every time. Don't accumulate 20 broken files before checking.

8. **RESEARCH STEPS ARE EXPLICIT.** If a device's spec is ambiguous across sources, mark the field `unknown` and open a `docs/research/<device-slug>.md` note describing what needs disambiguating. Don't guess. Don't hallucinate a number.

9. **SKEPTICISM.** Be skeptical of: subagent summaries, marketing blog posts, press releases that don't cite a paper, qubit counts that are "announced" but not "operational", and your own fuzzy recall of Nielsen & Chuang. Verify. Click the link. Check the datestamped archive.

10. **TEST-DRIVEN CURATION.** For every new schema field or new ingest adapter: write a test first. For every device file: the schema validator is the test. For every ingest script: a golden-master test on a cached raw source. No silent rots.

11. **JULIA IDIOMATIC.** Parametric types for device modality. Multiple dispatch over `isa` cascades. `ScopedValue` for build-time context. Use existing packages (`TOML`, `JSON3`, `JSONSchema`, `DuckDB.jl`, `SQLite.jl`) — don't reinvent parsers. No file >200 LOC unless there's a clear reason.

12. **NO SECOND SOURCE-OF-TRUTH.** TOML is the source-of-truth. Never edit the generated DuckDB/SQLite directly. Never let the Julia types diverge from the JSON Schema — regenerate one from the other when it makes sense.

13. **LIFECYCLE-COMPLETE.** Every device file carries an explicit `status` — `projected | announced | under_construction | in_service | intermittent | decommissioned | retired`. Retired devices STAY in the DB; don't delete history.

14. **MODALITY-AGNOSTIC CORE.** The schema must accommodate superconducting, trapped ion, neutral atom, photonic (discrete and CV), silicon spin, Ge spin, NV-diamond, SiC defect, topological / Majorana, NMR, annealers (flux and parametron), molecular tweezer arrays, rare-earth cavity-coupled systems, and anything not yet invented. If adding a new modality requires changing the core schema, the schema is wrong.

## Directory Layout

```
quantum-hardware/
├── CLAUDE.md                         # this file — ground rules
├── WORKLOG.md                        # institutional memory
├── LICENSE                           # AGPL-3.0 (matches Sturm.jl)
├── Project.toml                      # Julia package manifest
├── README.md                         # (forthcoming, keep CLAUDE first)
├── schema/
│   ├── SCHEMA.md                     # human-readable entity model + field reference
│   ├── device.schema.json            # JSON Schema for per-device TOML validation
│   └── vocab.toml                    # controlled vocabularies (modalities, gate names, api_kinds)
├── devices/                          # the LIVING DB — one TOML per DeviceRevision
│   ├── ibm/
│   ├── quantinuum/
│   ├── google/
│   ├── ionq/
│   ├── rigetti/
│   ├── quera/
│   ├── pasqal/
│   ├── iqm/
│   ├── oqc/
│   ├── atom_computing/
│   ├── infleqtion/
│   ├── alice_bob/
│   ├── xanadu/
│   ├── psiquantum/
│   ├── ustc/
│   ├── fujitsu_riken/
│   ├── dwave/
│   ├── microsoft/
│   ├── aws/
│   └── academic/                     # non-vendor testbeds, subfoldered by PI or institution
├── sources/                          # datestamped local archives (git-tracked)
│   └── YYYY/MM/DD/
├── src/                              # QuantumHardware.jl package
│   ├── QuantumHardware.jl            # module root
│   ├── schema.jl                     # Julia types mirroring the JSON Schema
│   ├── loader.jl                     # TOML → typed struct
│   ├── validator.jl                  # run JSON Schema against a TOML dict
│   ├── db.jl                         # build DuckDB/SQLite from TOML corpus
│   ├── queries.jl                    # public API for Sturm.jl consumers
│   └── ingest/                       # per-source ingest adapters
│       ├── braket.jl
│       ├── ibm.jl
│       ├── quantinuum.jl
│       └── …
├── test/
│   ├── runtests.jl
│   ├── test_schema.jl                # every devices/**/*.toml must pass schema
│   ├── test_loader.jl
│   └── test_db.jl
├── scripts/
│   ├── validate_all.jl               # schema-check the full devices/ tree
│   ├── build_db.jl                   # compile TOML → DuckDB + SQLite
│   ├── ingest_braket.jl              # pull all Braket public ARNs + save raw
│   └── …
└── docs/
    ├── research/                     # per-device disambiguation notes
    └── physics/                      # noise-model reference PDFs (Kraus / PTM conventions)
```

## Build & Validate

```bash
# Validate the corpus
julia --project scripts/validate_all.jl

# Build the compiled DB
julia --project scripts/build_db.jl
# writes db/quantum-hardware.duckdb and db/quantum-hardware.sqlite

# Run tests
julia --project -e 'using Pkg; Pkg.test()'

# Ingest from a live API
julia --project scripts/ingest_braket.jl   # requires AWS creds; saves raw to sources/YYYY/MM/DD/
```

## Consumer API (Sturm.jl facing)

```julia
using QuantumHardware

# Look up a device by slug
dev = target_spec("ibm-heron-r2")

# Query by capability
candidates = find_devices(min_qubits=100, modality=:sc_transmon, status=:in_service)

# Extract a Sturm.jl-compatible compile target
target = sturm_target(dev)  # returns (native_gates, coupling_map, noise_model, timing, access)
```

## License

AGPL-3.0. Every file.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking after `bd init --force --prefix quantum-hardware`. Run `bd prime` for full command reference.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists.
- Run `bd prime` for detailed command reference and session-close protocol.
- Use `bd remember` for persistent knowledge — do NOT scatter notes into stray markdown.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** — create issues for anything needing follow-up (schema ambiguity, source conflict, ingest failure).
2. **Run validation gates** — `scripts/validate_all.jl` and the test suite MUST pass.
3. **Update issue status** — close finished work, update in-progress items.
4. **PUSH TO REMOTE** — this is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** — clear stashes, prune stale branches.
6. **Verify** — all changes committed AND pushed.
7. **Hand off** — provide context for next session in the WORKLOG.

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds.
- NEVER stop before pushing — that leaves work stranded locally.
- NEVER say "ready to push when you are" — YOU must push.
- If push fails, resolve and retry until it succeeds.
<!-- END BEADS INTEGRATION -->
