# Device Schema v0.1 — quantum-hardware

One TOML file per `DeviceRevision`. Each file is authoritative for one specific revision of one device. The schema is lifecycle-complete: a single file tracks a device from `projected` through `retired`.

## File naming

`devices/<org_slug>/<device_slug>.toml`

- `<org_slug>` matches `[meta].org_slug` — kebab-case, lowercase.
- `<device_slug>` matches `[meta].id` — kebab-case, lowercase, unique across the corpus.

Examples:
- `devices/ibm/ibm-heron-r2.toml`
- `devices/quantinuum/quantinuum-helios.toml`
- `devices/quera/quera-aquila.toml`
- `devices/academic/ethz-wallraff-surface17.toml`

## Top-level sections

Every device TOML has these top-level tables / arrays, in this order:

| Section | Kind | Required | Purpose |
|---|---|---|---|
| `[meta]` | table | yes | id, slug, aliases, schema version, timestamps |
| `[organization]` | table | yes | vendor / group / lab / consortium |
| `[family]` | table | yes | device family / lineage |
| `[device]` | table | yes | the revision itself: status, qubits, dates |
| `[topology]` | table | yes | coupling graph / reconfigurable-ness |
| `[[native_gates]]` | array-of-tables | yes | native gate operations (≥1 entry) |
| `[noise_model]` | table | yes | T1/T2/readout/Kraus — fill what's public |
| `[[calibration_snapshots]]` | array-of-tables | no | longitudinal drift |
| `[timing]` | table | yes | gate durations, shot rate |
| `[access]` | table | yes | cloud / API / tier |
| `[benchmarks]` | table | no | QV, CLOPS, #AQ, kiloquop, XEB, … |
| `[energy_carbon]` | table | no | power draw, per-shot energy, CO₂ |
| `[roadmap]` | table | no | originally-projected targets (for historical perspective) |
| `[[provenance]]` | array-of-tables | yes | one entry per field with a non-null value (≥1) |

## `[meta]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string | yes | Globally unique slug, kebab-case (e.g. `ibm-heron-r2`). Matches filename stem. |
| `org_slug` | string | yes | Matches parent folder under `devices/`. |
| `aliases` | string[] | no | Vendor names, cloud names (`ibm_torino`), paper names. |
| `schema_version` | string | yes | Currently `"0.1"`. Bump on breaking schema changes. |
| `created_at` | datetime | yes | When this TOML was first committed. |
| `updated_at` | datetime | yes | Latest edit. |

## `[organization]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Display name. |
| `kind` | enum | yes | `commercial \| academic \| national_lab \| consortium \| government` |
| `country` | string | yes | ISO 3166-1 alpha-3 (e.g. `USA`, `CHN`, `DEU`). |
| `parent` | string | no | Parent org if applicable (`Honeywell` → Quantinuum). |
| `homepage_url` | string | no | |

## `[family]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | e.g. `Heron`, `Aspen`, `Aquila`. |
| `modality` | enum | yes | See `schema/vocab.toml` for full list: `sc_transmon \| sc_fluxonium \| sc_cat \| sc_dual_rail \| trapped_ion \| neutral_atom \| photonic_discrete \| photonic_cv \| si_spin \| ge_spin \| nv_diamond \| sic_defect \| topological_majorana \| nmr \| annealer_dwave \| annealer_parametron \| molecular \| rare_earth_cavity` |
| `lineage_predecessor` | string | no | Device id of the preceding revision. Enables DAG queries. |

## `[device]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Full revision name (e.g. `Heron r2`). |
| `status` | enum | yes | `projected \| announced \| under_construction \| in_service \| intermittent \| decommissioned \| retired` |
| `announced_date` | date | no | |
| `first_operational_date` | date | no | Required if `status >= in_service`. |
| `decommissioned_date` | date | no | Required if `status = decommissioned \| retired`. |
| `num_qubits` | integer | yes | Physical qubits (atoms, ions, transmons, modes for photonic). |
| `num_logical` | integer | no | QECC-native devices only. |
| `logical_code` | string | no | `steane \| surface \| rotated_surface \| bivariate_bicycle \| color \| gkp \| cat \| …` |
| `code_distance` | integer | no | |
| `architecture_notes` | string | no | Free-form prose: tunable couplers, zone count, fridge type, etc. |

## `[topology]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `kind` | enum | yes | `all_to_all \| heavy_hex \| square_grid \| hex \| linear_chain \| ring \| kagome \| bipartite \| reconfigurable \| analog_hamiltonian \| custom` |
| `reconfigurable` | bool | yes | `true` for neutral-atom arrays, photonic mesh, modular ion QCCD movement, etc. |
| `coupling_map` | int[][] | no | List of 2-element arrays `[q_a, q_b]`. Omit for `all_to_all` or pure `reconfigurable`. |
| `position_constraints` | table | no | Reconfigurable arrays: `{max_atom_count, lattice_spacing_um, addressable_region_um, …}` |
| `diagram_url` | string | no | Link to an authoritative topology figure / SVG. |

## `[[native_gates]]`

One entry per native operation. Include idle / reset / measurement as explicit entries if they participate in the calibration budget.

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Vendor-visible name: `CZ`, `ECR`, `MS`, `Rxx`, `U1q`, `GPI`, `analog_rydberg`, `readout`, `reset`. |
| `arity` | integer | yes | 1, 2, or (rare) n. |
| `kind` | enum | yes | `gate \| measurement \| reset \| idle \| analog_hamiltonian` |
| `params` | string[] | no | Names of continuous parameters, e.g. `["theta"]` or `["Omega(t)", "Delta(t)"]`. |
| `duration_ns` | float | no | Median or representative. Set to 0 for virtual / software (e.g. Rz in SC). |
| `fidelity_mean` | float | no | Average across qubits / pairs. |
| `fidelity_median` | float | no | |
| `fidelity_per_qubit` | float[] | no | Index matches qubit index. 1-qubit gates. |
| `fidelity_per_pair` | table[] | no | 2-qubit: `[{pair=[0,1], fidelity=0.997}, …]`. |
| `kraus_operators_file` | string | no | Relative path to a JSON sidecar file containing `[[Kᵢ]]` as complex matrices. TOML inlining is unwieldy for these. |
| `ptm_file` | string | no | Pauli transfer matrix sidecar. |

## `[noise_model]`

Fill whatever's public, at whatever fidelity order works (Kraus > PTM > T1/T2/gate-err > average fidelity).

```toml
[noise_model.t1_us]
mean = 250.0
median = 240.0
per_qubit = [ … ]         # length = num_qubits, nulls allowed

[noise_model.t2_us]
kind = "echo"             # ramsey | echo | cpmg
mean = 180.0
per_qubit = [ … ]

[noise_model.readout]
fidelity_mean = 0.98
fidelity_per_qubit = [ … ]
confusion_matrix_file = "…/confusion.json"   # optional

[noise_model.crosstalk]
zz_coupling_hz = { "[0,1]" = 50000, … }      # optional table
```

## `[[calibration_snapshots]]`

Longitudinal drift record. Append-only. Vendor APIs expose daily cron dumps for IBM and others — each pull yields one snapshot row.

| Field | Type | Required | Notes |
|---|---|---|---|
| `timestamp` | datetime | yes | UTC. |
| `t1_us_mean` | float | no | |
| `t2_us_mean` | float | no | |
| `gate_err_1q_mean` | float | no | |
| `gate_err_2q_mean` | float | no | |
| `readout_err_mean` | float | no | |
| `raw_file` | string | yes | Path into `sources/YYYY/MM/DD/…` with the raw API response this snapshot was extracted from. |
| `provenance_idx` | integer | yes | Index into `[[provenance]]`. |

## `[timing]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `single_qubit_gate_ns` | float | yes | Representative duration. |
| `two_qubit_gate_ns` | float | yes | |
| `readout_ns` | float | yes | |
| `reset_ns` | float | no | |
| `shot_rate_hz` | float | no | If published. |
| `queue_depth_notes` | string | no | |

## `[access]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `cloud_provider` | string | no | `aws_braket \| azure_quantum \| ibm_quantum \| google_quantum_ai \| ionq_cloud \| pasqal_cloud \| xanadu_cloud \| rigetti_qcs \| oqc_cloud \| quantinuum_systems \| dwave_leap \| origin_cloud \| tianyan \| none` |
| `api_kind` | enum | yes | `qiskit_runtime \| braket \| azure_quantum \| qcs \| pulser \| bloqade \| strawberry_fields \| ionq_rest \| pasqal_core \| openqasm3 \| openpulse \| custom \| offline` |
| `api_endpoint` | string | no | Base URL when public. |
| `tier` | enum | yes | `open \| free \| paid \| research_only \| private \| not_accessible` |
| `auth_required` | bool | yes | |
| `pricing_notes` | string | no | |
| `sdk_packages` | string[] | no | PyPI / Julia / npm package names. |

## `[benchmarks]`

Free table — each key is a named benchmark, each value either a scalar or an inline table `{value, methodology_url, date, source_provenance_idx}`. Examples:

```toml
[benchmarks]
quantum_volume = { value = 512, date = 2024-11-13, methodology_url = "https://arxiv.org/abs/1811.12926" }
clops = { value = 50000, date = 2024-11-13 }
aq = 29       # IonQ #AQ; scalar form permitted for terseness
kiloquop = 0.82
xeb_fidelity = { value = 0.9992, date = 2025-05-01 }
```

## `[energy_carbon]`

All optional. Record whatever's publicly reported.

| Field | Type | Notes |
|---|---|---|
| `fridge_kw` | float | Dilution fridge power draw. |
| `system_kw` | float | Full system including control racks. |
| `per_shot_j` | float | If reported. |
| `kgco2_per_shot` | float | If reported. |
| `cooling_notes` | string | |
| `helium3_notes` | string | |

## `[roadmap]`

For devices that are projected or announced, this is the primary source of truth. For operational devices, this preserves what was *originally* promised — useful for later "roadmap vs. reality" analyses.

| Field | Type | Notes |
|---|---|---|
| `originally_targeted_year` | integer | |
| `originally_targeted_qubits` | integer | |
| `originally_targeted_logical` | integer | |
| `originally_targeted_fidelity_1q` | float | |
| `originally_targeted_fidelity_2q` | float | |
| `narrative` | string | Prose from the original announcement. |

## `[[provenance]]`

**Every non-null numeric or categorical field SHOULD have at least one matching provenance record.** A validator can spot-check that the most important fields (`device.num_qubits`, `noise_model.t1_us.mean`, each `native_gates[].fidelity_mean`, etc.) have provenance.

| Field | Type | Required | Notes |
|---|---|---|---|
| `field_path` | string | yes | Dotted path to the field, e.g. `device.num_qubits` or `native_gates[0].fidelity_mean`. |
| `value` | any | yes | The actual value recorded. Redundant, but makes the provenance row self-contained. |
| `source_url` | string | yes | Canonical reference URL / DOI / arXiv id. |
| `source_kind` | enum | yes | `paper_arxiv \| paper_doi \| press_release \| vendor_doc \| api_dump \| talk_video \| datasheet \| book_report \| conference_abstract \| blog_post \| forum_post \| wikipedia` |
| `retrieved_at` | datetime | yes | When the local archive was captured. |
| `local_path` | string | yes | Path into `sources/YYYY/MM/DD/…`. NEVER absent — if the source is truly un-archivable, open a research note and leave the field `null`. |
| `sha256` | string | yes | Of the local archive bytes. |
| `notes` | string | no | Extraction detail (table row, equation number, JSON key, page number). |
| `conflict` | bool | no | `true` if this provenance disagrees with another recorded value for the same field. |

## Controlled vocabularies

See `schema/vocab.toml` for the authoritative enum lists: modalities, api_kinds, source_kinds, topology kinds, cloud_providers, logical_codes.

## Schema evolution

- Bump `schema_version` on any breaking change (new required field, renamed field, narrowed enum).
- Additions (new optional fields, new enum entries) are non-breaking and DO NOT require a version bump — but should be noted in `WORKLOG.md`.
- Every schema change requires the 3+1 agent protocol (`CLAUDE.md` §Principle 2).
