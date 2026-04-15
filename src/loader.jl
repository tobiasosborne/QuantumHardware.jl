# Thin adapter: TOML-parsed Dict → Device struct tree.
# All validation lives upstream in `validator.jl`.
# AbstractDict-accepting outer constructors live next to each struct's
# field declaration in `schema.jl`'s ordering — collected here so the
# parsing-helper primitives (`_sym`, `_as_date`, `_maybe`) stay co-located
# with their consumers.

_sym(x::AbstractString) = Symbol(x)
_sym(::Nothing)         = nothing

_maybe(d::AbstractDict, k::AbstractString) = haskey(d, k) ? d[k] : nothing

_as_date(::Nothing)         = nothing
_as_date(d::Date)           = d
_as_date(s::AbstractString) = Date(s)
_as_date(x)                 = Date(x)

_as_datetime(::Nothing)         = nothing
_as_datetime(t::DateTime)       = t
_as_datetime(d::Date)           = DateTime(d)
_as_datetime(s::AbstractString) = DateTime(s)
_as_datetime(x)                 = DateTime(x)

# --- Outer constructors: TOML-dict → struct ----------------------------------

DeviceMeta(d::AbstractDict) = DeviceMeta(
    d["id"], d["org_slug"],
    get(d, "aliases", String[]),
    d["schema_version"],
    _as_datetime(d["created_at"]),
    _as_datetime(d["updated_at"]),
)

Organization(d::AbstractDict) = Organization(
    d["name"], _sym(d["kind"]), d["country"],
    _maybe(d, "parent"), _maybe(d, "homepage_url"),
)

DeviceFamily(d::AbstractDict) = DeviceFamily(
    d["name"], _sym(d["modality"]), _maybe(d, "lineage_predecessor"),
)

DeviceRecord(d::AbstractDict) = DeviceRecord(
    d["name"], _sym(d["status"]),
    _as_date(_maybe(d, "announced_date")),
    _as_date(_maybe(d, "first_operational_date")),
    _as_date(_maybe(d, "decommissioned_date")),
    d["num_qubits"],
    _maybe(d, "num_logical"),
    _sym(_maybe(d, "logical_code")),
    _maybe(d, "code_distance"),
    _maybe(d, "architecture_notes"),
)

function Topology(d::AbstractDict)
    cm = _maybe(d, "coupling_map")
    cm_tuples = cm === nothing ? nothing : Tuple{Int,Int}[(e[1], e[2]) for e in cm]
    Topology(
        _sym(d["kind"]), d["reconfigurable"], cm_tuples,
        _maybe(d, "position_constraints"),
        _maybe(d, "diagram_url"),
    )
end

function NativeGate(d::AbstractDict)
    fp = _maybe(d, "fidelity_per_pair")
    fp_vec = fp === nothing ? nothing :
             FidelityPair[FidelityPair((e["pair"][1], e["pair"][2]), e["fidelity"]) for e in fp]
    NativeGate(
        d["name"], d["arity"], _sym(d["kind"]),
        get(d, "params", String[]),
        _maybe(d, "duration_ns"),
        _maybe(d, "fidelity_mean"),
        _maybe(d, "fidelity_median"),
        _maybe(d, "fidelity_per_qubit"),
        fp_vec,
        _maybe(d, "kraus_operators_file"),
        _maybe(d, "ptm_file"),
    )
end

T1Block(d::AbstractDict) = T1Block(
    _maybe(d, "mean"), _maybe(d, "median"), _maybe(d, "per_qubit"),
)

T2Block(d::AbstractDict) = T2Block(
    _sym(_maybe(d, "kind")),
    _maybe(d, "mean"), _maybe(d, "median"), _maybe(d, "per_qubit"),
)

ReadoutBlock(d::AbstractDict) = ReadoutBlock(
    _maybe(d, "fidelity_mean"),
    _maybe(d, "fidelity_per_qubit"),
    _maybe(d, "confusion_matrix_file"),
)

NoiseModel(d::AbstractDict) = NoiseModel(
    haskey(d, "t1_us")   ? T1Block(d["t1_us"])     : nothing,
    haskey(d, "t2_us")   ? T2Block(d["t2_us"])     : nothing,
    haskey(d, "readout") ? ReadoutBlock(d["readout"]) : nothing,
    _maybe(d, "crosstalk"),
)

CalibrationSnapshot(d::AbstractDict) = CalibrationSnapshot(
    _as_datetime(d["timestamp"]),
    _maybe(d, "t1_us_mean"), _maybe(d, "t2_us_mean"),
    _maybe(d, "gate_err_1q_mean"), _maybe(d, "gate_err_2q_mean"),
    _maybe(d, "readout_err_mean"),
    d["raw_file"], d["provenance_idx"],
)

Timing(d::AbstractDict) = Timing(
    d["single_qubit_gate_ns"], d["two_qubit_gate_ns"], d["readout_ns"],
    _maybe(d, "reset_ns"), _maybe(d, "shot_rate_hz"),
    _maybe(d, "queue_depth_notes"),
)

Access(d::AbstractDict) = Access(
    _sym(_maybe(d, "cloud_provider")),
    _sym(d["api_kind"]),
    _maybe(d, "api_endpoint"),
    _sym(d["tier"]),
    d["auth_required"],
    _maybe(d, "pricing_notes"),
    get(d, "sdk_packages", String[]),
)

EnergyCarbon(d::AbstractDict) = EnergyCarbon(
    _maybe(d, "fridge_kw"), _maybe(d, "system_kw"),
    _maybe(d, "per_shot_j"), _maybe(d, "kgco2_per_shot"),
    _maybe(d, "cooling_notes"), _maybe(d, "helium3_notes"),
)

Roadmap(d::AbstractDict) = Roadmap(
    _maybe(d, "originally_targeted_year"),
    _maybe(d, "originally_targeted_qubits"),
    _maybe(d, "originally_targeted_logical"),
    _maybe(d, "originally_targeted_fidelity_1q"),
    _maybe(d, "originally_targeted_fidelity_2q"),
    _maybe(d, "narrative"),
)

Provenance(d::AbstractDict) = Provenance(
    d["field_path"], d["value"], d["source_url"], _sym(d["source_kind"]),
    _as_datetime(d["retrieved_at"]),
    d["local_path"], d["sha256"],
    _maybe(d, "notes"),
    get(d, "conflict", false),
)

Device(d::AbstractDict) = Device(
    DeviceMeta(d["meta"]),
    Organization(d["organization"]),
    DeviceFamily(d["family"]),
    DeviceRecord(d["device"]),
    Topology(d["topology"]),
    NativeGate[NativeGate(g) for g in d["native_gates"]],
    NoiseModel(d["noise_model"]),
    CalibrationSnapshot[CalibrationSnapshot(s) for s in get(d, "calibration_snapshots", [])],
    Timing(d["timing"]),
    Access(d["access"]),
    haskey(d, "benchmarks") ? d["benchmarks"] : nothing,
    haskey(d, "energy_carbon") ? EnergyCarbon(d["energy_carbon"]) : nothing,
    haskey(d, "roadmap") ? Roadmap(d["roadmap"]) : nothing,
    Provenance[Provenance(p) for p in d["provenance"]],
)

# --- Public API --------------------------------------------------------------

"""
    load_device(path::AbstractString) -> Device

Parse and validate a single device TOML file; return a typed `Device`.
"""
function load_device(path::AbstractString)
    dict = TOML.parsefile(path)
    validate_device(dict; filename=path)
    return Device(dict)
end

"""
    device_toml_paths(root::AbstractString = corpus_root()) -> Vector{String}

Sorted list of every `*.toml` file under `root`. Single canonical corpus walk;
every other site (loader, queries, scripts, tests) iterates this rather than
re-rolling `walkdir`. Sort order is deterministic (path-lexicographic) so
duplicate-id errors surface against a stable file.
"""
function device_toml_paths(root::AbstractString = corpus_root())
    paths = String[]
    for (dir, _, files) in walkdir(root)
        for fname in files
            endswith(fname, ".toml") && push!(paths, joinpath(dir, fname))
        end
    end
    sort!(paths)
    return paths
end

"""
    each_device_toml(f, root::AbstractString = corpus_root())

Apply `f(path)` to every device TOML. Convenience wrapper around
`device_toml_paths` — use this for side-effecting walks; use the underlying
`device_toml_paths` when you need to short-circuit on a match.
"""
each_device_toml(f, root::AbstractString = corpus_root()) =
    foreach(f, device_toml_paths(root))

"""
    load_all_devices(root::AbstractString = corpus_root()) -> Dict{String,Device}

Walk the `devices/` tree, load every `*.toml` into a `Device`, key by
`meta.id`. Throws on the first validation failure.
"""
function load_all_devices(root::AbstractString = corpus_root())
    devs = Dict{String, Device}()
    each_device_toml(root) do path
        dev = load_device(path)
        haskey(devs, dev.meta.id) && error("duplicate device id: $(dev.meta.id) at $path")
        devs[dev.meta.id] = dev
    end
    return devs
end
