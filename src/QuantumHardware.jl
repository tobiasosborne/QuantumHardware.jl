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
include("db.jl")

export Device, DeviceMeta, Organization, DeviceFamily, DeviceRecord, Topology,
       NativeGate, FidelityPair, NoiseModel, CalibrationSnapshot, Timing, Access,
       EnergyCarbon, Roadmap, Provenance
export target_spec, find_devices, sturm_target, load_device, load_all_devices,
       each_device_toml, device_toml_paths, validate_device, validate_device_file, build_db

_project_path(parts...) = joinpath(pkgdir(@__MODULE__), parts...)

corpus_root()  = _project_path("devices")
sources_root() = _project_path("sources")
schema_path()  = _project_path("schema", "device.schema.json")

end # module
