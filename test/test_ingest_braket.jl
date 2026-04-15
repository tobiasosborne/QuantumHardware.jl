# Golden-master tests for the AWS Braket ingest parser.
# Pinned against test/fixtures/braket-devices-mini.html — change only when
# AWS docs structure shifts AND the parser is updated to match.

using Test
using QuantumHardware

include(joinpath(pkgdir(QuantumHardware), "src", "ingest", "braket.jl"))

const _BRAKET_FIXTURE = joinpath(@__DIR__, "fixtures", "braket-devices-mini.html")

@testset "BraketIngest.parse_braket_devices" begin
    devices = BraketIngest.parse_braket_devices(_BRAKET_FIXTURE)

    # The fixture has 3 unique QPU ARNs (one duplicated; one simulator ARN
    # excluded by the qpu regex). Deduplication MUST drop the duplicate.
    @test length(devices) == 3

    arns = [d[3] for d in devices]
    @test "arn:aws:braket:us-east-1::device/qpu/ionq/Forte-1" ∈ arns
    @test "arn:aws:braket:eu-north-1::device/qpu/iqm/Garnet" ∈ arns
    @test "arn:aws:braket:us-west-1::device/qpu/rigetti/Ankaa-3" ∈ arns
    @test length(unique(arns)) == length(arns)   # dedup invariant

    # Vendor + model captures (positional tuple shape: (vendor, model, arn))
    by_arn = Dict(d[3] => (vendor=d[1], model=d[2]) for d in devices)
    @test by_arn["arn:aws:braket:us-east-1::device/qpu/ionq/Forte-1"]      == (vendor="ionq",    model="Forte-1")
    @test by_arn["arn:aws:braket:eu-north-1::device/qpu/iqm/Garnet"]       == (vendor="iqm",     model="Garnet")
    @test by_arn["arn:aws:braket:us-west-1::device/qpu/rigetti/Ankaa-3"]   == (vendor="rigetti", model="Ankaa-3")
end

@testset "BraketIngest.region_of" begin
    @test BraketIngest.region_of("arn:aws:braket:us-east-1::device/qpu/ionq/Forte-1") == "us-east-1"
    @test BraketIngest.region_of("arn:aws:braket:eu-north-1::device/qpu/aqt/Ibex-Q1") == "eu-north-1"
    @test BraketIngest.region_of("arn:aws:braket:::device/qpu/quera/Aquila") == "us-east-1"   # fallback on empty
    @test BraketIngest.region_of("not-an-arn") == "us-east-1"                                  # fallback on no-match
end

@testset "BraketIngest config loaded from braket.toml" begin
    # Sanity: the externalised config must surface as VENDOR_PRESETS / DEVICE_OVERRIDES.
    @test haskey(BraketIngest.VENDOR_PRESETS, "ionq")
    @test BraketIngest.VENDOR_PRESETS["ionq"].country == "USA"
    @test BraketIngest.VENDOR_PRESETS["ionq"].modality == "trapped_ion"
    @test haskey(BraketIngest.DEVICE_OVERRIDES, "ionq/Forte-1")
    @test BraketIngest.DEVICE_OVERRIDES["ionq/Forte-1"].num_qubits == 36
end
