# Target{Modality} — Sturm.jl-facing compile target.
#
# A denormalized projection of `Device` carrying the three layers Sturm needs:
#   1. Compile-time data        (gates, coupling, qubit count) — for lowering
#   2. Resource-estimation data (timing, fidelities, coherence) — for runtime/error budgets
#   3. Feasibility data         (status, dates, roadmap) — for "achievable when?"
#
# Parametric on the modality singleton type so Sturm can dispatch:
#     lower(dag, t::Target{NeutralAtom})  ≠  lower(dag, t::Target{SCTransmon})
#
# A T1/T2 column is `Union{Nothing, Float64, Vector{Float64}}` rather than
# `Vector{Union{Nothing, Float64}}` — sentinels move to the wrapper level so
# downstream consumers don't branch per element.

"""
    Coherence

Per-target coherence summary. `Nothing` means no data; `Float64` means uniform
across all qubits (typically the calibrated mean); `Vector{Float64}` means
fully-calibrated per-qubit values (length must equal `Target.num_qubits`).
"""
const Coherence = Union{Nothing, Float64, Vector{Float64}}

"""
    coherence_at(c::Coherence, qubit::Integer) -> Union{Nothing, Float64}

Look up a per-qubit coherence value. Handles all three Coherence shapes;
qubit indices are 0-based to match the schema's `coupling_map` convention.
"""
coherence_at(::Nothing, ::Integer)         = nothing
coherence_at(x::Float64, ::Integer)        = x
coherence_at(v::Vector{Float64}, q::Integer) = v[q + 1]

"""
    Target{M<:AbstractModality}

A `Device` projected into the shape Sturm.jl's compile pipeline consumes.
The type parameter `M` is the modality singleton (e.g. `Target{NeutralAtom}`)
so lowering and feasibility methods can dispatch directly.
"""
struct Target{M<:AbstractModality}
    id::String
    modality::Symbol           # convenience mirror of M for non-dispatch code

    # --- Compile data --------------------------------------------------------
    num_qubits::Int
    coupling_map::Union{Nothing, Vector{Tuple{Int,Int}}}
    reconfigurable::Bool
    topology_kind::Symbol
    native_gates::Vector{NativeGate}

    # --- Resource-estimation data -------------------------------------------
    single_qubit_gate_ns::Float64
    two_qubit_gate_ns::Float64
    readout_ns::Float64
    reset_ns::Union{Nothing, Float64}
    t1_us::Coherence
    t2_us::Coherence
    fidelity_1q_mean::Union{Nothing, Float64}      # averaged across native 1q gates
    fidelity_2q_mean::Union{Nothing, Float64}      # averaged across native 2q gates
    readout_fidelity_mean::Union{Nothing, Float64}

    # --- Feasibility data ---------------------------------------------------
    status::Symbol
    announced_date::Union{Nothing, Date}
    first_operational_date::Union{Nothing, Date}
    decommissioned_date::Union{Nothing, Date}
    roadmap::Union{Nothing, Roadmap}

    # --- Access (so Sturm knows how to actually submit) ---------------------
    cloud_provider::Union{Nothing, Symbol}
    api_kind::Symbol
end

Base.show(io::IO, t::Target{M}) where {M} =
    print(io, "Target{", nameof(M), "}(", t.id, ", ", t.num_qubits, "q, ", t.status, ")")

# --- sturm_target: Device → Target{M} ---------------------------------------

"""
    sturm_target(dev::Device) -> Target{M}

Build a Sturm.jl-shaped `Target` from a `Device`. The modality dispatch type
`M` is resolved from `dev.family.modality`. Coherence/fidelity values are
distilled from the noise model and native gates per the policy below.
"""
function sturm_target(dev::Device)
    M = modality_type(dev.family.modality)
    nq = dev.device.num_qubits
    return Target{M}(
        dev.meta.id,
        dev.family.modality,
        nq,
        dev.topology.coupling_map,
        dev.topology.reconfigurable,
        dev.topology.kind,
        dev.native_gates,
        dev.timing.single_qubit_gate_ns,
        dev.timing.two_qubit_gate_ns,
        dev.timing.readout_ns,
        dev.timing.reset_ns,
        _coherence(dev.noise_model.t1_us, nq),
        _coherence(dev.noise_model.t2_us, nq),
        _gate_fidelity_mean(dev.native_gates, 1),
        _gate_fidelity_mean(dev.native_gates, 2),
        _field(dev.noise_model.readout, :fidelity_mean),
        dev.device.status,
        dev.device.announced_date,
        dev.device.first_operational_date,
        dev.device.decommissioned_date,
        dev.roadmap,
        dev.access.cloud_provider,
        dev.access.api_kind,
    )
end

# Distill T1Block / T2Block into a Coherence union.
# Policy: prefer fully-calibrated per_qubit; fall back to mean; else nothing.
# Mixed nothings in per_qubit force a fall-back to mean (no sentinel vectors
# leak into the Sturm-facing Target).
_coherence(::Nothing, _::Integer) = nothing
function _coherence(b, nqubits::Integer)
    if b.per_qubit !== nothing &&
       length(b.per_qubit) == nqubits &&
       all(x -> x !== nothing, b.per_qubit)
        return Float64[x for x in b.per_qubit]
    end
    return b.mean === nothing ? nothing : Float64(b.mean)
end

# Mean fidelity across native gates of a given arity (kind=:gate only).
function _gate_fidelity_mean(gates::Vector{NativeGate}, arity::Int)
    fids = Float64[]
    for g in gates
        g.arity == arity || continue
        g.kind == :gate || continue
        g.fidelity_mean === nothing && continue
        push!(fids, g.fidelity_mean)
    end
    return isempty(fids) ? nothing : sum(fids) / length(fids)
end

# --- Feasibility verdict ----------------------------------------------------

"""
    Verdict

Result of a `feasibility` check. Fields:

- `verdict::Symbol` ∈ `(:now, :near_term, :on_roadmap, :infeasible, :unknown)`
- `when::Union{Nothing,Date}` — the date the verdict refers to (operational
  date for `:now`/`:near_term`, roadmap target for `:on_roadmap`).
- `reason::String` — human-readable explanation.

Sturm.jl is the primary consumer; this is the basic in-package logic.
Sturm can refine with deeper resource-estimate inputs.
"""
struct Verdict
    verdict::Symbol
    when::Union{Nothing, Date}
    reason::String
end

Base.show(io::IO, v::Verdict) =
    print(io, "Verdict(", v.verdict,
          v.when === nothing ? "" : " @ $(v.when)",
          ": ", v.reason, ")")

"""
    feasibility(t::Target; need_qubits=0, need_2q_fidelity=0.0,
                today=Dates.today(), near_term_horizon=Year(2)) -> Verdict

Coarse-grained "achievable when?" verdict for a workload requiring
`need_qubits` qubits at minimum mean 2-qubit fidelity `need_2q_fidelity`
on this target. Considers the device's `status`, operational dates, and
roadmap targets.

Verdicts:
- `:now`         — `:in_service`/`:intermittent` AND meets specs
- `:near_term`   — `:announced`/`:under_construction` with a first-operational
                   date inside `near_term_horizon`, OR roadmap target inside
                   the horizon
- `:on_roadmap`  — has a roadmap year that meets specs but lies outside the
                   horizon
- `:infeasible`  — retired/decommissioned, or roadmap explicitly caps below
                   the requested capability
- `:unknown`     — projected/announced without dates, or no roadmap data

Sturm.jl is expected to extend this with resource-estimate inputs (depth,
total error budget, runtime); this baseline only checks qubit count + 2q
fidelity.
"""
function feasibility(t::Target;
                     need_qubits::Integer = 0,
                     need_2q_fidelity::Real = 0.0,
                     today::Date = Dates.today(),
                     near_term_horizon::Period = Year(2))
    if t.status ∈ (:decommissioned, :retired)
        return Verdict(:infeasible, t.decommissioned_date,
                       "device $(t.status)")
    end

    meets_spec = t.num_qubits >= need_qubits &&
                 (need_2q_fidelity == 0.0 ||
                  (t.fidelity_2q_mean !== nothing &&
                   t.fidelity_2q_mean >= need_2q_fidelity))

    if t.status ∈ (:in_service, :intermittent)
        meets_spec && return Verdict(:now, t.first_operational_date,
                                     "in service; $(t.num_qubits)q meets specs")
        # In-service but not enough capability — check if roadmap promises more
        return _check_roadmap(t, need_qubits, need_2q_fidelity, today, near_term_horizon;
                              fallback_reason="in service but only $(t.num_qubits)q")
    end

    if t.status ∈ (:announced, :under_construction)
        if t.first_operational_date !== nothing &&
           t.first_operational_date <= today + near_term_horizon
            return Verdict(meets_spec ? :near_term : :infeasible,
                           t.first_operational_date,
                           "$(t.status); first operational $(t.first_operational_date)")
        end
        # Dated beyond horizon, or no date — roadmap takes over
        return _check_roadmap(t, need_qubits, need_2q_fidelity, today, near_term_horizon;
                              fallback_reason="$(t.status) without near-term date")
    end

    if t.status == :projected
        return _check_roadmap(t, need_qubits, need_2q_fidelity, today, near_term_horizon;
                              fallback_reason="projected, no operational dates")
    end

    return Verdict(:unknown, nothing,
                   "status $(t.status) not classified")
end

function _check_roadmap(t::Target, need_qubits::Integer, need_2q_fidelity::Real,
                        today::Date, horizon::Period; fallback_reason::String)
    rd = t.roadmap
    rd === nothing && return Verdict(:unknown, nothing,
                                     "$fallback_reason; no roadmap data")
    # Hard cap: roadmap explicitly targets fewer qubits than needed.
    if rd.originally_targeted_qubits !== nothing &&
       rd.originally_targeted_qubits < need_qubits
        return Verdict(:infeasible, nothing,
                       "roadmap caps at $(rd.originally_targeted_qubits)q < needed $need_qubits")
    end
    if rd.originally_targeted_fidelity_2q !== nothing &&
       need_2q_fidelity > 0.0 &&
       rd.originally_targeted_fidelity_2q < need_2q_fidelity
        return Verdict(:infeasible, nothing,
                       "roadmap caps 2q fidelity at $(rd.originally_targeted_fidelity_2q)")
    end
    rd.originally_targeted_year === nothing && return Verdict(:unknown, nothing,
                                                              "$fallback_reason; roadmap has no year")
    target_date = Date(rd.originally_targeted_year, 1, 1)
    if target_date <= today + horizon
        return Verdict(:near_term, target_date, "roadmap targets $target_date")
    end
    return Verdict(:on_roadmap, target_date, "roadmap targets $target_date")
end
