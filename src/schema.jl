# Julia types mirroring schema/device.schema.json.
# Field names and shapes are mirrored manually; ENUM membership is
# loaded from the JSON Schema at module init (see ENUMS in QuantumHardware.jl)
# so there is one source of truth for enum values.

# --- Modality type hierarchy -------------------------------------------------
# One singleton type per `family.modality` enum value. Used as the type
# parameter of `Target{M}` so Sturm.jl's compile pipeline can dispatch on
# modality directly (e.g. `lower(dag, ::Target{NeutralAtom})`) instead of
# branching on a Symbol field.

abstract type AbstractModality end

struct SCTransmon          <: AbstractModality end
struct SCFluxonium         <: AbstractModality end
struct SCCat               <: AbstractModality end
struct SCDualRail          <: AbstractModality end
struct TrappedIon          <: AbstractModality end
struct NeutralAtom         <: AbstractModality end
struct PhotonicDiscrete    <: AbstractModality end
struct PhotonicCV          <: AbstractModality end
struct SiSpin              <: AbstractModality end
struct GeSpin              <: AbstractModality end
struct NVDiamond           <: AbstractModality end
struct SiCDefect           <: AbstractModality end
struct TopologicalMajorana <: AbstractModality end
struct NMR                 <: AbstractModality end
struct AnnealerDwave       <: AbstractModality end
struct AnnealerParametron  <: AbstractModality end
struct Molecular           <: AbstractModality end
struct RareEarthCavity     <: AbstractModality end

const MODALITY_TYPES = Dict{Symbol, Type{<:AbstractModality}}(
    :sc_transmon          => SCTransmon,
    :sc_fluxonium         => SCFluxonium,
    :sc_cat               => SCCat,
    :sc_dual_rail         => SCDualRail,
    :trapped_ion          => TrappedIon,
    :neutral_atom         => NeutralAtom,
    :photonic_discrete    => PhotonicDiscrete,
    :photonic_cv          => PhotonicCV,
    :si_spin              => SiSpin,
    :ge_spin              => GeSpin,
    :nv_diamond           => NVDiamond,
    :sic_defect           => SiCDefect,
    :topological_majorana => TopologicalMajorana,
    :nmr                  => NMR,
    :annealer_dwave       => AnnealerDwave,
    :annealer_parametron  => AnnealerParametron,
    :molecular            => Molecular,
    :rare_earth_cavity    => RareEarthCavity,
)

"""
    modality_type(::Symbol) -> Type{<:AbstractModality}

Resolve a `family.modality` enum value to its concrete singleton type.
"""
modality_type(s::Symbol) = MODALITY_TYPES[s]

struct DeviceMeta
    id::String
    org_slug::String
    aliases::Vector{String}
    schema_version::String
    created_at::DateTime
    updated_at::DateTime
end

struct Organization
    name::String
    kind::Symbol            # commercial | academic | national_lab | consortium | government
    country::String         # ISO 3166-1 alpha-3
    parent::Union{Nothing, String}
    homepage_url::Union{Nothing, String}
end

struct DeviceFamily
    name::String
    modality::Symbol
    lineage_predecessor::Union{Nothing, String}
end

struct DeviceRecord
    name::String
    status::Symbol
    announced_date::Union{Nothing, Date}
    first_operational_date::Union{Nothing, Date}
    decommissioned_date::Union{Nothing, Date}
    num_qubits::Int
    num_logical::Union{Nothing, Int}
    logical_code::Union{Nothing, Symbol}
    code_distance::Union{Nothing, Int}
    architecture_notes::Union{Nothing, String}
end

struct Topology
    kind::Symbol
    reconfigurable::Bool
    coupling_map::Union{Nothing, Vector{Tuple{Int,Int}}}
    position_constraints::Union{Nothing, Dict{String, Any}}
    diagram_url::Union{Nothing, String}
end

struct FidelityPair
    pair::Tuple{Int,Int}
    fidelity::Float64
end

struct NativeGate
    name::String
    arity::Int
    kind::Symbol            # gate | measurement | reset | idle | analog_hamiltonian
    params::Vector{String}
    duration_ns::Union{Nothing, Float64}
    fidelity_mean::Union{Nothing, Float64}
    fidelity_median::Union{Nothing, Float64}
    fidelity_per_qubit::Union{Nothing, Vector{Union{Nothing, Float64}}}
    fidelity_per_pair::Union{Nothing, Vector{FidelityPair}}
    kraus_operators_file::Union{Nothing, String}
    ptm_file::Union{Nothing, String}
end

struct T1Block
    mean::Union{Nothing, Float64}
    median::Union{Nothing, Float64}
    per_qubit::Union{Nothing, Vector{Union{Nothing, Float64}}}
end

struct T2Block
    kind::Union{Nothing, Symbol}   # ramsey | echo | cpmg
    mean::Union{Nothing, Float64}
    median::Union{Nothing, Float64}
    per_qubit::Union{Nothing, Vector{Union{Nothing, Float64}}}
end

struct ReadoutBlock
    fidelity_mean::Union{Nothing, Float64}
    fidelity_per_qubit::Union{Nothing, Vector{Union{Nothing, Float64}}}
    confusion_matrix_file::Union{Nothing, String}
end

struct NoiseModel
    t1_us::Union{Nothing, T1Block}
    t2_us::Union{Nothing, T2Block}
    readout::Union{Nothing, ReadoutBlock}
    crosstalk::Union{Nothing, Dict{String, Any}}
end

struct CalibrationSnapshot
    timestamp::DateTime
    t1_us_mean::Union{Nothing, Float64}
    t2_us_mean::Union{Nothing, Float64}
    gate_err_1q_mean::Union{Nothing, Float64}
    gate_err_2q_mean::Union{Nothing, Float64}
    readout_err_mean::Union{Nothing, Float64}
    raw_file::String
    provenance_idx::Int
end

struct Timing
    single_qubit_gate_ns::Float64
    two_qubit_gate_ns::Float64
    readout_ns::Float64
    reset_ns::Union{Nothing, Float64}
    shot_rate_hz::Union{Nothing, Float64}
    queue_depth_notes::Union{Nothing, String}
end

struct Access
    cloud_provider::Union{Nothing, Symbol}
    api_kind::Symbol
    api_endpoint::Union{Nothing, String}
    tier::Symbol
    auth_required::Bool
    pricing_notes::Union{Nothing, String}
    sdk_packages::Vector{String}
end

struct EnergyCarbon
    fridge_kw::Union{Nothing, Float64}
    system_kw::Union{Nothing, Float64}
    per_shot_j::Union{Nothing, Float64}
    kgco2_per_shot::Union{Nothing, Float64}
    cooling_notes::Union{Nothing, String}
    helium3_notes::Union{Nothing, String}
end

struct Roadmap
    originally_targeted_year::Union{Nothing, Int}
    originally_targeted_qubits::Union{Nothing, Int}
    originally_targeted_logical::Union{Nothing, Int}
    originally_targeted_fidelity_1q::Union{Nothing, Float64}
    originally_targeted_fidelity_2q::Union{Nothing, Float64}
    narrative::Union{Nothing, String}
end

struct Provenance
    field_path::String
    value::Any
    source_url::String
    source_kind::Symbol
    retrieved_at::DateTime
    local_path::String
    sha256::String
    notes::Union{Nothing, String}
    conflict::Bool
end

"""
Top-level typed representation of one device TOML file.
"""
struct Device
    meta::DeviceMeta
    organization::Organization
    family::DeviceFamily
    device::DeviceRecord
    topology::Topology
    native_gates::Vector{NativeGate}
    noise_model::NoiseModel
    calibration_snapshots::Vector{CalibrationSnapshot}
    timing::Timing
    access::Access
    benchmarks::Union{Nothing, Dict{String, Any}}
    energy_carbon::Union{Nothing, EnergyCarbon}
    roadmap::Union{Nothing, Roadmap}
    provenance::Vector{Provenance}
end

Base.show(io::IO, dev::Device) = print(io,
    "Device(", dev.meta.id, " | ", dev.family.modality, " | ",
    dev.device.num_qubits, "q | ", dev.device.status, ")")
