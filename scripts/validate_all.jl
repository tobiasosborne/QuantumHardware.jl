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
using SHA

const REPO_ROOT = dirname(@__DIR__)
const DEVICES_DIR = joinpath(REPO_ROOT, "devices")

function main()
    fail_count = 0
    pass_count = 0
    for path in device_toml_paths(DEVICES_DIR)
        try
            QuantumHardware.validate_device_file(path)
            dev = load_device(path)
            for (i, p) in pairs(dev.provenance)
                archive = joinpath(REPO_ROOT, p.local_path)
                isfile(archive) || error("archive missing: $archive (provenance[$i])")
                actual = bytes2hex(open(sha256, archive))
                actual == p.sha256 || error(
                    "sha256 mismatch on $archive\n  expected $(p.sha256)\n  actual   $actual")
            end
            pass_count += 1
            println("ok  ", path)
        catch e
            fail_count += 1
            println("ERR ", path, " -- ", sprint(showerror, e))
        end
    end
    println()
    println("$(pass_count) passed, $(fail_count) failed.")
    exit(fail_count == 0 ? 0 : 1)
end

main()
