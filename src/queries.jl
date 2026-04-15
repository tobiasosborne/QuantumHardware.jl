# Public API for downstream consumers (principally Sturm.jl).
# Keep stable — changes here ripple into Sturm's compile pipeline.
#
# Performance model (995):
#   - target_spec(id) hits a lazy id→path index (built on first call by
#     parsing every TOML's [meta] block once). O(1) lookup; one full
#     load_device on the matched file.
#   - find_devices(...) hits the DuckDB artefact for SQL-side filtering;
#     loads matched Devices from TOML on demand. Auto-builds the DB on
#     first call if missing.
#
# Both caches reset via `reload_corpus!()` after the corpus changes.

const _PATH_INDEX = Ref{Union{Nothing, Dict{String, String}}}(nothing)
const _DB_CONN    = Ref{Any}(nothing)
const _DB_PATH    = Ref{Union{Nothing, String}}(nothing)

# Build (or reuse) an id → toml-path index. Cached only when `root` is the
# default corpus_root(); a custom root falls back to a fresh walk every call.
function _path_index(root::AbstractString)
    cached = _PATH_INDEX[]
    if cached !== nothing && root == corpus_root()
        return cached
    end
    idx = Dict{String, String}()
    for path in device_toml_paths(root)
        toml = TOML.parsefile(path)
        haskey(toml, "meta") || continue
        id = toml["meta"]["id"]
        haskey(idx, id) && error("duplicate device id `$id` at $path")
        idx[id] = path
    end
    root == corpus_root() && (_PATH_INDEX[] = idx)
    return idx
end

# Lazy DuckDB connection. Auto-builds the artefact on first call if missing.
function _ensure_db()
    if _DB_CONN[] === nothing
        db_path = _project_path("db", "quantum-hardware.duckdb")
        if !isfile(db_path)
            @info "DuckDB artefact missing — building from corpus…" db_path
            build_db(db_path; backend=:duckdb)
        end
        _DB_CONN[] = DBInterface.connect(DuckDB.DB, db_path)
        _DB_PATH[] = db_path
    end
    return _DB_CONN[]
end

"""
    reload_corpus!()

Drop the cached path index and DuckDB connection so the next query rebuilds
from disk. Call after `build_db` or after editing the TOML corpus.
"""
function reload_corpus!()
    _PATH_INDEX[] = nothing
    _DB_CONN[] === nothing || DBInterface.close!(_DB_CONN[])
    _DB_CONN[] = nothing
    _DB_PATH[] = nothing
    return nothing
end

"""
    target_spec(id::AbstractString; root=corpus_root()) -> Device

Look up a device by its `meta.id` slug. O(1) on the cached path index.
Throws `KeyError` if not found.
"""
function target_spec(id::AbstractString; root::AbstractString = corpus_root())
    idx = _path_index(root)
    haskey(idx, id) || throw(KeyError(id))
    return load_device(idx[id])
end

"""
    find_devices(; kwargs...) -> Vector{Device}

Filter the corpus by:
- `min_qubits::Int`
- `max_qubits::Int`
- `modality::Symbol`
- `status::Symbol`
- `org_kind::Symbol`
- `cloud_provider::Symbol`
- `in_service_only::Bool` (shorthand for `status=:in_service`)

Returns matching `Device`s in alphabetical id order. Default-root calls go
through DuckDB for SQL-side filtering (auto-builds the artefact if missing);
custom-root calls fall back to a corpus walk.
"""
function find_devices(;
    root::AbstractString = corpus_root(),
    min_qubits::Union{Nothing, Int} = nothing,
    max_qubits::Union{Nothing, Int} = nothing,
    modality::Union{Nothing, Symbol} = nothing,
    status::Union{Nothing, Symbol} = nothing,
    org_kind::Union{Nothing, Symbol} = nothing,
    cloud_provider::Union{Nothing, Symbol} = nothing,
    in_service_only::Bool = false,
)
    effective_status = in_service_only ? :in_service : status
    if root != corpus_root()
        return _find_devices_walk(root, min_qubits, max_qubits, modality,
                                  effective_status, org_kind, cloud_provider)
    end

    db = _ensure_db()
    where = String[]
    params = Any[]
    if min_qubits !== nothing
        push!(where, "num_qubits >= ?"); push!(params, min_qubits)
    end
    if max_qubits !== nothing
        push!(where, "num_qubits <= ?"); push!(params, max_qubits)
    end
    if modality !== nothing
        push!(where, "modality = ?"); push!(params, String(modality))
    end
    if effective_status !== nothing
        push!(where, "status = ?"); push!(params, String(effective_status))
    end
    if org_kind !== nothing
        push!(where, "org_kind = ?"); push!(params, String(org_kind))
    end
    if cloud_provider !== nothing
        push!(where, "cloud_provider = ?"); push!(params, String(cloud_provider))
    end

    sql = "SELECT id FROM devices"
    isempty(where) || (sql *= " WHERE " * join(where, " AND "))
    sql *= " ORDER BY id"

    matched_ids = String[]
    for r in DBInterface.execute(db, sql, params)
        push!(matched_ids, r.id)
    end
    return Device[target_spec(id; root) for id in matched_ids]
end

# Fallback when the user points at a non-default corpus — no DB available.
function _find_devices_walk(root, min_qubits, max_qubits, modality,
                            effective_status, org_kind, cloud_provider)
    corpus = load_all_devices(root)
    matches = Device[]
    for (_, dev) in corpus
        min_qubits       !== nothing && dev.device.num_qubits  < min_qubits       && continue
        max_qubits       !== nothing && dev.device.num_qubits  > max_qubits       && continue
        modality         !== nothing && dev.family.modality   != modality         && continue
        effective_status !== nothing && dev.device.status     != effective_status && continue
        org_kind         !== nothing && dev.organization.kind != org_kind         && continue
        cloud_provider   !== nothing && dev.access.cloud_provider != cloud_provider && continue
        push!(matches, dev)
    end
    sort!(matches, by = d -> d.meta.id)
    return matches
end

# `sturm_target` lives in src/target.jl alongside the Target{M} struct.
