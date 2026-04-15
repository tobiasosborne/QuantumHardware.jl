#!/usr/bin/env julia
# scripts/validate_all.jl
#
# Schema + archive-integrity check over the entire devices/ corpus.
# Exit code 0 on success, 1 on first failure. Suitable for CI.
#
# Usage:
#   julia --project scripts/validate_all.jl

using Pkg
Pkg.activate(dirname(@__DIR__))

using QuantumHardware

result = QuantumHardware.validate_corpus()
exit(result.fail == 0 ? 0 : 1)
