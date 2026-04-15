#!/usr/bin/env julia
# scripts/ingest_quantinuum.jl
#
# Clone (or update) CQCL/quantinuum-hardware-specifications into
# `.ingest-cache/quantinuum-hw-specs/`, then run the ingest adapter.
#
# Usage:
#   julia --project scripts/ingest_quantinuum.jl
#
# Idempotent — re-running re-snapshots today's sources/ archive and rewrites
# the device TOMLs. Existing `.ingest-cache/` is `git pull`-ed in place.

using Pkg
Pkg.activate(dirname(@__DIR__))

using QuantumHardware

const REPO_ROOT = dirname(@__DIR__)
const CACHE_DIR = joinpath(REPO_ROOT, ".ingest-cache", "quantinuum-hw-specs")
const UPSTREAM = "https://github.com/CQCL/quantinuum-hardware-specifications"

function ensure_clone()
    if isdir(CACHE_DIR)
        @info "quantinuum-hw-specs clone already present; git pull"
        run(Cmd(`git -C $CACHE_DIR fetch --depth 1 origin main`))
        run(Cmd(`git -C $CACHE_DIR reset --hard origin/main`))
    else
        @info "cloning quantinuum-hw-specs (depth 1)"
        mkpath(dirname(CACHE_DIR))
        run(Cmd(`git clone --depth 1 $UPSTREAM $CACHE_DIR`))
    end
end

include(joinpath(REPO_ROOT, "src", "ingest", "quantinuum.jl"))
using .QuantinuumIngest

function main()
    ensure_clone()
    QuantinuumIngest.ingest(; repo_root = REPO_ROOT)
    @info "done — validating corpus"
    result = QuantumHardware.validate_corpus()
    result.fail == 0 || error("$(result.fail) device(s) failed validation after ingest")
end

main()
