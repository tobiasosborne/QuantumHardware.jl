# Compile the TOML corpus into a query-ready DuckDB (primary) or SQLite
# (fallback) artefact. Never hand-edit the output — regenerate from scratch.
#
# Each table is declared once via a `ColumnSpec[]` list. The list drives:
#   - the CREATE TABLE DDL,
#   - the INSERT SQL (column list + placeholder count),
#   - the per-row value tuple (via each spec's `extract` closure).
# Single source of truth — adding a column means editing one entry; the
# previous "lockstep mismatch crashes loudly at INSERT time" pattern is gone.
#
# Tables:
#   devices               one row per DeviceRevision, scalars flattened
#   native_gates          one row per (device_id, gate_idx)
#   coupling_edges        one row per (device_id, qubit_a, qubit_b)
#   calibration_snapshots one row per (device_id, timestamp)
#   provenance            one row per (device_id, prov_idx)
#
# SQL is portable between DuckDB and SQLite. DuckDB enforces strict types;
# SQLite stores with flexible affinity. Dates/timestamps stored as ISO 8601
# text for portability — cast at query time if you need arithmetic.

using DBInterface
import DuckDB
import SQLite
import JSON3

# --- Primitives --------------------------------------------------------------

_iso(d::Date)     = string(d)
_iso(t::DateTime) = Dates.format(t, dateformat"yyyy-mm-ddTHH:MM:SS")
_iso(::Nothing)   = nothing

_json_or_null(::Nothing) = nothing
_json_or_null(x)         = JSON3.write(x)

_sym_or_null(::Nothing) = nothing
_sym_or_null(s::Symbol) = String(s)

# Optional-wrapper field access. Composes with _json_or_null / _sym_or_null
# because both already dispatch on Nothing — a missing wrapper short-circuits
# cleanly through any number of transforms.
_field(::Nothing, ::Symbol) = nothing
_field(x,         f::Symbol) = getfield(x, f)

# --- Column-spec abstraction -------------------------------------------------

"""
One column in one table. `extract` is invoked with whatever per-row context
the owning table's inserter passes (`Device` for devices; `(Device, idx, gate)`
for native_gates; etc.). All columns in a table share the same extract
arity — the table's inserter is responsible for the calling convention.
"""
struct ColumnSpec
    name::Symbol
    sql_type::String
    nullable::Bool
    extract::Function
end

_ddl(table::String, cols::Vector{ColumnSpec}, pk::Vector{Symbol}) =
    string("CREATE TABLE ", table, " (\n",
           join(("  $(c.name) $(c.sql_type)" * (c.nullable ? "" : " NOT NULL")
                 for c in cols), ",\n"),
           ",\n  PRIMARY KEY (", join(string.(pk), ", "), ")\n)")

_insert_sql(table::String, cols::Vector{ColumnSpec}) =
    string("INSERT INTO ", table, " (",
           join((string(c.name) for c in cols), ","),
           ") VALUES (", join(fill("?", length(cols)), ","), ")")

# --- Table specifications ----------------------------------------------------

const _DEVICES_TABLE = "devices"
const _DEVICES_PK    = [:id]

const _DEVICES_COLS = ColumnSpec[
    ColumnSpec(:id,                                 "TEXT",    false, d -> d.meta.id),
    ColumnSpec(:org_slug,                           "TEXT",    false, d -> d.meta.org_slug),
    ColumnSpec(:org_name,                           "TEXT",    false, d -> d.organization.name),
    ColumnSpec(:org_kind,                           "TEXT",    false, d -> String(d.organization.kind)),
    ColumnSpec(:org_country,                        "TEXT",    false, d -> d.organization.country),
    ColumnSpec(:org_parent,                         "TEXT",    true,  d -> d.organization.parent),
    ColumnSpec(:org_homepage_url,                   "TEXT",    true,  d -> d.organization.homepage_url),
    ColumnSpec(:family_name,                        "TEXT",    false, d -> d.family.name),
    ColumnSpec(:modality,                           "TEXT",    false, d -> String(d.family.modality)),
    ColumnSpec(:lineage_predecessor,                "TEXT",    true,  d -> d.family.lineage_predecessor),
    ColumnSpec(:device_name,                        "TEXT",    false, d -> d.device.name),
    ColumnSpec(:status,                             "TEXT",    false, d -> String(d.device.status)),
    ColumnSpec(:announced_date,                     "TEXT",    true,  d -> _iso(d.device.announced_date)),
    ColumnSpec(:first_operational_date,             "TEXT",    true,  d -> _iso(d.device.first_operational_date)),
    ColumnSpec(:decommissioned_date,                "TEXT",    true,  d -> _iso(d.device.decommissioned_date)),
    ColumnSpec(:num_qubits,                         "INTEGER", false, d -> d.device.num_qubits),
    ColumnSpec(:num_logical,                        "INTEGER", true,  d -> d.device.num_logical),
    ColumnSpec(:logical_code,                       "TEXT",    true,  d -> _sym_or_null(d.device.logical_code)),
    ColumnSpec(:code_distance,                      "INTEGER", true,  d -> d.device.code_distance),
    ColumnSpec(:architecture_notes,                 "TEXT",    true,  d -> d.device.architecture_notes),
    ColumnSpec(:topology_kind,                      "TEXT",    false, d -> String(d.topology.kind)),
    ColumnSpec(:topology_reconfigurable,            "BOOLEAN", false, d -> d.topology.reconfigurable),
    ColumnSpec(:topology_position_constraints_json, "TEXT",    true,  d -> _json_or_null(d.topology.position_constraints)),
    ColumnSpec(:topology_diagram_url,               "TEXT",    true,  d -> d.topology.diagram_url),
    ColumnSpec(:t1_us_mean,                         "DOUBLE",  true,  d -> _field(d.noise_model.t1_us, :mean)),
    ColumnSpec(:t1_us_median,                       "DOUBLE",  true,  d -> _field(d.noise_model.t1_us, :median)),
    ColumnSpec(:t2_kind,                            "TEXT",    true,  d -> _sym_or_null(_field(d.noise_model.t2_us, :kind))),
    ColumnSpec(:t2_us_mean,                         "DOUBLE",  true,  d -> _field(d.noise_model.t2_us, :mean)),
    ColumnSpec(:t2_us_median,                       "DOUBLE",  true,  d -> _field(d.noise_model.t2_us, :median)),
    ColumnSpec(:readout_fidelity_mean,              "DOUBLE",  true,  d -> _field(d.noise_model.readout, :fidelity_mean)),
    ColumnSpec(:readout_confusion_matrix_file,      "TEXT",    true,  d -> _field(d.noise_model.readout, :confusion_matrix_file)),
    ColumnSpec(:crosstalk_json,                     "TEXT",    true,  d -> _json_or_null(d.noise_model.crosstalk)),  # free-form: kept as JSON
    ColumnSpec(:single_qubit_gate_ns,               "DOUBLE",  false, d -> d.timing.single_qubit_gate_ns),
    ColumnSpec(:two_qubit_gate_ns,                  "DOUBLE",  false, d -> d.timing.two_qubit_gate_ns),
    ColumnSpec(:readout_ns,                         "DOUBLE",  false, d -> d.timing.readout_ns),
    ColumnSpec(:reset_ns,                           "DOUBLE",  true,  d -> d.timing.reset_ns),
    ColumnSpec(:shot_rate_hz,                       "DOUBLE",  true,  d -> d.timing.shot_rate_hz),
    ColumnSpec(:queue_depth_notes,                  "TEXT",    true,  d -> d.timing.queue_depth_notes),
    ColumnSpec(:cloud_provider,                     "TEXT",    true,  d -> _sym_or_null(d.access.cloud_provider)),
    ColumnSpec(:api_kind,                           "TEXT",    false, d -> String(d.access.api_kind)),
    ColumnSpec(:api_endpoint,                       "TEXT",    true,  d -> d.access.api_endpoint),
    ColumnSpec(:tier,                               "TEXT",    false, d -> String(d.access.tier)),
    ColumnSpec(:auth_required,                      "BOOLEAN", false, d -> d.access.auth_required),
    ColumnSpec(:pricing_notes,                      "TEXT",    true,  d -> d.access.pricing_notes),
    ColumnSpec(:benchmarks_json,                    "TEXT",    true,  d -> _json_or_null(d.benchmarks)),  # free-form: kept as JSON
    ColumnSpec(:fridge_kw,                          "DOUBLE",  true,  d -> _field(d.energy_carbon, :fridge_kw)),
    ColumnSpec(:system_kw,                          "DOUBLE",  true,  d -> _field(d.energy_carbon, :system_kw)),
    ColumnSpec(:per_shot_j,                         "DOUBLE",  true,  d -> _field(d.energy_carbon, :per_shot_j)),
    ColumnSpec(:kgco2_per_shot,                     "DOUBLE",  true,  d -> _field(d.energy_carbon, :kgco2_per_shot)),
    ColumnSpec(:cooling_notes,                      "TEXT",    true,  d -> _field(d.energy_carbon, :cooling_notes)),
    ColumnSpec(:helium3_notes,                      "TEXT",    true,  d -> _field(d.energy_carbon, :helium3_notes)),
    ColumnSpec(:roadmap_targeted_year,              "INTEGER", true,  d -> _field(d.roadmap, :originally_targeted_year)),
    ColumnSpec(:roadmap_targeted_qubits,            "INTEGER", true,  d -> _field(d.roadmap, :originally_targeted_qubits)),
    ColumnSpec(:roadmap_targeted_logical,           "INTEGER", true,  d -> _field(d.roadmap, :originally_targeted_logical)),
    ColumnSpec(:roadmap_targeted_fidelity_1q,       "DOUBLE",  true,  d -> _field(d.roadmap, :originally_targeted_fidelity_1q)),
    ColumnSpec(:roadmap_targeted_fidelity_2q,       "DOUBLE",  true,  d -> _field(d.roadmap, :originally_targeted_fidelity_2q)),
    ColumnSpec(:roadmap_narrative,                  "TEXT",    true,  d -> _field(d.roadmap, :narrative)),
    ColumnSpec(:schema_version,                     "TEXT",    false, d -> d.meta.schema_version),
    ColumnSpec(:created_at,                         "TEXT",    false, d -> _iso(d.meta.created_at)),
    ColumnSpec(:updated_at,                         "TEXT",    false, d -> _iso(d.meta.updated_at)),
]

# Child tables — extract closures take (Device, ctx...) per-row context.

const _NATIVE_GATES_TABLE = "native_gates"
const _NATIVE_GATES_PK    = [:device_id, :gate_idx]
const _NATIVE_GATES_COLS = ColumnSpec[
    ColumnSpec(:device_id,               "TEXT",    false, (d, i, g) -> d.meta.id),
    ColumnSpec(:gate_idx,                "INTEGER", false, (d, i, g) -> i),
    ColumnSpec(:name,                    "TEXT",    false, (d, i, g) -> g.name),
    ColumnSpec(:arity,                   "INTEGER", false, (d, i, g) -> g.arity),
    ColumnSpec(:kind,                    "TEXT",    false, (d, i, g) -> String(g.kind)),
    ColumnSpec(:params_json,             "TEXT",    true,  (d, i, g) -> _json_or_null(g.params)),
    ColumnSpec(:duration_ns,             "DOUBLE",  true,  (d, i, g) -> g.duration_ns),
    ColumnSpec(:fidelity_mean,           "DOUBLE",  true,  (d, i, g) -> g.fidelity_mean),
    ColumnSpec(:fidelity_median,         "DOUBLE",  true,  (d, i, g) -> g.fidelity_median),
    ColumnSpec(:kraus_operators_file,    "TEXT",    true,  (d, i, g) -> g.kraus_operators_file),
    ColumnSpec(:ptm_file,                "TEXT",    true,  (d, i, g) -> g.ptm_file),
]

const _COUPLING_EDGES_TABLE = "coupling_edges"
const _COUPLING_EDGES_PK    = [:device_id, :qubit_a, :qubit_b]
const _COUPLING_EDGES_COLS = ColumnSpec[
    ColumnSpec(:device_id, "TEXT",    false, (d, e) -> d.meta.id),
    ColumnSpec(:qubit_a,   "INTEGER", false, (d, e) -> e[1]),
    ColumnSpec(:qubit_b,   "INTEGER", false, (d, e) -> e[2]),
]

const _SNAPSHOTS_TABLE = "calibration_snapshots"
const _SNAPSHOTS_PK    = [:device_id, :ts]
const _SNAPSHOTS_COLS = ColumnSpec[
    ColumnSpec(:device_id,        "TEXT",    false, (d, s) -> d.meta.id),
    ColumnSpec(:ts,               "TEXT",    false, (d, s) -> _iso(s.timestamp)),
    ColumnSpec(:t1_us_mean,       "DOUBLE",  true,  (d, s) -> s.t1_us_mean),
    ColumnSpec(:t2_us_mean,       "DOUBLE",  true,  (d, s) -> s.t2_us_mean),
    ColumnSpec(:gate_err_1q_mean, "DOUBLE",  true,  (d, s) -> s.gate_err_1q_mean),
    ColumnSpec(:gate_err_2q_mean, "DOUBLE",  true,  (d, s) -> s.gate_err_2q_mean),
    ColumnSpec(:readout_err_mean, "DOUBLE",  true,  (d, s) -> s.readout_err_mean),
    ColumnSpec(:raw_file,         "TEXT",    false, (d, s) -> s.raw_file),
    ColumnSpec(:provenance_idx,   "INTEGER", false, (d, s) -> s.provenance_idx),
]

const _SNAPSHOTS_TABLE = "calibration_snapshots"  # (forward-compat ordering preserved below)

# --- Denormalized child tables (e82) ----------------------------------------
# JSON-in-TEXT was the original encoding for tall list-shaped fields. These
# tables make analytical queries (e.g. "count devices with mean T1 > X")
# index- and SQL-friendly. The original JSON columns are gone.
#
# Free-form structures (`crosstalk`, `position_constraints`, `benchmarks`,
# `native_gates.params`) keep their `*_json` text columns — they have no
# stable inner schema worth a child table. Use DuckDB's `json_extract` /
# `->`/`->>` to query into them.

const _DEVICE_ALIASES_TABLE = "device_aliases"
const _DEVICE_ALIASES_PK    = [:device_id, :alias_idx]
const _DEVICE_ALIASES_COLS = ColumnSpec[
    ColumnSpec(:device_id, "TEXT",    false, (d, i, a) -> d.meta.id),
    ColumnSpec(:alias_idx, "INTEGER", false, (d, i, a) -> i),
    ColumnSpec(:alias,     "TEXT",    false, (d, i, a) -> a),
]

const _DEVICE_SDK_PACKAGES_TABLE = "device_sdk_packages"
const _DEVICE_SDK_PACKAGES_PK    = [:device_id, :pkg_idx]
const _DEVICE_SDK_PACKAGES_COLS = ColumnSpec[
    ColumnSpec(:device_id, "TEXT",    false, (d, i, p) -> d.meta.id),
    ColumnSpec(:pkg_idx,   "INTEGER", false, (d, i, p) -> i),
    ColumnSpec(:package,   "TEXT",    false, (d, i, p) -> p),
]

# One row per (device, qubit) when ANY per-qubit calibration field is populated.
# t1_us / t2_us / readout_fidelity NULL for unmeasured slots.
const _QUBIT_COHERENCE_TABLE = "qubit_coherence"
const _QUBIT_COHERENCE_PK    = [:device_id, :qubit_idx]
const _QUBIT_COHERENCE_COLS = ColumnSpec[
    ColumnSpec(:device_id,         "TEXT",    false, (d, q, t1, t2, ro) -> d.meta.id),
    ColumnSpec(:qubit_idx,         "INTEGER", false, (d, q, t1, t2, ro) -> q),
    ColumnSpec(:t1_us,             "DOUBLE",  true,  (d, q, t1, t2, ro) -> t1),
    ColumnSpec(:t2_us,             "DOUBLE",  true,  (d, q, t1, t2, ro) -> t2),
    ColumnSpec(:readout_fidelity,  "DOUBLE",  true,  (d, q, t1, t2, ro) -> ro),
]

const _GATE_QUBIT_FIDELITY_TABLE = "gate_qubit_fidelity"
const _GATE_QUBIT_FIDELITY_PK    = [:device_id, :gate_idx, :qubit_idx]
const _GATE_QUBIT_FIDELITY_COLS = ColumnSpec[
    ColumnSpec(:device_id, "TEXT",    false, (d, gi, qi, f) -> d.meta.id),
    ColumnSpec(:gate_idx,  "INTEGER", false, (d, gi, qi, f) -> gi),
    ColumnSpec(:qubit_idx, "INTEGER", false, (d, gi, qi, f) -> qi),
    ColumnSpec(:fidelity,  "DOUBLE",  false, (d, gi, qi, f) -> f),
]

const _GATE_PAIR_FIDELITY_TABLE = "gate_pair_fidelity"
const _GATE_PAIR_FIDELITY_PK    = [:device_id, :gate_idx, :qubit_a, :qubit_b]
const _GATE_PAIR_FIDELITY_COLS = ColumnSpec[
    ColumnSpec(:device_id, "TEXT",    false, (d, gi, fp) -> d.meta.id),
    ColumnSpec(:gate_idx,  "INTEGER", false, (d, gi, fp) -> gi),
    ColumnSpec(:qubit_a,   "INTEGER", false, (d, gi, fp) -> fp.pair[1]),
    ColumnSpec(:qubit_b,   "INTEGER", false, (d, gi, fp) -> fp.pair[2]),
    ColumnSpec(:fidelity,  "DOUBLE",  false, (d, gi, fp) -> fp.fidelity),
]

const _PROVENANCE_TABLE = "provenance"
const _PROVENANCE_PK    = [:device_id, :prov_idx]
const _PROVENANCE_COLS = ColumnSpec[
    ColumnSpec(:device_id,    "TEXT",    false, (d, i, p) -> d.meta.id),
    ColumnSpec(:prov_idx,     "INTEGER", false, (d, i, p) -> i),
    ColumnSpec(:field_path,   "TEXT",    false, (d, i, p) -> p.field_path),
    ColumnSpec(:value_json,   "TEXT",    false, (d, i, p) -> JSON3.write(p.value)),
    ColumnSpec(:source_url,   "TEXT",    false, (d, i, p) -> p.source_url),
    ColumnSpec(:source_kind,  "TEXT",    false, (d, i, p) -> String(p.source_kind)),
    ColumnSpec(:retrieved_at, "TEXT",    false, (d, i, p) -> _iso(p.retrieved_at)),
    ColumnSpec(:local_path,   "TEXT",    false, (d, i, p) -> p.local_path),
    ColumnSpec(:sha256,       "TEXT",    false, (d, i, p) -> p.sha256),
    ColumnSpec(:notes,        "TEXT",    true,  (d, i, p) -> p.notes),
    ColumnSpec(:conflict,     "BOOLEAN", false, (d, i, p) -> p.conflict),
]

# --- Connection + table creation --------------------------------------------

function _connect(path::AbstractString, backend::Symbol)
    isfile(path) && rm(path)
    mkpath(dirname(path))
    if backend === :duckdb
        return DBInterface.connect(DuckDB.DB, path)
    elseif backend === :sqlite
        return DBInterface.connect(SQLite.DB, path)
    else
        error("unknown backend `$backend` — use :duckdb or :sqlite")
    end
end

function _create_tables(conn)
    DBInterface.execute(conn, _ddl(_DEVICES_TABLE,             _DEVICES_COLS,             _DEVICES_PK))
    DBInterface.execute(conn, _ddl(_NATIVE_GATES_TABLE,        _NATIVE_GATES_COLS,        _NATIVE_GATES_PK))
    DBInterface.execute(conn, _ddl(_COUPLING_EDGES_TABLE,      _COUPLING_EDGES_COLS,      _COUPLING_EDGES_PK))
    DBInterface.execute(conn, _ddl(_SNAPSHOTS_TABLE,           _SNAPSHOTS_COLS,           _SNAPSHOTS_PK))
    DBInterface.execute(conn, _ddl(_PROVENANCE_TABLE,          _PROVENANCE_COLS,          _PROVENANCE_PK))
    DBInterface.execute(conn, _ddl(_DEVICE_ALIASES_TABLE,      _DEVICE_ALIASES_COLS,      _DEVICE_ALIASES_PK))
    DBInterface.execute(conn, _ddl(_DEVICE_SDK_PACKAGES_TABLE, _DEVICE_SDK_PACKAGES_COLS, _DEVICE_SDK_PACKAGES_PK))
    DBInterface.execute(conn, _ddl(_QUBIT_COHERENCE_TABLE,     _QUBIT_COHERENCE_COLS,     _QUBIT_COHERENCE_PK))
    DBInterface.execute(conn, _ddl(_GATE_QUBIT_FIDELITY_TABLE, _GATE_QUBIT_FIDELITY_COLS, _GATE_QUBIT_FIDELITY_PK))
    DBInterface.execute(conn, _ddl(_GATE_PAIR_FIDELITY_TABLE,  _GATE_PAIR_FIDELITY_COLS,  _GATE_PAIR_FIDELITY_PK))
end

# --- Per-table inserters -----------------------------------------------------
# Each calls its column specs' `extract` with the per-row context. Because
# column names + extractors live in the same ColumnSpec, drift is impossible.

function _insert_devices(conn, dev::Device)
    sql = _insert_sql(_DEVICES_TABLE, _DEVICES_COLS)
    vals = Tuple(c.extract(dev) for c in _DEVICES_COLS)
    DBInterface.execute(conn, sql, vals)
end

function _insert_native_gates(conn, dev::Device)
    sql = _insert_sql(_NATIVE_GATES_TABLE, _NATIVE_GATES_COLS)
    for (i, g) in pairs(dev.native_gates)
        vals = Tuple(c.extract(dev, i, g) for c in _NATIVE_GATES_COLS)
        DBInterface.execute(conn, sql, vals)
    end
end

function _insert_coupling_edges(conn, dev::Device)
    dev.topology.coupling_map === nothing && return
    sql = _insert_sql(_COUPLING_EDGES_TABLE, _COUPLING_EDGES_COLS)
    for e in dev.topology.coupling_map
        vals = Tuple(c.extract(dev, e) for c in _COUPLING_EDGES_COLS)
        DBInterface.execute(conn, sql, vals)
    end
end

function _insert_snapshots(conn, dev::Device)
    sql = _insert_sql(_SNAPSHOTS_TABLE, _SNAPSHOTS_COLS)
    for s in dev.calibration_snapshots
        vals = Tuple(c.extract(dev, s) for c in _SNAPSHOTS_COLS)
        DBInterface.execute(conn, sql, vals)
    end
end

function _insert_provenance(conn, dev::Device)
    sql = _insert_sql(_PROVENANCE_TABLE, _PROVENANCE_COLS)
    for (i, p) in pairs(dev.provenance)
        vals = Tuple(c.extract(dev, i, p) for c in _PROVENANCE_COLS)
        DBInterface.execute(conn, sql, vals)
    end
end

function _insert_device_aliases(conn, dev::Device)
    isempty(dev.meta.aliases) && return 0
    sql = _insert_sql(_DEVICE_ALIASES_TABLE, _DEVICE_ALIASES_COLS)
    for (i, a) in pairs(dev.meta.aliases)
        DBInterface.execute(conn, sql, Tuple(c.extract(dev, i, a) for c in _DEVICE_ALIASES_COLS))
    end
    return length(dev.meta.aliases)
end

function _insert_sdk_packages(conn, dev::Device)
    isempty(dev.access.sdk_packages) && return 0
    sql = _insert_sql(_DEVICE_SDK_PACKAGES_TABLE, _DEVICE_SDK_PACKAGES_COLS)
    for (i, p) in pairs(dev.access.sdk_packages)
        DBInterface.execute(conn, sql, Tuple(c.extract(dev, i, p) for c in _DEVICE_SDK_PACKAGES_COLS))
    end
    return length(dev.access.sdk_packages)
end

# Per-qubit coherence: emit one row per qubit when ANY of t1/t2/readout per_qubit
# is populated. NULLs fill the unmeasured slots.
function _insert_qubit_coherence(conn, dev::Device)
    nm = dev.noise_model
    t1_per = _field(nm.t1_us,   :per_qubit)
    t2_per = _field(nm.t2_us,   :per_qubit)
    ro_per = _field(nm.readout, :fidelity_per_qubit)
    (t1_per === nothing && t2_per === nothing && ro_per === nothing) && return 0
    n = dev.device.num_qubits
    sql = _insert_sql(_QUBIT_COHERENCE_TABLE, _QUBIT_COHERENCE_COLS)
    for q in 0:(n-1)
        t1 = t1_per === nothing || q+1 > length(t1_per) ? nothing : t1_per[q+1]
        t2 = t2_per === nothing || q+1 > length(t2_per) ? nothing : t2_per[q+1]
        ro = ro_per === nothing || q+1 > length(ro_per) ? nothing : ro_per[q+1]
        DBInterface.execute(conn, sql,
            Tuple(c.extract(dev, q, t1, t2, ro) for c in _QUBIT_COHERENCE_COLS))
    end
    return n
end

function _insert_gate_qubit_fidelity(conn, dev::Device)
    sql = _insert_sql(_GATE_QUBIT_FIDELITY_TABLE, _GATE_QUBIT_FIDELITY_COLS)
    n = 0
    for (gi, g) in pairs(dev.native_gates)
        g.fidelity_per_qubit === nothing && continue
        for (qi, f) in pairs(g.fidelity_per_qubit)
            f === nothing && continue
            DBInterface.execute(conn, sql,
                Tuple(c.extract(dev, gi, qi - 1, f) for c in _GATE_QUBIT_FIDELITY_COLS))
            n += 1
        end
    end
    return n
end

function _insert_gate_pair_fidelity(conn, dev::Device)
    sql = _insert_sql(_GATE_PAIR_FIDELITY_TABLE, _GATE_PAIR_FIDELITY_COLS)
    n = 0
    for (gi, g) in pairs(dev.native_gates)
        g.fidelity_per_pair === nothing && continue
        for fp in g.fidelity_per_pair
            DBInterface.execute(conn, sql,
                Tuple(c.extract(dev, gi, fp) for c in _GATE_PAIR_FIDELITY_COLS))
            n += 1
        end
    end
    return n
end

# --- Public API --------------------------------------------------------------

"""
    build_db(output_path; backend=:duckdb, devices=nothing) -> NamedTuple

Compile the devices corpus into a DB at `output_path`. Overwrites any
existing file at that path. Returns a NamedTuple of row counts.

`backend` ∈ `(:duckdb, :sqlite)`. `devices` may be a preloaded
`Dict{String, Device}`; omit to load from `corpus_root()`.
"""
function build_db(output_path::AbstractString;
                  backend::Symbol = :duckdb,
                  devices::Union{Nothing, AbstractDict} = nothing)
    corpus = devices === nothing ? load_all_devices() : devices
    conn = _connect(output_path, backend)
    try
        _create_tables(conn)
        n_devices = n_gates = n_edges = n_snaps = n_prov = 0
        n_aliases = n_pkgs = n_qcoh = n_gqfid = n_gpfid = 0
        for id in sort!(collect(keys(corpus)))
            dev = corpus[id]
            _insert_devices(conn, dev)
            _insert_native_gates(conn, dev)
            _insert_coupling_edges(conn, dev)
            _insert_snapshots(conn, dev)
            _insert_provenance(conn, dev)
            n_aliases += _insert_device_aliases(conn, dev)
            n_pkgs    += _insert_sdk_packages(conn, dev)
            n_qcoh    += _insert_qubit_coherence(conn, dev)
            n_gqfid   += _insert_gate_qubit_fidelity(conn, dev)
            n_gpfid   += _insert_gate_pair_fidelity(conn, dev)
            n_devices += 1
            n_gates   += length(dev.native_gates)
            n_edges   += dev.topology.coupling_map === nothing ? 0 : length(dev.topology.coupling_map)
            n_snaps   += length(dev.calibration_snapshots)
            n_prov    += length(dev.provenance)
        end
        return (; devices=n_devices, native_gates=n_gates, coupling_edges=n_edges,
                calibration_snapshots=n_snaps, provenance=n_prov,
                device_aliases=n_aliases, device_sdk_packages=n_pkgs,
                qubit_coherence=n_qcoh, gate_qubit_fidelity=n_gqfid,
                gate_pair_fidelity=n_gpfid,
                backend, path=output_path)
    finally
        DBInterface.close!(conn)
    end
end
