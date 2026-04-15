using Test
using SHA
using QuantumHardware

const REPO_ROOT = pkgdir(QuantumHardware)
const DEVICES_DIR = joinpath(REPO_ROOT, "devices")

@testset "QuantumHardware" begin

    @testset "ENUMS loaded from JSON schema (single source of truth)" begin
        E = QuantumHardware.ENUMS
        # Every $defs.<name>.enum from device.schema.json must surface here.
        for k in (:modality, :status, :topology_kind, :org_kind, :source_kind,
                  :api_kind, :cloud_provider, :access_tier, :t2_kind,
                  :native_gate_kind, :logical_code)
            @test haskey(E, k)
            @test !isempty(E[k])
            @test all(v isa String for v in E[k])
        end
        # Smoke: a representative value is present in each.
        @test "sc_transmon" ∈ E[:modality]
        @test "in_service"  ∈ E[:status]
        @test "heavy_hex"   ∈ E[:topology_kind]
        @test "braket"      ∈ E[:api_kind]
    end

    @testset "schema validation — every device TOML passes" begin
        # Every TOML under devices/ must pass v0.1 schema validation.
        # Failing files surface as individual @test failures with their path.
        paths = device_toml_paths(DEVICES_DIR)
        for path in paths
            @testset "$path" begin
                @test_nowarn QuantumHardware.validate_device_file(path)
            end
        end
        @test length(paths) >= 3   # Session 1 seeded three examples — never regress below that
    end

    @testset "loader — Device struct tree" begin
        for path in device_toml_paths(DEVICES_DIR)
            @testset "$path" begin
                dev = load_device(path)
                @test dev isa Device
                @test !isempty(dev.meta.id)
                @test dev.device.num_qubits >= 0
                @test !isempty(dev.native_gates)
                @test !isempty(dev.provenance)
                # Dual source-of-truth rule: every provenance entry points to a
                # real local archive, and the sha256 matches on disk.
                for (i, p) in pairs(dev.provenance)
                    archive = joinpath(REPO_ROOT, p.local_path)
                    @test isfile(archive)
                    if isfile(archive)
                        actual = bytes2hex(open(sha256, archive))
                        @test actual == p.sha256
                    end
                end
            end
        end
    end

    @testset "load_all_devices corpus walk" begin
        corpus = QuantumHardware.load_all_devices(DEVICES_DIR)
        @test length(corpus) >= 19
        @test haskey(corpus, "quera-aquila")
        @test haskey(corpus, "quantinuum-h2-1")
        @test haskey(corpus, "ibm-heron-r2")
        @test haskey(corpus, "ionq-forte-1")
    end

    @testset "target_spec lookup" begin
        d = QuantumHardware.target_spec("quera-aquila"; root=DEVICES_DIR)
        @test d.device.num_qubits == 256
        @test d.family.modality == :neutral_atom
        @test d.access.cloud_provider == :aws_braket

        @test_throws KeyError QuantumHardware.target_spec("does-not-exist"; root=DEVICES_DIR)
    end

    @testset "target_spec uses cached path index" begin
        # Cold call (may build the cache); warm call should be sub-millisecond.
        QuantumHardware.reload_corpus!()
        QuantumHardware.target_spec("ibm-heron-r2"; root=DEVICES_DIR)
        # Warm call: cached index + single TOML parse + validate. Should be <50ms.
        warm = @elapsed QuantumHardware.target_spec("ibm-heron-r2"; root=DEVICES_DIR)
        @test warm < 0.050
        # Cache invalidation
        QuantumHardware.reload_corpus!()
        @test QuantumHardware.target_spec("ibm-heron-r2"; root=DEVICES_DIR).device.num_qubits == 156
    end

    @testset "find_devices filters" begin
        all_in_service = find_devices(; root=DEVICES_DIR, in_service_only=true)
        @test length(all_in_service) >= 3

        atoms_only = find_devices(; root=DEVICES_DIR, modality=:neutral_atom)
        @test all(d -> d.family.modality == :neutral_atom, atoms_only)
        @test !isempty(atoms_only)

        big = find_devices(; root=DEVICES_DIR, min_qubits=100)
        @test all(d -> d.device.num_qubits >= 100, big)

        tiny = find_devices(; root=DEVICES_DIR, max_qubits=10)
        @test all(d -> d.device.num_qubits <= 10, tiny)
        @test any(d -> d.meta.id == "quandela-ascella", tiny)
    end

    @testset "sturm_target -> Target{M}" begin
        d = QuantumHardware.target_spec("ibm-heron-r2"; root=DEVICES_DIR)
        t = sturm_target(d)
        # Type-parameter dispatch: Target{SCTransmon}, not just a NamedTuple.
        @test t isa Target{SCTransmon}
        @test t.modality == :sc_transmon
        @test t.num_qubits == 156
        @test t.api_kind == :qiskit_runtime
        @test t.single_qubit_gate_ns == 36.0
        @test t.two_qubit_gate_ns == 68.0
        # No T1 data on this seed → Nothing, not a sentinel-filled vector.
        @test t.t1_us === nothing
        @test t.t2_us === nothing

        # Modality dispatch works generically.
        a = sturm_target(QuantumHardware.target_spec("quera-aquila"; root=DEVICES_DIR))
        @test a isa Target{NeutralAtom}
        @test a.topology_kind == :analog_hamiltonian
        @test a.reconfigurable

        q = sturm_target(QuantumHardware.target_spec("quantinuum-h2-1"; root=DEVICES_DIR))
        @test q isa Target{TrappedIon}
        @test q.fidelity_2q_mean !== nothing  # ingested from the spec-sheet CSV
    end

    @testset "feasibility verdicts" begin
        # In-service device meeting the spec → :now
        h = sturm_target(QuantumHardware.target_spec("ibm-heron-r2"; root=DEVICES_DIR))
        v = feasibility(h; need_qubits=100)
        @test v.verdict == :now
        @test v.when == h.first_operational_date

        # In-service but caller asks for too many qubits → falls through to roadmap (none here) → :unknown
        v_big = feasibility(h; need_qubits=1_000_000)
        @test v_big.verdict ∈ (:unknown, :infeasible, :on_roadmap)

        # Projected device → roadmap-driven
        bs = sturm_target(QuantumHardware.target_spec("qudora-bs-200"; root=DEVICES_DIR))
        @test bs.status == :projected
        v_pr = feasibility(bs; need_qubits=100)
        @test v_pr.verdict ∈ (:near_term, :on_roadmap, :unknown)
    end

    @testset "modality_type mapping" begin
        @test modality_type(:sc_transmon) === SCTransmon
        @test modality_type(:neutral_atom) === NeutralAtom
        @test modality_type(:trapped_ion) === TrappedIon
        @test modality_type(:photonic_discrete) === PhotonicDiscrete
        # All 18 schema enums must have a Julia type
        for m in QuantumHardware.ENUMS[:modality]
            @test haskey(MODALITY_TYPES, Symbol(m))
        end
    end

    @testset "coherence_at dispatch" begin
        @test coherence_at(nothing, 0) === nothing
        @test coherence_at(75.0, 5) == 75.0
        @test coherence_at([10.0, 20.0, 30.0], 0) == 10.0
        @test coherence_at([10.0, 20.0, 30.0], 2) == 30.0
    end

    include("test_db.jl")
    include("test_ingest_braket.jl")
    include("test_ingest_quantinuum.jl")
end
