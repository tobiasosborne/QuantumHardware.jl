# src/ingest/quantinuum.jl
#
# Ingest adapter for CQCL/quantinuum-hardware-specifications
# (https://github.com/CQCL/quantinuum-hardware-specifications).
#
# This is a pure-Julia adapter — no external Python tooling required. It expects
# the repo to have been cloned to `.ingest-cache/quantinuum-hw-specs/` via the
# caller (`scripts/ingest_quantinuum.jl`).
#
# Contract (dual source-of-truth rule, CLAUDE.md §4):
#   - Every file read from the clone is COPIED into sources/YYYY/MM/DD/ with a
#     stable slug.
#   - The sha256 of the copied file is recorded in the emitted provenance entry.
#   - The canonical source_url is the GitHub raw.githubusercontent URL.
#
# What lands on disk after running:
#   devices/quantinuum/quantinuum-h1-1.toml
#   devices/quantinuum/quantinuum-h1-2.toml
#   devices/quantinuum/quantinuum-h2-1.toml
#   devices/quantinuum/quantinuum-h2-2.toml
#   devices/quantinuum/quantinuum-reimei.toml
#
# Re-running is idempotent: re-copy overwrites the snapshot (fine, sha will
# match), re-emit rewrites the TOML.

module QuantinuumIngest

using TOML
using SHA
using Dates

using QuantumHardware.IngestCommon: is_hand_curated, snapshot_file

const GITHUB_RAW_BASE =
    "https://raw.githubusercontent.com/CQCL/quantinuum-hardware-specifications/main"

"""
    parse_csv_value(s::AbstractString)

Parse a Quantinuum spec-sheet cell of the form `"2.4(3)E-05"` into `2.4e-5`.
Empty string → `nothing`. Format: mantissa, optional `(digits)` uncertainty
tag (ignored), E±exponent.
"""
function parse_csv_value(s::AbstractString)
    s = strip(s)
    isempty(s) && return nothing
    m = match(r"([0-9.]+)(?:\([0-9]+\))?[eE]([+-]?[0-9]+)", s)
    m === nothing && return nothing
    return parse(Float64, m[1]) * 10.0^parse(Int, m[2])
end

"""
    parse_spec_csv(path)

Return a Vector of NamedTuples — one per row — with keys
`:date`, `:machine`, `:err_1q`, `:err_2q`, `:spam`, `:transport_1q`, `:mcm`.
Uses the csv header names from `notebooks/Spec sheet parameters.csv`.
"""
function parse_spec_csv(path::AbstractString)
    rows = NamedTuple[]
    lines = readlines(path)
    header = split(lines[1], ',')
    col(row, name) = row[findfirst(==(name), header)]
    for line in lines[2:end]
        isempty(strip(line)) && continue
        parts = split(line, ',')
        length(parts) < length(header) && continue
        push!(rows, (
            date = String(parts[findfirst(==("Date"), header)]),
            machine = String(parts[findfirst(==("Machine"), header)]),
            err_1q = parse_csv_value(parts[findfirst(==("1Q error"), header)]),
            err_2q = parse_csv_value(parts[findfirst(==("2Q error"), header)]),
            transport_1q = parse_csv_value(parts[findfirst(==("Transport 1Q error"), header)]),
            mcm = parse_csv_value(parts[findfirst(==("MCM error"), header)]),
            spam = parse_csv_value(parts[findfirst(==("SPAM error"), header)]),
        ))
    end
    return rows
end

# --- Per-system metadata -----------------------------------------------------
# Quantinuum publishes one folder per live system: H1-1, H1-2, H2-1, H2-2, REIMEI.
# Static facts per system — qubit count, announcement date, modality specifics.
# Updated when a new generation lands.

const SYSTEM_META = Dict(
    "H1-1"   => (slug="quantinuum-h1-1", family="H-Series", display="Quantinuum H1-1",
                 num_qubits=20, announced=Date("2020-06-01"),
                 lineage=nothing, notes="20-qubit QCCD, Yb-171+ with Ba-138+ sympathetic coolant."),
    "H1-2"   => (slug="quantinuum-h1-2", family="H-Series", display="Quantinuum H1-2",
                 num_qubits=20, announced=Date("2021-02-01"),
                 lineage="quantinuum-h1-1", notes="20-qubit QCCD (second H1 system)."),
    "H2-1"   => (slug="quantinuum-h2-1", family="H-Series", display="Quantinuum H2-1",
                 num_qubits=56, announced=Date("2023-05-30"),
                 lineage="quantinuum-h1-1",
                 notes="QCCD; shipped as 32 qubits (2023) then upgraded to 56 (2024)."),
    "H2-2"   => (slug="quantinuum-h2-2", family="H-Series", display="Quantinuum H2-2",
                 num_qubits=56, announced=Date("2024-12-06"),
                 lineage="quantinuum-h2-1", notes="Second H2 system."),
    "REIMEI" => (slug="quantinuum-reimei", family="H-Series (RIKEN deployment)",
                 display="Quantinuum REIMEI (RIKEN)",
                 num_qubits=20, announced=Date("2025-01-26"),
                 lineage="quantinuum-h1-1",
                 notes="H-class machine deployed at RIKEN RQC as the REIMEI system."),
)

"""
    ingest(; repo_root, cache=".ingest-cache/quantinuum-hw-specs", today=today())

Main entry point. Walks the cloned Quantinuum repo, snapshots every JSON file
under `data/<system>/<date>/` into `sources/<today>/quantinuum/<system>/<date>/`,
and emits one device TOML per system.
"""
function ingest(; repo_root::AbstractString,
                  cache::AbstractString = joinpath(repo_root, ".ingest-cache", "quantinuum-hw-specs"),
                  today_date::Date = today())
    data_dir = joinpath(cache, "data")
    isdir(data_dir) || error("Quantinuum clone not found at $cache — run scripts/ingest_quantinuum.jl which handles the clone")

    sources_today = joinpath(repo_root, "sources",
                             string(year(today_date)),
                             string(month(today_date); pad=2),
                             string(day(today_date); pad=2))

    # 1) Snapshot the spec-sheet CSV once.
    csv_src = joinpath(cache, "notebooks", "Spec sheet parameters.csv")
    csv_rel, csv_sha = snapshot_file(csv_src, repo_root, sources_today,
                                     "quantinuum-spec-sheet-parameters.csv")
    csv_url = "$GITHUB_RAW_BASE/notebooks/Spec%20sheet%20parameters.csv"
    spec_rows = parse_spec_csv(csv_src)

    # 2) Per system: snapshot every date folder and emit one TOML.
    for entry in readdir(data_dir)
        sys_dir = joinpath(data_dir, entry)
        isdir(sys_dir) || continue
        meta = get(SYSTEM_META, entry, nothing)
        meta === nothing && (@warn "unknown Quantinuum system in clone: $entry" ; continue)

        # Per-date snapshot records: provenance entries + calibration_snapshots.
        provenance = Vector{Dict{String,Any}}()
        cal_snapshots = Vector{Dict{String,Any}}()
        sys_source_dir = joinpath(sources_today, "quantinuum", entry)

        # Seed one provenance entry for the CSV (used for summary fidelity fields).
        push!(provenance, Dict(
            "field_path" => "noise_model (summary)",
            "value" => "spec-sheet CSV",
            "source_url" => csv_url,
            "source_kind" => "vendor_doc",
            "retrieved_at" => DateTime(today_date),
            "local_path" => csv_rel,
            "sha256" => csv_sha,
            "notes" => "Latest per-date summary row for system $entry used below.",
        ))

        for date in sort!(readdir(sys_dir))
            date_dir = joinpath(sys_dir, date)
            isdir(date_dir) || continue
            prov_idx_for_date = length(provenance)  # 0-based offset of first prov entry for this date
            first_in_date = true
            raw_file_rel_representative = ""
            for f in readdir(date_dir)
                endswith(f, ".json") || continue
                slug = "$(lowercase(entry))-$(date)-$f"
                rel, sha = snapshot_file(joinpath(date_dir, f), repo_root,
                                         sys_source_dir, "$(date)_$f")
                push!(provenance, Dict(
                    "field_path" => "calibration_snapshots[@$(date)].$f",
                    "value" => f,
                    "source_url" => "$GITHUB_RAW_BASE/data/$entry/$date/$f",
                    "source_kind" => "api_dump",
                    "retrieved_at" => DateTime(today_date),
                    "local_path" => rel,
                    "sha256" => sha,
                    "notes" => "Raw randomized-benchmarking survival data from Quantinuum public repo.",
                ))
                if first_in_date
                    raw_file_rel_representative = rel
                    first_in_date = false
                end
            end

            # Look up the CSV summary row for this (system, date), if present.
            csv_row = nothing
            for r in spec_rows
                if r.machine == entry && r.date == date
                    csv_row = r
                    break
                end
            end

            date_iso = replace(date, "_" => "-")
            snap = Dict{String,Any}(
                "timestamp" => DateTime(Date(date_iso)),
                "raw_file" => raw_file_rel_representative,
                "provenance_idx" => prov_idx_for_date,
            )
            if csv_row !== nothing
                csv_row.err_1q !== nothing && (snap["gate_err_1q_mean"] = csv_row.err_1q)
                csv_row.err_2q !== nothing && (snap["gate_err_2q_mean"] = csv_row.err_2q)
                csv_row.spam   !== nothing && (snap["readout_err_mean"] = csv_row.spam)
            end
            push!(cal_snapshots, snap)
        end

        # Use the latest CSV summary row for the system's top-level fidelity.
        latest_row = nothing
        for r in reverse(spec_rows)
            if r.machine == entry
                latest_row = r
                break
            end
        end

        # 3) Build the TOML dict.
        meta_date = today_date
        doc = Dict{String,Any}()
        doc["meta"] = Dict(
            "id" => meta.slug,
            "org_slug" => "quantinuum",
            "aliases" => [entry, meta.display],
            "schema_version" => "0.1",
            "created_at" => DateTime(meta_date),
            "updated_at" => DateTime(meta_date),
        )
        doc["organization"] = Dict(
            "name" => "Quantinuum",
            "kind" => "commercial",
            "country" => "USA",
            "parent" => "Honeywell / Cambridge Quantum merger (2021)",
            "homepage_url" => "https://www.quantinuum.com/",
        )
        doc["family"] = Dict{String,Any}(
            "name" => meta.family,
            "modality" => "trapped_ion",
        )
        if meta.lineage !== nothing
            doc["family"]["lineage_predecessor"] = meta.lineage
        end

        device_block = Dict{String,Any}(
            "name" => meta.display,
            "status" => "in_service",
            "announced_date" => meta.announced,
            "first_operational_date" => meta.announced,
            "num_qubits" => meta.num_qubits,
            "architecture_notes" => meta.notes,
        )
        doc["device"] = device_block

        doc["topology"] = Dict{String,Any}(
            "kind" => "all_to_all",
            "reconfigurable" => true,
        )

        # Native gates — Quantinuum publishes U1q + Rzz(ZZ) as the primary ones.
        two_q_fid = latest_row !== nothing && latest_row.err_2q !== nothing ?
                    1.0 - latest_row.err_2q : nothing
        one_q_fid = latest_row !== nothing && latest_row.err_1q !== nothing ?
                    1.0 - latest_row.err_1q : nothing
        gates = Any[]
        u1q = Dict{String,Any}("name" => "U1q", "arity" => 1, "kind" => "gate",
                               "params" => ["theta", "phi"],
                               "duration_ns" => 5000.0)
        one_q_fid !== nothing && (u1q["fidelity_mean"] = one_q_fid)
        push!(gates, u1q)

        rzz = Dict{String,Any}("name" => "ZZ", "arity" => 2, "kind" => "gate",
                               "params" => ["theta"],
                               "duration_ns" => 300_000.0)
        two_q_fid !== nothing && (rzz["fidelity_mean"] = two_q_fid)
        push!(gates, rzz)
        push!(gates, Dict{String,Any}("name" => "readout", "arity" => 1, "kind" => "measurement"))
        push!(gates, Dict{String,Any}("name" => "reset", "arity" => 1, "kind" => "reset"))
        doc["native_gates"] = gates

        noise = Dict{String,Any}()
        if latest_row !== nothing && latest_row.spam !== nothing
            noise["readout"] = Dict{String,Any}("fidelity_mean" => 1.0 - latest_row.spam)
        end
        doc["noise_model"] = noise

        if !isempty(cal_snapshots)
            doc["calibration_snapshots"] = cal_snapshots
        end

        doc["timing"] = Dict{String,Any}(
            "single_qubit_gate_ns" => 5_000.0,
            "two_qubit_gate_ns" => 300_000.0,
            "readout_ns" => 350_000.0,
            "reset_ns" => 50_000.0,
        )

        doc["access"] = Dict{String,Any}(
            "cloud_provider" => "quantinuum_systems",
            "api_kind" => "openqasm3",
            "tier" => "paid",
            "auth_required" => true,
            "sdk_packages" => ["pytket", "pytket-quantinuum", "qtm_spec"],
        )

        doc["provenance"] = provenance

        # 4) Write the TOML file.
        target = joinpath(repo_root, "devices", "quantinuum", "$(meta.slug).toml")
        if is_hand_curated(target)
            @info "skipping — target is hand-curated (no ingest marker)" target
            continue
        end
        open(target, "w") do io
            header = """
            # $(meta.display)
            #
            # Auto-generated by scripts/ingest_quantinuum.jl on $(today_date).
            # Source-of-truth clone: $(GITHUB_RAW_BASE)/
            # Edit the ingest script, not the TOML, to change structure.
            # Each calibration_snapshots[i].provenance_idx points into provenance[].
            """
            write(io, header)
            TOML.print(io, doc; sorted=true)
        end
        @info "wrote" target
    end
end

end # module
