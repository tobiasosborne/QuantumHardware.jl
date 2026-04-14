"""
    QuantumHardware

Public-sources-only database of quantum computing devices — past, present, projected,
commercial and academic. Consumer #1 is `Sturm.jl`'s `compile(ch, target=…)` pipeline.

Source-of-truth: `devices/<org>/<slug>.toml` per `DeviceRevision`. Compiled artefact:
DuckDB/SQLite built from the TOML corpus.

Public API (stable):
    target_spec(id::AbstractString) -> Device
    find_devices(; kwargs...) -> Vector{Device}
    sturm_target(dev::Device) -> NamedTuple

See `schema/SCHEMA.md` for the full entity model and field reference.
"""
module QuantumHardware

using TOML
using JSON3
using SHA
using Dates

include("schema.jl")
include("validator.jl")
include("loader.jl")
include("queries.jl")

export Device, DeviceMeta, Organization, DeviceFamily, DeviceRecord, Topology,
       NativeGate, NoiseModel, CalibrationSnapshot, Timing, Access, Benchmarks,
       EnergyCarbon, Roadmap, Provenance
export target_spec, find_devices, sturm_target, load_device, load_all_devices,
       validate_device, validate_device_file

"""
    corpus_root()

Absolute path to the root of the source-of-truth `devices/` tree, resolved
relative to the installed package location.
"""
function corpus_root()
    return joinpath(pkgdir(@__MODULE__), "devices")
end

"""
    sources_root()

Absolute path to the `sources/` archive tree.
"""
function sources_root()
    return joinpath(pkgdir(@__MODULE__), "sources")
end

"""
    schema_path()

Absolute path to `schema/device.schema.json`.
"""
function schema_path()
    return joinpath(pkgdir(@__MODULE__), "schema", "device.schema.json")
end

end # module
