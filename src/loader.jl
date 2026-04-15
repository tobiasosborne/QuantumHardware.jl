# Thin adapter layer: TOML-parsed Dict → Device struct tree.
# Kept deliberately dumb — all validation is upstream in `validator.jl`.

_sym(x::AbstractString) = Symbol(x)
_sym(::Nothing) = nothing

function _maybe(d::AbstractDict, k::AbstractString)
    haskey(d, k) ? d[k] : nothing
end

function _as_date(x)
    x === nothing      ? nothing :
    x isa Date         ? x       :
    Date(x)
end

function _as_datetime(x)
    x === nothing      ? nothing :
    x isa DateTime     ? x       :
    x isa Date         ? DateTime(x) :
    DateTime(x)
end

function _to_meta(d::AbstractDict)
    DeviceMeta(
        d["id"], d["org_slug"],
        get(d, "aliases", String[]),
        d["schema_version"],
        _as_datetime(d["created_at"]),
        _as_datetime(d["updated_at"]),
    )
end

function _to_org(d::AbstractDict)
    Organization(
        d["name"], _sym(d["kind"]), d["country"],
        _maybe(d, "parent"), _maybe(d, "homepage_url"),
    )
end

function _to_family(d::AbstractDict)
    DeviceFamily(d["name"], _sym(d["modality"]), _maybe(d, "lineage_predecessor"))
end

function _to_device(d::AbstractDict)
    DeviceRecord(
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
end

function _to_topology(d::AbstractDict)
    cm = _maybe(d, "coupling_map")
    cm_tuples = cm === nothing ? nothing : [(e[1], e[2]) for e in cm]
    Topology(
        _sym(d["kind"]), d["reconfigurable"], cm_tuples,
        _maybe(d, "position_constraints"),
        _maybe(d, "diagram_url"),
    )
end

function _to_gate(d::AbstractDict)
    NativeGate(
        d["name"], d["arity"], _sym(d["kind"]),
        get(d, "params", String[]),
        _maybe(d, "duration_ns"),
        _maybe(d, "fidelity_mean"),
        _maybe(d, "fidelity_median"),
        _maybe(d, "fidelity_per_qubit"),
        let pairs = _maybe(d, "fidelity_per_pair")
            pairs === nothing ? nothing :
            [FidelityPair((e["pair"][1], e["pair"][2]), e["fidelity"]) for e in pairs]
        end,
        _maybe(d, "kraus_operators_file"),
        _maybe(d, "ptm_file"),
    )
end

function _to_noise(d::AbstractDict)
    t1 = haskey(d, "t1_us") ? T1Block(
            _maybe(d["t1_us"], "mean"),
            _maybe(d["t1_us"], "median"),
            _maybe(d["t1_us"], "per_qubit")) : nothing
    t2 = haskey(d, "t2_us") ? T2Block(
            _sym(_maybe(d["t2_us"], "kind")),
            _maybe(d["t2_us"], "mean"),
            _maybe(d["t2_us"], "median"),
            _maybe(d["t2_us"], "per_qubit")) : nothing
    ro = haskey(d, "readout") ? ReadoutBlock(
            _maybe(d["readout"], "fidelity_mean"),
            _maybe(d["readout"], "fidelity_per_qubit"),
            _maybe(d["readout"], "confusion_matrix_file")) : nothing
    NoiseModel(t1, t2, ro, _maybe(d, "crosstalk"))
end

function _to_snap(d::AbstractDict)
    CalibrationSnapshot(
        _as_datetime(d["timestamp"]),
        _maybe(d, "t1_us_mean"), _maybe(d, "t2_us_mean"),
        _maybe(d, "gate_err_1q_mean"), _maybe(d, "gate_err_2q_mean"),
        _maybe(d, "readout_err_mean"),
        d["raw_file"], d["provenance_idx"],
    )
end

function _to_timing(d::AbstractDict)
    Timing(
        d["single_qubit_gate_ns"], d["two_qubit_gate_ns"], d["readout_ns"],
        _maybe(d, "reset_ns"), _maybe(d, "shot_rate_hz"),
        _maybe(d, "queue_depth_notes"),
    )
end

function _to_access(d::AbstractDict)
    Access(
        _sym(_maybe(d, "cloud_provider")),
        _sym(d["api_kind"]),
        _maybe(d, "api_endpoint"),
        _sym(d["tier"]),
        d["auth_required"],
        _maybe(d, "pricing_notes"),
        get(d, "sdk_packages", String[]),
    )
end

function _to_energy(d::AbstractDict)
    EnergyCarbon(
        _maybe(d, "fridge_kw"), _maybe(d, "system_kw"),
        _maybe(d, "per_shot_j"), _maybe(d, "kgco2_per_shot"),
        _maybe(d, "cooling_notes"), _maybe(d, "helium3_notes"),
    )
end

function _to_roadmap(d::AbstractDict)
    Roadmap(
        _maybe(d, "originally_targeted_year"),
        _maybe(d, "originally_targeted_qubits"),
        _maybe(d, "originally_targeted_logical"),
        _maybe(d, "originally_targeted_fidelity_1q"),
        _maybe(d, "originally_targeted_fidelity_2q"),
        _maybe(d, "narrative"),
    )
end

function _to_prov(d::AbstractDict)
    Provenance(
        d["field_path"], d["value"], d["source_url"], _sym(d["source_kind"]),
        _as_datetime(d["retrieved_at"]),
        d["local_path"], d["sha256"],
        _maybe(d, "notes"),
        get(d, "conflict", false),
    )
end

"""
    load_device(path::AbstractString) -> Device

Parse and validate a single device TOML file; return a typed `Device`.
"""
function load_device(path::AbstractString)
    dict = TOML.parsefile(path)
    validate_device(dict; filename=path)
    Device(
        _to_meta(dict["meta"]),
        _to_org(dict["organization"]),
        _to_family(dict["family"]),
        _to_device(dict["device"]),
        _to_topology(dict["topology"]),
        [_to_gate(g) for g in dict["native_gates"]],
        _to_noise(dict["noise_model"]),
        [_to_snap(s) for s in get(dict, "calibration_snapshots", [])],
        _to_timing(dict["timing"]),
        _to_access(dict["access"]),
        haskey(dict, "benchmarks") ? dict["benchmarks"] : nothing,
        haskey(dict, "energy_carbon") ? _to_energy(dict["energy_carbon"]) : nothing,
        haskey(dict, "roadmap") ? _to_roadmap(dict["roadmap"]) : nothing,
        [_to_prov(p) for p in dict["provenance"]],
    )
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
