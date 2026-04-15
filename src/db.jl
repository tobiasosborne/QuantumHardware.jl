# Compile the TOML corpus into a query-ready DuckDB (primary) or SQLite
# (fallback) artefact. Never hand-edit the output — regenerate from scratch.
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

const _DDL = (
    """
    CREATE TABLE devices (
        id TEXT PRIMARY KEY,
        org_slug TEXT NOT NULL,
        org_name TEXT NOT NULL,
        org_kind TEXT NOT NULL,
        org_country TEXT NOT NULL,
        org_parent TEXT,
        org_homepage_url TEXT,
        family_name TEXT NOT NULL,
        modality TEXT NOT NULL,
        lineage_predecessor TEXT,
        device_name TEXT NOT NULL,
        status TEXT NOT NULL,
        announced_date TEXT,
        first_operational_date TEXT,
        decommissioned_date TEXT,
        num_qubits INTEGER NOT NULL,
        num_logical INTEGER,
        logical_code TEXT,
        code_distance INTEGER,
        architecture_notes TEXT,
        topology_kind TEXT NOT NULL,
        topology_reconfigurable BOOLEAN NOT NULL,
        topology_position_constraints_json TEXT,
        topology_diagram_url TEXT,
        t1_us_mean DOUBLE,
        t1_us_median DOUBLE,
        t1_us_per_qubit_json TEXT,
        t2_kind TEXT,
        t2_us_mean DOUBLE,
        t2_us_median DOUBLE,
        t2_us_per_qubit_json TEXT,
        readout_fidelity_mean DOUBLE,
        readout_fidelity_per_qubit_json TEXT,
        readout_confusion_matrix_file TEXT,
        crosstalk_json TEXT,
        single_qubit_gate_ns DOUBLE NOT NULL,
        two_qubit_gate_ns DOUBLE NOT NULL,
        readout_ns DOUBLE NOT NULL,
        reset_ns DOUBLE,
        shot_rate_hz DOUBLE,
        queue_depth_notes TEXT,
        cloud_provider TEXT,
        api_kind TEXT NOT NULL,
        api_endpoint TEXT,
        tier TEXT NOT NULL,
        auth_required BOOLEAN NOT NULL,
        pricing_notes TEXT,
        sdk_packages_json TEXT,
        benchmarks_json TEXT,
        fridge_kw DOUBLE,
        system_kw DOUBLE,
        per_shot_j DOUBLE,
        kgco2_per_shot DOUBLE,
        cooling_notes TEXT,
        helium3_notes TEXT,
        roadmap_targeted_year INTEGER,
        roadmap_targeted_qubits INTEGER,
        roadmap_targeted_logical INTEGER,
        roadmap_targeted_fidelity_1q DOUBLE,
        roadmap_targeted_fidelity_2q DOUBLE,
        roadmap_narrative TEXT,
        aliases_json TEXT,
        schema_version TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE native_gates (
        device_id TEXT NOT NULL,
        gate_idx INTEGER NOT NULL,
        name TEXT NOT NULL,
        arity INTEGER NOT NULL,
        kind TEXT NOT NULL,
        params_json TEXT,
        duration_ns DOUBLE,
        fidelity_mean DOUBLE,
        fidelity_median DOUBLE,
        fidelity_per_qubit_json TEXT,
        fidelity_per_pair_json TEXT,
        kraus_operators_file TEXT,
        ptm_file TEXT,
        PRIMARY KEY (device_id, gate_idx)
    )
    """,
    """
    CREATE TABLE coupling_edges (
        device_id TEXT NOT NULL,
        qubit_a INTEGER NOT NULL,
        qubit_b INTEGER NOT NULL,
        PRIMARY KEY (device_id, qubit_a, qubit_b)
    )
    """,
    """
    CREATE TABLE calibration_snapshots (
        device_id TEXT NOT NULL,
        ts TEXT NOT NULL,
        t1_us_mean DOUBLE,
        t2_us_mean DOUBLE,
        gate_err_1q_mean DOUBLE,
        gate_err_2q_mean DOUBLE,
        readout_err_mean DOUBLE,
        raw_file TEXT NOT NULL,
        provenance_idx INTEGER NOT NULL,
        PRIMARY KEY (device_id, ts)
    )
    """,
    """
    CREATE TABLE provenance (
        device_id TEXT NOT NULL,
        prov_idx INTEGER NOT NULL,
        field_path TEXT NOT NULL,
        value_json TEXT NOT NULL,
        source_url TEXT NOT NULL,
        source_kind TEXT NOT NULL,
        retrieved_at TEXT NOT NULL,
        local_path TEXT NOT NULL,
        sha256 TEXT NOT NULL,
        notes TEXT,
        conflict BOOLEAN NOT NULL,
        PRIMARY KEY (device_id, prov_idx)
    )
    """,
)

_iso(d::Date)     = string(d)
_iso(t::DateTime) = Dates.format(t, dateformat"yyyy-mm-ddTHH:MM:SS")
_iso(::Nothing)   = nothing

_json_or_null(::Nothing) = nothing
_json_or_null(x)         = JSON3.write(x)

_sym_or_null(::Nothing) = nothing
_sym_or_null(s::Symbol) = String(s)

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
    for ddl in _DDL
        DBInterface.execute(conn, ddl)
    end
end

# Columns for the `devices` table, in DDL order. Must stay in lockstep with
# `_device_values` and the CREATE TABLE above — a mismatch surfaces loudly at
# INSERT time rather than silently shifting columns.
const _DEVICE_COLUMNS = (
    :id, :org_slug, :org_name, :org_kind, :org_country, :org_parent, :org_homepage_url,
    :family_name, :modality, :lineage_predecessor,
    :device_name, :status,
    :announced_date, :first_operational_date, :decommissioned_date,
    :num_qubits, :num_logical, :logical_code, :code_distance, :architecture_notes,
    :topology_kind, :topology_reconfigurable,
    :topology_position_constraints_json, :topology_diagram_url,
    :t1_us_mean, :t1_us_median, :t1_us_per_qubit_json,
    :t2_kind, :t2_us_mean, :t2_us_median, :t2_us_per_qubit_json,
    :readout_fidelity_mean, :readout_fidelity_per_qubit_json, :readout_confusion_matrix_file,
    :crosstalk_json,
    :single_qubit_gate_ns, :two_qubit_gate_ns, :readout_ns, :reset_ns,
    :shot_rate_hz, :queue_depth_notes,
    :cloud_provider, :api_kind, :api_endpoint, :tier, :auth_required,
    :pricing_notes, :sdk_packages_json,
    :benchmarks_json,
    :fridge_kw, :system_kw, :per_shot_j, :kgco2_per_shot, :cooling_notes, :helium3_notes,
    :roadmap_targeted_year, :roadmap_targeted_qubits, :roadmap_targeted_logical,
    :roadmap_targeted_fidelity_1q, :roadmap_targeted_fidelity_2q, :roadmap_narrative,
    :aliases_json,
    :schema_version, :created_at, :updated_at,
)

function _device_values(dev::Device)
    topo = dev.topology
    nm   = dev.noise_model
    t1   = nm.t1_us
    t2   = nm.t2_us
    ro   = nm.readout
    rd   = dev.roadmap
    ec   = dev.energy_carbon
    return (
        dev.meta.id,
        dev.meta.org_slug,
        dev.organization.name,
        String(dev.organization.kind),
        dev.organization.country,
        dev.organization.parent,
        dev.organization.homepage_url,
        dev.family.name,
        String(dev.family.modality),
        dev.family.lineage_predecessor,
        dev.device.name,
        String(dev.device.status),
        _iso(dev.device.announced_date),
        _iso(dev.device.first_operational_date),
        _iso(dev.device.decommissioned_date),
        dev.device.num_qubits,
        dev.device.num_logical,
        _sym_or_null(dev.device.logical_code),
        dev.device.code_distance,
        dev.device.architecture_notes,
        String(topo.kind),
        topo.reconfigurable,
        _json_or_null(topo.position_constraints),
        topo.diagram_url,
        t1 === nothing ? nothing : t1.mean,
        t1 === nothing ? nothing : t1.median,
        t1 === nothing ? nothing : _json_or_null(t1.per_qubit),
        t2 === nothing ? nothing : _sym_or_null(t2.kind),
        t2 === nothing ? nothing : t2.mean,
        t2 === nothing ? nothing : t2.median,
        t2 === nothing ? nothing : _json_or_null(t2.per_qubit),
        ro === nothing ? nothing : ro.fidelity_mean,
        ro === nothing ? nothing : _json_or_null(ro.fidelity_per_qubit),
        ro === nothing ? nothing : ro.confusion_matrix_file,
        _json_or_null(nm.crosstalk),
        dev.timing.single_qubit_gate_ns,
        dev.timing.two_qubit_gate_ns,
        dev.timing.readout_ns,
        dev.timing.reset_ns,
        dev.timing.shot_rate_hz,
        dev.timing.queue_depth_notes,
        _sym_or_null(dev.access.cloud_provider),
        String(dev.access.api_kind),
        dev.access.api_endpoint,
        String(dev.access.tier),
        dev.access.auth_required,
        dev.access.pricing_notes,
        _json_or_null(dev.access.sdk_packages),
        _json_or_null(dev.benchmarks),
        ec === nothing ? nothing : ec.fridge_kw,
        ec === nothing ? nothing : ec.system_kw,
        ec === nothing ? nothing : ec.per_shot_j,
        ec === nothing ? nothing : ec.kgco2_per_shot,
        ec === nothing ? nothing : ec.cooling_notes,
        ec === nothing ? nothing : ec.helium3_notes,
        rd === nothing ? nothing : rd.originally_targeted_year,
        rd === nothing ? nothing : rd.originally_targeted_qubits,
        rd === nothing ? nothing : rd.originally_targeted_logical,
        rd === nothing ? nothing : rd.originally_targeted_fidelity_1q,
        rd === nothing ? nothing : rd.originally_targeted_fidelity_2q,
        rd === nothing ? nothing : rd.narrative,
        _json_or_null(dev.meta.aliases),
        dev.meta.schema_version,
        _iso(dev.meta.created_at),
        _iso(dev.meta.updated_at),
    )
end

const _DEVICE_INSERT_SQL = string(
    "INSERT INTO devices (",
    join(string.(_DEVICE_COLUMNS), ","),
    ") VALUES (",
    join(fill("?", length(_DEVICE_COLUMNS)), ","),
    ")",
)

function _insert_device(conn, dev::Device)
    vals = _device_values(dev)
    length(vals) == length(_DEVICE_COLUMNS) ||
        error("devices insert: $(length(vals)) values for $(length(_DEVICE_COLUMNS)) columns")
    DBInterface.execute(conn, _DEVICE_INSERT_SQL, vals)
end

function _insert_native_gates(conn, dev::Device)
    for (i, g) in pairs(dev.native_gates)
        DBInterface.execute(conn,
            "INSERT INTO native_gates VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                dev.meta.id, i,
                g.name, g.arity, String(g.kind),
                _json_or_null(g.params),
                g.duration_ns, g.fidelity_mean, g.fidelity_median,
                _json_or_null(g.fidelity_per_qubit),
                _json_or_null(g.fidelity_per_pair),
                g.kraus_operators_file, g.ptm_file,
            ))
    end
end

function _insert_coupling_edges(conn, dev::Device)
    dev.topology.coupling_map === nothing && return
    for (a, b) in dev.topology.coupling_map
        DBInterface.execute(conn,
            "INSERT INTO coupling_edges VALUES (?,?,?)",
            (dev.meta.id, a, b))
    end
end

function _insert_snapshots(conn, dev::Device)
    for s in dev.calibration_snapshots
        DBInterface.execute(conn,
            "INSERT INTO calibration_snapshots VALUES (?,?,?,?,?,?,?,?,?)",
            (
                dev.meta.id, _iso(s.timestamp),
                s.t1_us_mean, s.t2_us_mean,
                s.gate_err_1q_mean, s.gate_err_2q_mean, s.readout_err_mean,
                s.raw_file, s.provenance_idx,
            ))
    end
end

function _insert_provenance(conn, dev::Device)
    for (i, p) in pairs(dev.provenance)
        DBInterface.execute(conn,
            "INSERT INTO provenance VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (
                dev.meta.id, i,
                p.field_path, JSON3.write(p.value),
                p.source_url, String(p.source_kind),
                _iso(p.retrieved_at),
                p.local_path, p.sha256,
                p.notes, p.conflict,
            ))
    end
end

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
        for id in sort!(collect(keys(corpus)))
            dev = corpus[id]
            _insert_device(conn, dev)
            _insert_native_gates(conn, dev)
            _insert_coupling_edges(conn, dev)
            _insert_snapshots(conn, dev)
            _insert_provenance(conn, dev)
            n_devices += 1
            n_gates   += length(dev.native_gates)
            n_edges   += dev.topology.coupling_map === nothing ? 0 : length(dev.topology.coupling_map)
            n_snaps   += length(dev.calibration_snapshots)
            n_prov    += length(dev.provenance)
        end
        return (; devices=n_devices, native_gates=n_gates, coupling_edges=n_edges,
                calibration_snapshots=n_snaps, provenance=n_prov, backend, path=output_path)
    finally
        DBInterface.close!(conn)
    end
end
