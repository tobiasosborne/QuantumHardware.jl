#!/usr/bin/env julia
# scripts/check_url_drift.jl
#
# Refetch every unique source_url across the corpus and compare its sha256
# against the one recorded in provenance. Surfaces:
#   - URL rot       (404 / 5xx / timeout)
#   - silent drift  (URL still resolves but content has changed)
#
# Network-heavy and rate-limit-sensitive — intended for a weekly cron, NOT
# the test suite. Avoid running more often than that against external hosts
# (arXiv, AWS docs, vendor pages) to be a polite citizen.
#
# Output: one line per unique URL — ok / DRIFT / UNREACHABLE — plus a summary.
# Exit 0 only if every URL is ok.
#
# Caveat: some HTML pages (arXiv abstract listings, vendor blog pages) carry
# view counters / dynamic carousels and will drift for cosmetic reasons. The
# stable ground truth is the LOCAL archive (already verified by validate_corpus
# via sha256 against on-disk bytes); this script's drift signal is advisory
# — when it fires, decide whether to refetch and re-archive, or whitelist.

using Pkg
Pkg.activate(dirname(@__DIR__))

using Downloads
using SHA
using TOML
using QuantumHardware

# --- Collect URLs from the corpus -------------------------------------------

"""
Map source_url → Vector{(sha256_expected, device_id, field_path)}.
Multiple device files may reference the same URL (e.g. the AWS Braket docs
page). One URL with multiple distinct expected shas is itself a smell — the
report flags it.
"""
function collect_provenance_urls()
    urls = Dict{String, Vector{NamedTuple{(:sha, :device, :field), Tuple{String,String,String}}}}()
    for path in device_toml_paths()
        toml = TOML.parsefile(path)
        haskey(toml, "provenance") || continue
        did = toml["meta"]["id"]
        for p in toml["provenance"]
            haskey(p, "source_url") && haskey(p, "sha256") || continue
            url = p["source_url"]
            entry = (sha=p["sha256"], device=did, field=get(p, "field_path", "?"))
            push!(get!(urls, url, similar([entry], 0)), entry)
        end
    end
    return urls
end

# --- Fetch + hash -----------------------------------------------------------

function fetch_sha256(url::AbstractString; timeout::Real=30)
    io = IOBuffer()
    Downloads.download(url, io;
                       timeout=timeout,
                       headers=Dict("User-Agent" => "Mozilla/5.0 (quantum-hardware/url-drift)"))
    return bytes2hex(sha256(take!(io)))
end

# --- Report ----------------------------------------------------------------

function main()
    urls = collect_provenance_urls()
    println("Checking $(length(urls)) unique source_urls.\n")
    n_ok = 0
    n_drift = 0
    n_unreachable = 0
    failures = String[]

    for url in sort!(collect(keys(urls)))
        entries = urls[url]
        expected = unique(e.sha for e in entries)
        try
            actual = fetch_sha256(url)
            if actual ∈ expected
                println("ok           $url")
                n_ok += 1
            else
                println("DRIFT        $url")
                println("             expected: $(join(expected, ", "))")
                println("             actual:   $actual")
                println("             cited by: $(join(unique(e.device for e in entries), ", "))")
                n_drift += 1
                push!(failures, "DRIFT $url")
            end
        catch e
            short = first(split(sprint(showerror, e), '\n'), 1)[1]
            println("UNREACHABLE  $url")
            println("             $short")
            n_unreachable += 1
            push!(failures, "UNREACHABLE $url")
        end
    end

    println()
    println("$n_ok ok, $n_drift drift, $n_unreachable unreachable")
    exit(n_drift + n_unreachable == 0 ? 0 : 1)
end

main()
