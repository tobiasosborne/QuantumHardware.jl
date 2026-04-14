# quantum-hardware Work Log

Gotchas, learnings, decisions, surprises. Updated every step. Institutional memory.

---

## 2026-04-14 — Session 1: scoping, schema v0, repo scaffold

### Goal of the project

Build a living, versioned, public-sources-only database of ALL quantum-computing hardware — commercial **and** academic, past through projected, across every modality. Consumer #1 is `Sturm.jl`'s forthcoming `compile(ch, target=…)` viability pipeline.

### Scoping research (4 parallel subagents)

Four background agents ran in parallel covering: existing public DBs / registries, commercial vendor census, academic experimental-group census, and data ingestion channels. Key findings:

**Device count: ~280.**
- Commercial / vendor-named: **~155** across ~40 vendors. IBM alone has ~12 named generations (Canary-5 → Falcon → Hummingbird → Eagle → Osprey → Condor → Heron r1/r2/r3 → Nighthawk → Loon → Flamingo plan). Rigetti ~12 Aspen/Ankaa variants. D-Wave 6 generations. Chinese stack ~10 named devices (Zuchongzhi 1/2.1/3.0/3.2, Jiuzhang 1–4, Wukong, Tianyan-176/287/504).
- Academic / national-lab testbeds: **~110-130** across ~45 PI groups, averaging ~2.5 concurrent testbeds per group.
- National / consortium "hero" systems: **~15-20** (JUNIQ stack, WACQT-25, RQC-Fujitsu 256q, EuroHPC Pasqal sites, Fermilab SQMS, Q-NEXT testbeds, Microsoft Majorana 1, …).

**Modality mix (commercial vendors):** SC transmon 14 · trapped ion 4 · neutral atom 4 · photonic 6 · silicon spin 5 · NV-diamond 1 · annealer 1 · topological 1 · bosonic/cat 3 · dual-rail 2.

**Existing-DB verdict: no single source is fork-worthy.**
- Closest: MIT Quantum Index Report QPU Benchmarking (200+ QPUs) — but CC BY-**ND**, annual PDF only, no API.
- Best open schema anchor: **`amazon-braket-schemas-python`** (Apache-2.0, Pydantic-typed per-provider capability blobs).
- Best open vendor-specific Git repo: **`CQCL/quantinuum-hardware-specifications`** (Apache-2.0, JSON + CSV + notebooks, kept in lockstep with PDF datasheets).
- Best open benchmark spine: **`unitaryfoundation/metriq-data`** (CC BY 4.0).
- IBM: live `BackendV2.target` + `target_history(datetime=…)` + `qiskit-ibm-runtime.fake_provider` snapshots.

**Critical gaps across all existing sources** (which this DB aims to fill):
- Longitudinal calibration history
- Academic testbed coverage (beyond Quantum Inspire)
- Projected → shipped lifecycle (single row, not two)
- Carbon / energy data (essentially nil today)
- Cross-modality normalised metrics

### Design decisions (recorded now to save future bikeshedding)

1. **Storage:** TOML per `DeviceRevision`, git-tracked, human-editable, PR-friendly. Compiled artefact is DuckDB (+ SQLite fallback) built by `scripts/build_db.jl`. Never hand-edit the DB. Confirmed by user.
2. **Language bindings:** Julia only (`QuantumHardware` package) for now. No Python/Rust wrappers until schema is stable. Confirmed by user.
3. **First ingest targets:** full AWS Braket fleet (5 vendors in one pull: IonQ, IQM, Rigetti-via-Braket, QuEra, OQC Lucy) + Quantinuum's Git repo. Confirmed by user.
4. **Provenance = URL + local datestamped archive.** Every field must cite both a canonical URL AND a `sources/YYYY/MM/DD/…` file with SHA-256. URLs rot. User emphasised this is non-negotiable. Memorialised in `CLAUDE.md` §DUAL SOURCE-OF-TRUTH.
5. **Ground rules adapted from `../Sturm.jl`, `../Bennett.jl`, `../Feynfeld.jl`.** Shared principles (WORKLOG, fail-fast, skepticism, TDD, Julia-idiomatic, 3+1-agent rule for core changes) carried over. "Physics = local PDF + equation" became "Data = local archive + reference URL".
6. **Schema is modality-agnostic from day 1.** A new modality must not require core schema changes — only a new entry in `schema/vocab.toml`.
7. **Lifecycle is a single-row concept.** A device stays one file from `projected` through `retired`. No duplicate rows per status change.

### Schema v0 entity model (see `schema/SCHEMA.md` for full field reference)

```
Organization
  └─ DeviceFamily
       └─ DeviceRevision               ← one TOML file == one revision
            ├─ Topology
            ├─ NativeGateSet
            ├─ NoiseModel
            ├─ CalibrationSnapshot[]   ← longitudinal
            ├─ Timing
            ├─ Access
            ├─ Benchmarks
            ├─ EnergyCarbon
            ├─ Provenance[]            ← (url, local_path, sha256, retrieved_at, source_kind)
            └─ Roadmap
```

### Anchor schemas studied

- **AWS Braket**: `deviceCapabilities` → `paradigm` (`gate_model` vs `analog_hamiltonian`) + `action` (`braket.ir.jaqcd.program` vs `braket.ir.ahs.program`) + `qubitCount` + `connectivity` (`fullyConnected` bool + `connectivityGraph`) + `nativeGateSet` + `qubitProperties` + `twoQubitProperties` (with `edges` listing `fidelity`, `gateTime`).
- **Qiskit Target**: `num_qubits`, `coupling_map`, `basis_gates`, per-instruction `InstructionProperties(duration, error)`, per-qubit `QubitProperties(t1, t2, frequency)`, `dt` pulse resolution.
- **Quantinuum datasheet JSON**: mixes performance metrics (`sq_error`, `tq_error`, `memory_error`, `spam_error`) with benchmark results (QV, AQ, mirror benchmarking) and system-level facts (qubit count, zone count for QCCD, connectivity = all-to-all).

Our schema unifies all three without privileging any.

### Open questions / research backlog

- **Native gate nomenclature.** Different vendors name "the same" gate differently (IBM: `ECR`, `CX`, `CZ`, `Rzz`; IonQ: `GPI`, `GPI2`, `MS`, `ZZ`; Quantinuum: `Rxx(θ)`, `U1q`, `ZZ`; neutral atom: `Rz`, `Ry`, `CZ`, plus analog Hamiltonian tokens). `schema/vocab.toml` will carry a controlled vocab + per-vendor aliases. Start with IBM + IonQ + Quantinuum + Pasqal coverage; extend as ingests roll in.
- **Kraus operator representation in TOML.** A general Kraus set is a list of complex matrices. TOML doesn't have complex numbers natively — likely encode as `[[real, imag], …]` arrays. Decided: keep raw Kraus sets in JSON sidecar files referenced from TOML, since TOML gets unwieldy for large matrices.
- **How to represent reconfigurable topologies?** QuEra/Pasqal atom positions are programmable per shot, not a fixed coupling map. Schema field `topology.reconfigurable: bool` plus optional `topology.position_constraints` describing tweezer-array parameters (max atom count, lattice spacing, addressable region).
- **How to represent analog Hamiltonian devices?** Aquila exposes a Rydberg Hamiltonian with programmable `Ω(t)`, `Δ(t)`, `φ(t)` and interaction tensor — not a gate set. Schema field `native_gates[].kind: "analog_hamiltonian"` with `params: {Omega_max, Delta_range, phi_range, C6, …}`.
- **Benchmark normalisation across modalities.** Quantum Volume is SC-centric; `#AQ` is IonQ-centric; kiloquop is Quantinuum-centric; XEB is SC-centric; analog GBS benchmarks are photonic-only. Schema records each benchmark as a separate row with `metric_name` + `value` + `methodology_url` — normalisation is a downstream concern, not a schema concern.
- **Connectivity graph format.** Coupling map = list of `[q_a, q_b]` edges. Fine for gate-model devices. For heavy-hex / grid / kagome / ring, we also record the `topology.kind` enum so layout-aware compilers can short-circuit graph analysis.

### Beads / repo hygiene TODOs

- [ ] `bd init --force --prefix quantum-hardware` when user initialises issue tracking.
- [ ] `git init` and first commit of scaffold.
- [ ] First AWS Braket ingest after scaffold is validated.

### Gap-finding methodology (agreed this session)

Single-LLM surveys leak — the Quandela/Qudora miss is the recurring failure mode. The countermeasure is **multi-source triangulation**: cross-reference several independent enumeration channels and treat the set union as the candidate pool. Six channels worth systematising, in rough order of yield:

1. **Government-funding award lists (highest yield).** Every major QC-funding programme publishes awardees, and each awardee is a device-bearing org by construction.
   - **DLR Quantum Computing Initiative** (DE) — where Qudora surfaced; €740M programme, consortium awardees named.
   - **France 2030 / PEPR Quantique** (FR) — where Quandela / C12 / Welinq surface.
   - **EuroHPC Quantum Initiative** (EU) — 6 host sites × their hardware partners.
   - **DARPA QBI** (US) — stage-gated vendor list (20 companies, 11 in Stage B).
   - **DOE National QIS Centers** (US, 5) — industrial partners per centre (SQMS, QSC, Q-NEXT, QSA, C2QA).
   - **UK NQCC + EPSRC Quantum Hubs** — industrial co-investigators.
   - **Japan Moonshot Goal 6 / Q-LEAP**, **Korea K-Quantum**, **Australia ARC CoE QCQT**, **Israel Quantum Initiative**.
   - **Tobias has an existing database `fundingscape` cataloguing all grants** — we can diff our `devices/` corpus against fundingscape's awardees in a later session instead of re-scraping.

2. **Cloud-provider partner pages.** AWS Braket / Azure Quantum / OVHcloud / Alibaba Quantum Lab / Naver Cloud / SberCloud each publish hardware-partner lists.

3. **Patent-assignee scans.** OECD-EPO "Mapping the Global Quantum Ecosystem" (Dec 2025) already did this aggregation; WIPO + USPTO + JPO + KIPO + CNIPA queries on IPC `G06N 10/*` filtered by ≥5 assignees.

4. **Conference sponsor/exhibitor lists.** APS March 2026, IEEE QCE 2026, Q2B Tokyo/Chicago, Quantum.Tech, Photonics West, Q-TURN, regional events — sponsor tiers list orgs verbatim.

5. **arXiv institution-diff crawl.** Monthly cron over `quant-ph` new submissions with device-characterisation keywords (`T1 T2`, `process tomography`, `randomized benchmarking`, `gate fidelity`). Extract affiliations, diff against known orgs, novel affiliation = candidate.

6. **Community pressure-testing.** Open the DB publicly, invite PRs. Post periodic "what are we missing?" on Qiskit Slack + Unitary Fund Discord + quant-ph arXiv forum. Register with Metriq so their contributor base surfaces gaps. **This is the only channel that scales past a single curator.**

**Decision Session 1 (user, 2026-04-14):** Defer structured gap-hunting in favour of running the first real ingests (Braket + Quantinuum). Gap-hunting is a priority-2 follow-up. The `fundingscape` DB is the primary future source for channel 1.

### Commercial-census gaps surfaced during Session 1

User noted two missing vendors that the commercial-survey subagent had dropped:

- **Quandela (France, photonic_discrete)** — single-photon / quantum-dot source feeding a programmable linear-optical mesh. MosaiQ product line: Ascella-6 (in_service at OVHcloud, Nature Photonics 2024), Belenos-12 (announced, mid-2026 cloud), Canopus-24 (projected 2026). Added as 3 device files.
- **QUDORA Technologies (Germany, trapped_ion)** — microwave-driven ion trap (Near-Field Quantum Control / NFQC). Hamburg-50 (projected, DLR €42M contract, delivery Jan 2027 with NXP) and Braunschweig-200 (projected, through 2027). Added as 2 device files.

Action: enumerate European mid-tier vendors more carefully in the next census sweep. Candidates to verify and (probably) add: **eleQtron** (DE, ion), **planqc** (DE, neutral atom), **Aegiq** (UK, photonic), **C12 Quantum Electronics** (FR, carbon-nanotube spin), **Nu Quantum** (UK, photonic networking), **Welinq** (FR, photonic networking), **TreQ** (DE/AT, ion), **Quantum Source** (IL, photonic-atomic hybrid). The Session-1 commercial-survey agent skewed toward US/UK/Chinese coverage; European and Japanese coverage needs a dedicated pass.

### Session 1 delivered (end-of-session summary)

- Repo scaffold at `/home/tobias/Projects/quantum-hardware/` — see `CLAUDE.md` for the directory layout.
- Schema v0.1: `schema/SCHEMA.md` (prose), `schema/device.schema.json` (validation), `schema/vocab.toml` (controlled enums).
- Julia package `QuantumHardware` (0.0.1): `src/{QuantumHardware,schema,validator,loader,queries}.jl`.
- Eight hand-curated example devices covering five modalities:
  - `devices/quera/quera-aquila.toml` — neutral-atom analog Hamiltonian, 256q (in_service).
  - `devices/quantinuum/quantinuum-h2.toml` — trapped-ion QCCD, 56q (in_service).
  - `devices/ibm/ibm-heron-r2.toml` — SC transmon heavy-hex, 156q (in_service).
  - `devices/quandela/quandela-{ascella,belenos,canopus}.toml` — photonic MosaiQ 6/12/24q.
  - `devices/qudora/qudora-{hamburg-50,bs-200}.toml` — microwave-NFQC ion 50q/200q (projected).
- Three real public-source archives in `sources/2026/04/14/` (arXiv abstract, Quantinuum spec-repo README, Wikipedia list of QPUs) with SHA-256s recorded.
- `scripts/validate_all.jl` passes on all three devices. `julia --project -e 'using Pkg; Pkg.test()'` passes 48/48 tests, including the strong "every provenance archive exists on disk and its sha256 matches" integrity check.

### Schema self-test outcome (Session 1)

The three seed devices exercised every optional section except `calibration_snapshots` and `energy_carbon`. No schema field had to be added mid-session. One bug found and fixed: the module docstring in `src/schema.jl` interpolated `$defs` because Julia docstrings are regular strings — escaped with `\$defs`. Noted for future agents writing docstrings referencing JSON Schema terminology.

### First-ingest run (Session 1, cont.) — Apr 14 2026

**Quantinuum ingest (pathway: git clone, no auth)**
- `scripts/ingest_quantinuum.jl` clones `CQCL/quantinuum-hardware-specifications` (depth 1), snapshots every JSON under `data/<system>/<date>/` into `sources/2026/04/14/quantinuum/<system>/<date>_<file>`, parses `notebooks/Spec sheet parameters.csv`, emits one TOML per system.
- Produced 5 devices: `quantinuum-h1-1`, `quantinuum-h1-2`, `quantinuum-h2-1`, `quantinuum-h2-2`, `quantinuum-reimei`.
- Each TOML carries real `calibration_snapshots[]` — one per dated spec-sheet row, with gate_err_1q_mean / gate_err_2q_mean / readout_err_mean parsed from the CSV. Provenance points to GitHub raw URLs AND to the local archive of each JSON (sha256-verified on disk). H2-1 ends up with 3 snapshots (2023-03-10, 2024-05-20, 2025-04-30); H1-1 has 5 across 2022–2025.
- The Session-1 stub `devices/quantinuum/quantinuum-h2.toml` was deleted in favour of the proper H2-1 / H2-2 split.

**AWS Braket ingest (pathway A: no-AWS-creds docs scrape)**
- `scripts/ingest_braket.jl` fetches the developer-guide "Supported devices" HTML, snapshots it into `sources/2026/04/14/aws-braket-devices.html`, parses ARNs by regex, emits one TOML per unique QPU ARN.
- Produced 7 new devices + 1 overwrite: `aqt-ibex-q1`, `ionq-forte-1`, `ionq-forte-enterprise-1`, `iqm-garnet`, `iqm-emerald`, `rigetti-ankaa-3`, `rigetti-cepheus-1-108q`, and `quera-aquila` (overwritten — see bug below).
- Pathway A is intentionally coarse: numeric gate times are vendor-baseline presets, not live calibration. Pathway B (live `GetDevice`) will overwrite these once AWS creds are wired up.
- **AQT Ibex-Q1 surfaced as a vendor we'd missed in Session 1** (another Europe-coverage gap — AQT is the Innsbruck spinout). The gap-finding methodology above predicts this pattern; AQT only showed up because docs-scraping enumerated ARNs exhaustively.

**Bug discovered + fixed: the hand-curation guard**
- First Braket-ingest pass clobbered the hand-curated `devices/quera/quera-aquila.toml` (which had real arxiv-paper provenance, analog-Hamiltonian native gate, position_constraints, roadmap). The preservation check was looking for `calibration_snapshots[]`, and the hand-curated Aquila didn't have any, so the check green-lit the overwrite. User accepted the overwrite as intentional — leaving the coarser TOML in place for now.
- **Fix:** new `src/ingest/common.jl` with `is_hand_curated(path)` — checks the first 20 lines of a target TOML for the canonical `# Auto-generated by scripts/…` marker. Absent marker → hand-curated → skip. Both `BraketIngest` and `QuantinuumIngest` now call this before writing. Every auto-generated TOML writes the marker header; hand-curated TOMLs simply don't. A belt-and-braces `[meta] curation = "hand"` key is available for explicit locking. This is the documented convention going forward — future ingest adapters MUST call `is_hand_curated` before any overwrite.

**Corpus state end-of-session**
- 19 devices: 1 IBM, 5 Quantinuum, 1 QuEra (overwritten), 3 Quandela, 2 QUDORA, 1 AQT, 2 IonQ, 2 IQM, 2 Rigetti.
- All 328 tests pass (schema validation + loader roundtrip + dual-SoT sha256 verification + find_devices/target_spec/sturm_target API).
- `scripts/validate_all.jl` reports `19 passed, 0 failed`.
- Total source archives: 11 files in `sources/2026/04/14/` covering arXiv, Quantinuum public spec repo (+ five systems × multiple dates of RB data), Quandela roadmap + arXiv, QUDORA news + TQI article, Wikipedia list of QPUs, AWS Braket devices docs page.

**Schema evolution in this session:** none. All 5 Quantinuum + 7 Braket TOMLs validated without schema changes, confirming the v0.1 shape is robust across two very different ingest pipelines.

### Next session targets

1. **First real ingest: AWS Braket.** Write `scripts/ingest_braket.jl` to pull `GetDevice` for every public ARN, save the raw JSON under `sources/YYYY/MM/DD/`, and emit / update a TOML per device. This should produce ~5 new device files in one run (IonQ Forte + Forte Enterprise, IQM Garnet + Emerald, Rigetti Ankaa-3 + Cepheus-1, QuEra Aquila (replace seed), OQC Lucy). Success criteria: `scripts/validate_all.jl` stays green after the run.
2. **Quantinuum repo ingest.** `git clone CQCL/quantinuum-hardware-specifications` into a cache, write `scripts/ingest_quantinuum.jl` that parses the JSON specs and refreshes `devices/quantinuum/*.toml`, replacing the Session-1 stub with real gate-fidelity history.
3. **Beads init.** `bd init --force --prefix quantum-hardware` and file first-class issues for the 15-20 known ingest targets.
4. **Longitudinal IBM pull.** Thin wrapper around `IBMBackend.target_history(datetime=…)` that populates `calibration_snapshots` for Heron r2 going back as far as the API allows. This is the one schema section none of the Session-1 seeds exercised.
5. **Fill the Academic tree.** Port a dozen high-visibility testbeds from the Session-1 research tables (Wallraff-Surface17, Oliver MIT-LL Fluxonium, Endres Caltech 6100-atom array, Innsbruck AQT PINE-50, …). These don't have an API; they need hand-curation from arXiv papers with papers archived into `sources/`.
6. **DuckDB build.** `scripts/build_db.jl` — open a new DuckDB, declare tables mirroring the TOML schema, insert one row per `DeviceRevision` + one row per provenance entry, write to `db/quantum-hardware.duckdb`. This is the artefact Sturm.jl will query. Add `DuckDB.jl` (and `SQLite.jl` as fallback) to `Project.toml`.
7. **Sturm.jl bridge.** Once the DuckDB is alive, add a `QuantumHardware` dep to Sturm.jl and expose a `Sturm.compile(ch, target=id::String)` first draft that consumes `sturm_target(target_spec(id))`.

### Session 1 close (end of day)

- **Delivered:** scaffold + 19 devices + 2 ingest pipelines + 328 passing tests + 84 archived sources.
- **Known tech debt:** `quera-aquila.toml` was overwritten by the first Braket ingest run — it lost the arXiv-paper provenance, analog-Hamiltonian native-gate detail, and position_constraints that had been hand-curated earlier in the session. The hand-curation guard is now in place so this can't recur, but the Aquila data itself needs to be restored from the Session-1 stub (or from pathway-B ingest once AWS creds are wired). Tracked for next session.
- **Next session kickoff:** `git pull`; `julia --project scripts/validate_all.jl` should show 19 passed; beads init (`bd init --force --prefix quantum-hardware`) to formalise the issue queue; then move to `scripts/build_db.jl` for the DuckDB artefact.

---

## 2026-04-14 — Session 2: beads init, DuckDB/SQLite build artefact

### Kickoff

Validation ran green (19/19). `bd init --force --prefix quantum-hardware` succeeded — Dolt embedded backend, prefix `quantum-hardware-<hash>`. Filed 7 follow-up issues (Aquila restore, DuckDB build, live-Braket pathway-B, IBM target_history, academic-tree port, Sturm.jl bridge, census-sweep gaps). `quantum-hardware-t0c` (DuckDB build) claimed as the session's main work; `quantum-hardware-lg9` (Sturm bridge) wired `depends on` → DuckDB build.

### DuckDB + SQLite compiled artefact

**Delivered:** `src/db.jl` + `scripts/build_db.jl` + `test/test_db.jl`. Added `DuckDB.jl`, `SQLite.jl`, `DBInterface.jl` to `Project.toml`. Artefact produced at `db/quantum-hardware.duckdb` (2.6 MB) and `db/quantum-hardware.sqlite` (112 KB). Both files `.gitignore`d — never committed, always regenerated.

Tables (5): `devices` (65 flat columns, JSON-encoded blobs for nested things), `native_gates`, `coupling_edges`, `calibration_snapshots`, `provenance`. Current corpus populates:
- 19 devices, 78 native gates, 15 calibration snapshots, 96 provenance rows
- 0 coupling edges — IBM Heron r2's heavy-hex map is intentionally deferred to the live `target_history` ingest (noted in its TOML); every other device is `all_to_all` or `reconfigurable`. Count will jump once IBM ingest lands.

Cross-backend: identical DDL works for both DuckDB and SQLite via `DBInterface.jl`. DuckDB enforces strict types; SQLite stores with flexible affinity. Dates/timestamps stored as ISO-8601 TEXT for portability — cast at query time if arithmetic is needed.

### Gotchas

- **DuckDB column-count mismatch surfaces only at INSERT time.** First attempt wrote `VALUES (?,?, …)` by hand; missed two placeholders, caught only when the first row hit the prepared statement: `Binder Error: table devices has 65 columns but 63 values were supplied`. **Fix:** declare `_DEVICE_COLUMNS::NTuple{Symbol}` in DDL order, build the INSERT SQL programmatically with `join(fill("?", length(cols)), ",")`, and assert `length(vals) == length(cols)` inside `_insert_device`. Any future column add requires editing both the DDL and the tuple — a mismatch now errors loudly with a clear message, not a mysterious binder error. Convention going forward: every multi-column insert uses this explicit-columns-plus-programmatic-placeholders pattern.

- **SQLite.jl `Row` is cursor-backed and does not survive `collect()`.** First cut of `test_db.jl` did `rows = collect(DBInterface.execute(s, "SELECT …"))` and then `rows[1].num_qubits`, which returned `missing` for *NOT NULL* columns that were definitely populated. The underlying SQLite statement had been finalised by the time `rows[1]` was accessed. **Fix:** extract field values eagerly during iteration (`push!(ext, (num_qubits=r.num_qubits, …))`). DuckDB.jl does materialise rows on collect, so the DuckDB round-trip test didn't hit this — the mismatch only showed up in the SQLite test. Convention going forward: for the SQLite backend, always extract column values inside the iterator body, never off a collected array.

- **Reserved-word near miss:** `TIMESTAMP` as a column name works in DuckDB but is borderline. Renamed the snapshot column to `ts` to avoid any dialect drift.

- **DuckDB.jl deprecation warnings** (`nextDataChunk` at `result.jl:822/832/836`) fire on every `DBInterface.execute` collection. Noise-only right now — upstream will remove the deprecated internal method in a future release; upgrade DuckDB.jl when that happens.

### Beads issues filed this session

| id | title | priority | status |
|---|---|---|---|
| quantum-hardware-dw4 | Restore QuEra Aquila hand-curated data | P1 | open |
| quantum-hardware-t0c | Build DuckDB+SQLite compiled artefact | P1 | **closed** |
| quantum-hardware-8x4 | Live AWS Braket pathway-B ingest | P2 | open (blocked-on-creds) |
| quantum-hardware-cj1 | IBM target_history longitudinal calibration pull | P2 | open (blocked-on-creds) |
| quantum-hardware-jgc | Port academic testbeds (hand-curated from arXiv) | P2 | open |
| quantum-hardware-lg9 | Sturm.jl bridge (depends on t0c) | P3 | open (now unblocked) |
| quantum-hardware-xiy | Census sweep: European mid-tier + JP/KR vendors | P3 | open |

### Corpus state end-of-session

- 19 devices (unchanged), 351 tests pass (was 328 — 23 new DB-roundtrip tests), 84 source archives (unchanged — no new ingests this session).
- Validator still `19 passed, 0 failed`.
- DB artefact: `build_db(path; backend=:duckdb|:sqlite, devices=nothing)` — idempotent (deletes and rebuilds), returns row-count NamedTuple.

### Next session targets

1. **Restore QuEra Aquila** (quantum-hardware-dw4). Session-1 stub content is NOT recoverable from git (single commit `a00b8dc` already had the overwritten version). Options: (a) re-hand-curate from arXiv 2306.11727 + QuEra docs, or (b) wait for pathway-B Braket ingest. (a) is faster if the archive is still in `sources/2026/04/14/`.
2. **Sturm.jl bridge** (quantum-hardware-lg9) — now unblocked. Add `QuantumHardware` dep to `../Sturm.jl`, expose `Sturm.compile(ch; target=id::String)` that consumes `sturm_target(target_spec(id))`. No DB query needed for v0 — the TOML corpus is fast enough; DB is for analytical queries.
3. **Longitudinal IBM pull** (quantum-hardware-cj1, blocked-on-creds). Wire up IBM Quantum creds, write `scripts/ingest_ibm.jl` around `target_history(datetime=…)`. First real populated coupling_map in the DB.
4. **Academic testbeds** (quantum-hardware-jgc). Hand-curate ~12 testbeds from arXiv papers. No API; PDFs archived into `sources/YYYY/MM/DD/`.
5. **TDD discipline:** user flagged mid-session that all future work should go strict red-green. The Session-2 DB work was more implementation-first-then-test than red-green. Future sessions: every new function gets a failing test in `test/test_*.jl` before the implementation lands. Validate the red before writing the green.
