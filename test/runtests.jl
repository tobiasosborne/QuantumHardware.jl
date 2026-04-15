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

    @testset "sturm_target API shape" begin
        d = QuantumHardware.target_spec("ibm-heron-r2"; root=DEVICES_DIR)
        t = sturm_target(d)
        @test t.num_qubits == 156
        @test t.modality == :sc_transmon
        @test t.api_kind == :qiskit_runtime
        @test t.single_qubit_gate_ns == 36.0
        @test t.two_qubit_gate_ns == 68.0
        # T1/T2 not populated on the seed; fallback vector is all `nothing`
        @test length(t.t1_us) == 156
    end

    include("test_db.jl")
    include("test_ingest_braket.jl")
    include("test_ingest_quantinuum.jl")
end
