# Public API for downstream consumers (principally Sturm.jl).
# Keep stable — changes here ripple into Sturm's compile pipeline.

"""
    target_spec(id::AbstractString; root=corpus_root()) -> Device

Look up a device by its `meta.id` slug. Throws `KeyError` if not found.
"""
function target_spec(id::AbstractString; root::AbstractString = corpus_root())
    for path in device_toml_paths(root)
        toml = TOML.parsefile(path)
        haskey(toml, "meta") && toml["meta"]["id"] == id || continue
        return load_device(path)
    end
    throw(KeyError(id))
end

"""
    find_devices(; kwargs...) -> Vector{Device}

Filter the full corpus by combinations of:
- `min_qubits::Int`
- `max_qubits::Int`
- `modality::Symbol`
- `status::Symbol`
- `org_kind::Symbol`
- `cloud_provider::Symbol`
- `in_service_only::Bool` (shorthand for `status=:in_service`)

Returns a `Vector{Device}` in alphabetical id order. Filters with value
`nothing` (i.e. omitted kwargs) are skipped.
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
    corpus = load_all_devices(root)
    matches = Device[]
    effective_status = in_service_only ? :in_service : status
    for (_, dev) in corpus
        min_qubits      !== nothing && dev.device.num_qubits  < min_qubits      && continue
        max_qubits      !== nothing && dev.device.num_qubits  > max_qubits      && continue
        modality        !== nothing && dev.family.modality   != modality        && continue
        effective_status!== nothing && dev.device.status     != effective_status && continue
        org_kind        !== nothing && dev.organization.kind != org_kind        && continue
        cloud_provider  !== nothing && (dev.access.cloud_provider != cloud_provider) && continue
        push!(matches, dev)
    end
    sort!(matches, by = d -> d.meta.id)
    return matches
end

# `sturm_target` lives in src/target.jl alongside the Target{M} struct.
