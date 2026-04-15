# Golden-master tests for the Quantinuum ingest CSV parser.
# Pinned against test/fixtures/quantinuum-spec-mini.csv.

using Test
using QuantumHardware

include(joinpath(pkgdir(QuantumHardware), "src", "ingest", "quantinuum.jl"))

const _QUANTINUUM_FIXTURE = joinpath(@__DIR__, "fixtures", "quantinuum-spec-mini.csv")

@testset "QuantinuumIngest.parse_csv_value" begin
    # Mantissa + uncertainty + exponent; uncertainty digits are dropped.
    @test QuantinuumIngest.parse_csv_value("2.4(3)E-05") ≈ 2.4e-5
    @test QuantinuumIngest.parse_csv_value("1.5(2)E-03") ≈ 1.5e-3
    # No uncertainty tag — straight scientific notation.
    @test QuantinuumIngest.parse_csv_value("3.7E-04") ≈ 3.7e-4
    @test QuantinuumIngest.parse_csv_value("1.8E-05") ≈ 1.8e-5
    # Empty / whitespace → nothing.
    @test QuantinuumIngest.parse_csv_value("") === nothing
    @test QuantinuumIngest.parse_csv_value("   ") === nothing
    # Garbage → nothing (no exponent, no match).
    @test QuantinuumIngest.parse_csv_value("garbage") === nothing
end

@testset "QuantinuumIngest.parse_spec_csv" begin
    rows = QuantinuumIngest.parse_spec_csv(_QUANTINUUM_FIXTURE)

    # Fixture has 4 data lines but one is fully blank — should be skipped.
    @test length(rows) == 3

    # First row: H2-1 2024-05-20, fully populated.
    r1 = rows[1]
    @test r1.date == "2024-05-20"
    @test r1.machine == "H2-1"
    @test r1.err_1q ≈ 2.4e-5
    @test r1.err_2q ≈ 1.5e-3
    @test r1.transport_1q ≈ 3.0e-5
    @test r1.mcm ≈ 1.2e-4
    @test r1.spam ≈ 3.7e-4

    # Second row: H2-1 2025-04-30 — partially populated (missing transport_1q + mcm).
    r2 = rows[2]
    @test r2.date == "2025-04-30"
    @test r2.machine == "H2-1"
    @test r2.err_1q ≈ 1.8e-5
    @test r2.err_2q ≈ 9.1e-4
    @test r2.transport_1q === nothing
    @test r2.mcm === nothing
    @test r2.spam ≈ 2.5e-4

    # Third row: H1-1 2023-03-10 (the blank line was skipped).
    r3 = rows[3]
    @test r3.date == "2023-03-10"
    @test r3.machine == "H1-1"
end
