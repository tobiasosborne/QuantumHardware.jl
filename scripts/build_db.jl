#!/usr/bin/env julia
# scripts/build_db.jl
#
# Compile the TOML corpus into db/quantum-hardware.duckdb (primary)
# and db/quantum-hardware.sqlite (fallback). Both artefacts are the
# query-ready representation consumed by Sturm.jl — never hand-edit them.
#
# Usage:
#   julia --project scripts/build_db.jl
#
# Exits 0 on success, 1 on any build failure. Both files are rebuilt
# from scratch on every invocation.

using Pkg
Pkg.activate(dirname(@__DIR__))

using QuantumHardware

const REPO_ROOT = dirname(@__DIR__)
const DB_DIR    = joinpath(REPO_ROOT, "db")
const DUCK_PATH = joinpath(DB_DIR, "quantum-hardware.duckdb")
const SQLITE_PATH = joinpath(DB_DIR, "quantum-hardware.sqlite")

function main()
    mkpath(DB_DIR)
    corpus = load_all_devices()
    println("loaded $(length(corpus)) devices from corpus")

    duck_stats = build_db(DUCK_PATH; backend=:duckdb, devices=corpus)
    println("duckdb → $(DUCK_PATH)")
    for (k, v) in pairs(duck_stats)
        k in (:backend, :path) && continue
        println("  $(k): $v")
    end

    sqlite_stats = build_db(SQLITE_PATH; backend=:sqlite, devices=corpus)
    println("sqlite → $(SQLITE_PATH)")
    for (k, v) in pairs(sqlite_stats)
        k in (:backend, :path) && continue
        println("  $(k): $v")
    end

    # Sanity: both backends produce identical row counts
    for k in (:devices, :native_gates, :coupling_edges, :calibration_snapshots, :provenance)
        duck_stats[k] == sqlite_stats[k] ||
            error("row count mismatch on $k: duckdb=$(duck_stats[k]), sqlite=$(sqlite_stats[k])")
    end
    println("ok — duckdb and sqlite row counts agree")
end

main()
