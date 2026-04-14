#!/usr/bin/env julia
# scripts/ingest_braket.jl
#
# Ingest AWS Braket public QPU list via the developer-guide HTML page.
# Pathway A (no AWS creds). Pathway B (live GetDevice) is future work.
#
# Usage:
#   julia --project scripts/ingest_braket.jl
#
# Idempotent — re-runs re-snapshot today's HTML archive and rewrite the stub
# TOMLs unless the existing target has richer data (e.g. hand-curated
# quera-aquila.toml with its analog-Hamiltonian block is preserved).

using Pkg
Pkg.activate(dirname(@__DIR__))

using QuantumHardware
using Dates

const REPO_ROOT = dirname(@__DIR__)
const AWS_DOCS_URL = "https://docs.aws.amazon.com/braket/latest/developerguide/braket-devices.html"

function fetch_docs_snapshot()
    today_date = today()
    dest_dir = joinpath(REPO_ROOT, "sources",
                        string(year(today_date)),
                        string(month(today_date); pad=2),
                        string(day(today_date); pad=2))
    mkpath(dest_dir)
    dest = joinpath(dest_dir, "aws-braket-devices.html")
    if !isfile(dest)
        @info "fetching AWS Braket docs"
        run(Cmd(`curl -sSL --max-time 30 -A Mozilla/5.0 -o $dest $AWS_DOCS_URL`))
    else
        @info "AWS Braket docs snapshot present; reusing" dest
    end
    return dest
end

include(joinpath(REPO_ROOT, "src", "ingest", "braket.jl"))
using .BraketIngest

function main()
    snapshot = fetch_docs_snapshot()
    BraketIngest.ingest(; repo_root = REPO_ROOT, docs_html = snapshot)
    @info "done — validating corpus"
    run(Cmd(`julia --project=$REPO_ROOT $(joinpath(REPO_ROOT, "scripts", "validate_all.jl"))`))
end

main()
