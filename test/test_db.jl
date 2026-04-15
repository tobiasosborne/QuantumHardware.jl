# Verifies build_db produces working DuckDB + SQLite artefacts from the
# corpus, with matching row counts across backends and recoverable data.

using Test
using QuantumHardware
using DBInterface
import DuckDB
import SQLite

@testset "build_db → DuckDB + SQLite artefacts" begin
    mktempdir() do tmp
        corpus = QuantumHardware.load_all_devices()
        @test length(corpus) >= 19

        duck_path   = joinpath(tmp, "qh.duckdb")
        sqlite_path = joinpath(tmp, "qh.sqlite")

        duck_stats   = build_db(duck_path;   backend=:duckdb, devices=corpus)
        sqlite_stats = build_db(sqlite_path; backend=:sqlite, devices=corpus)

        @test isfile(duck_path)
        @test isfile(sqlite_path)

        # Core acceptance: one row per DeviceRevision, one row per provenance entry
        @test duck_stats.devices == length(corpus)
        expected_prov = sum(length(d.provenance) for d in values(corpus))
        @test duck_stats.provenance == expected_prov

        # Both backends agree on every counted table
        for k in (:devices, :native_gates, :coupling_edges, :calibration_snapshots,
                  :provenance, :device_aliases, :device_sdk_packages,
                  :qubit_coherence, :gate_qubit_fidelity, :gate_pair_fidelity)
            @test duck_stats[k] == sqlite_stats[k]
        end

        # Denormalized child tables actually populate from the corpus
        @test duck_stats.device_aliases > 0       # most devices carry aliases
        @test duck_stats.device_sdk_packages > 0   # all devices carry sdk_packages

        # Query-level: a hand-curated device round-trips correctly
        @testset "duckdb round-trip quera-aquila" begin
            d = DBInterface.connect(DuckDB.DB, duck_path)
            try
                rows = collect(DBInterface.execute(d,
                    "SELECT num_qubits, modality, status FROM devices WHERE id = 'quera-aquila'"))
                @test length(rows) == 1
                r = rows[1]
                @test r.num_qubits == 256
                @test r.modality == "neutral_atom"
                @test r.status == "in_service"

                gates = collect(DBInterface.execute(d,
                    "SELECT count(*) as n FROM native_gates WHERE device_id = 'quera-aquila'"))
                @test gates[1].n >= 1

                prov_rows = collect(DBInterface.execute(d,
                    "SELECT count(*) as n FROM provenance WHERE device_id = 'quera-aquila'"))
                @test prov_rows[1].n >= 1
            finally
                DBInterface.close!(d)
            end
        end

        # Query-level: sqlite agrees on the same device. SQLite.Row is cursor-
        # backed and does not survive `collect`, so we extract eagerly within
        # the iteration.
        @testset "sqlite round-trip quera-aquila" begin
            s = DBInterface.connect(SQLite.DB, sqlite_path)
            try
                extracted = NamedTuple[]
                for r in DBInterface.execute(s,
                        "SELECT num_qubits, modality, status FROM devices WHERE id = 'quera-aquila'")
                    push!(extracted, (num_qubits=r.num_qubits, modality=r.modality, status=r.status))
                end
                @test length(extracted) == 1
                r = extracted[1]
                @test r.num_qubits == 256
                @test r.modality == "neutral_atom"
                @test r.status == "in_service"
            finally
                DBInterface.close!(s)
            end
        end

        # Longitudinal data is preserved: Quantinuum H1-1 has multi-year snapshots
        @testset "calibration_snapshots longitudinal" begin
            d = DBInterface.connect(DuckDB.DB, duck_path)
            try
                rows = collect(DBInterface.execute(d,
                    "SELECT count(*) as n FROM calibration_snapshots WHERE device_id = 'quantinuum-h1-1'"))
                @test rows[1].n >= 2
            finally
                DBInterface.close!(d)
            end
        end

        # Dual source-of-truth: every row in provenance carries a 64-hex sha256
        @testset "provenance sha256 shape" begin
            d = DBInterface.connect(DuckDB.DB, duck_path)
            try
                bad = collect(DBInterface.execute(d,
                    "SELECT count(*) as n FROM provenance WHERE NOT regexp_matches(sha256, '^[a-f0-9]{64}\$')"))
                @test bad[1].n == 0
            finally
                DBInterface.close!(d)
            end
        end

        # Overwrite behaviour: a second build on the same path must succeed
        duck_stats_2 = build_db(duck_path; backend=:duckdb, devices=corpus)
        @test duck_stats_2.devices == duck_stats.devices

        # Denormalized aliases queryable directly (no JSON extract needed)
        @testset "device_aliases denormalized" begin
            d = DBInterface.connect(DuckDB.DB, duck_path)
            try
                rows = collect(DBInterface.execute(d,
                    "SELECT alias FROM device_aliases WHERE device_id = 'ibm-heron-r2' ORDER BY alias_idx"))
                @test "Heron r2" ∈ [r.alias for r in rows]
                @test "ibm_torino" ∈ [r.alias for r in rows]
            finally
                DBInterface.close!(d)
            end
        end

        # device_sdk_packages denormalized
        @testset "device_sdk_packages denormalized" begin
            d = DBInterface.connect(DuckDB.DB, duck_path)
            try
                rows = collect(DBInterface.execute(d,
                    "SELECT package FROM device_sdk_packages WHERE device_id = 'ibm-heron-r2'"))
                pkgs = [r.package for r in rows]
                @test "qiskit" ∈ pkgs
                @test "qiskit-ibm-runtime" ∈ pkgs
            finally
                DBInterface.close!(d)
            end
        end
    end
end
