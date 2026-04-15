# src/ingest/braket.jl
#
# Ingest adapter for AWS Braket QPU devices.
#
# Two pathways:
#   (A) Public pathway (no AWS creds): scrape the Braket developer-guide
#       "Supported devices" HTML page for the canonical ARN list, emit one
#       TOML per device with status=in_service. Numeric specs (qubit count,
#       coupling, fidelity, T1/T2) come from the vendor's public data rather
#       than the live GetDevice payload. THIS is what the current script uses.
#   (B) Live pathway (requires AWS creds): call `GetDevice` for each ARN and
#       parse `deviceCapabilities` using amazon-braket-schemas. NOT IMPLEMENTED
#       yet — see Session 1 WORKLOG note.
#
# Pathway A is intentionally coarse: the goal is to land a complete device-list
# quickly; pathway B fills in the calibration detail once creds are available.

module BraketIngest

using TOML
using SHA
using Dates

using QuantumHardware.IngestCommon: is_hand_curated, snapshot_file

const AWS_DOCS_URL = "https://docs.aws.amazon.com/braket/latest/developerguide/braket-devices.html"
const CONFIG_PATH  = joinpath(@__DIR__, "config", "braket.toml")

"""
Vendor presets and per-device overrides loaded from `config/braket.toml`.
Adding a new Braket ARN should mean editing the config TOML, not this file.
"""
function _load_config(path::AbstractString = CONFIG_PATH)
    cfg = TOML.parsefile(path)
    presets   = Dict{String, NamedTuple}(k => _to_namedtuple(v) for (k, v) in cfg["vendor"])
    overrides = Dict{String, NamedTuple}(k => _to_namedtuple(v) for (k, v) in cfg["device"])
    return (; presets, overrides)
end

_to_namedtuple(d::AbstractDict) =
    NamedTuple{Tuple(Symbol(k) for k in keys(d))}(Tuple(values(d)))

const _CONFIG          = _load_config()
const VENDOR_PRESETS   = _CONFIG.presets
const DEVICE_OVERRIDES = _CONFIG.overrides

"""
Extract `(vendor, model, arn)` tuples from the AWS Braket "Supported devices"
HTML by regex. Robust to the current layout; may break if AWS redesigns the
page — tolerable for a docs-scraping path since pathway B (live GetDevice) is
the future canonical source.
"""
function parse_braket_devices(html_path::AbstractString)
    text = read(html_path, String)
    arns = String[]
    for m in eachmatch(r"arn:aws:braket:[a-z0-9-]+::device/qpu/([a-z]+)/([A-Za-z0-9-]+)", text)
        arn = m.match
        arn ∈ arns && continue
        push!(arns, arn)
    end
    parsed = Tuple{String,String,String}[]
    for arn in arns
        m = match(r"device/qpu/([a-z]+)/([A-Za-z0-9-]+)$", arn)
        m === nothing && continue
        push!(parsed, (m.captures[1], m.captures[2], arn))
    end
    return parsed
end

"""
    ingest(; repo_root, today_date=today(), docs_html=<path>)

Public pathway (A). Reads the AWS docs HTML (caller must have fetched it
into `sources/YYYY/MM/DD/aws-braket-devices.html`), emits one TOML per
unique QPU ARN.

Existing TOMLs at the target slug are preserved if they have richer content
than we'd emit (detected by checking for non-empty `calibration_snapshots`).
This protects the Session-1 hand-curated `quera-aquila.toml` from being
overwritten by the coarser docs-scrape version.
"""
function ingest(; repo_root::AbstractString,
                  today_date::Date = today(),
                  docs_html::Union{Nothing, AbstractString} = nothing)
    sources_today = joinpath(repo_root, "sources",
                             string(year(today_date)),
                             string(month(today_date); pad=2),
                             string(day(today_date); pad=2))
    mkpath(sources_today)

    # Locate the AWS docs snapshot. We DO NOT fetch here — scripts/ingest_braket.jl
    # owns the network IO. This module only reads and writes.
    docs_html === nothing && (docs_html = joinpath(sources_today, "aws-braket-devices.html"))
    isfile(docs_html) || error("AWS Braket docs snapshot not found at $docs_html — run scripts/ingest_braket.jl which fetches it")
    docs_rel = relpath(docs_html, repo_root)
    docs_sha = bytes2hex(open(sha256, docs_html))

    devices = parse_braket_devices(docs_html)
    @info "parsed ARNs" count=length(devices)

    for (vendor, model, arn) in devices
        key = "$vendor/$model"
        override = get(DEVICE_OVERRIDES, key, nothing)
        preset = get(VENDOR_PRESETS, vendor, nothing)
        if override === nothing || preset === nothing
            @warn "no override/preset for" vendor model
            continue
        end

        out_path = joinpath(repo_root, "devices", vendor, "$(override.slug).toml")
        if is_hand_curated(out_path)
            @info "skipping — target is hand-curated (no ingest marker)" out_path
            continue
        end
        if isfile(out_path)
            existing = TOML.parsefile(out_path)
            if haskey(existing, "calibration_snapshots") && !isempty(existing["calibration_snapshots"])
                @info "skipping — existing TOML has richer calibration_snapshots" out_path
                continue
            end
        end

        mkpath(dirname(out_path))

        doc = Dict{String,Any}(
            "meta" => Dict(
                "id" => override.slug,
                "org_slug" => vendor,
                "aliases" => [override.display, arn, model],
                "schema_version" => "0.1",
                "created_at" => DateTime(today_date),
                "updated_at" => DateTime(today_date),
            ),
            "organization" => Dict(
                "name" => preset.org,
                "kind" => "commercial",
                "country" => preset.country,
            ),
            "family" => Dict{String,Any}(
                "name" => override.family,
                "modality" => preset.modality,
            ),
            "device" => Dict{String,Any}(
                "name" => override.display,
                "status" => "in_service",
                "announced_date" => override.announced,
                "first_operational_date" => override.announced,
                "num_qubits" => override.num_qubits,
                "architecture_notes" => override.notes,
            ),
            "topology" => Dict{String,Any}(
                "kind" => override.topology_kind,
                "reconfigurable" => override.topology_kind == "analog_hamiltonian" ||
                                    override.topology_kind == "reconfigurable",
            ),
            "native_gates" => Any[
                Dict{String,Any}("name" => "native_1q", "arity" => 1, "kind" => "gate",
                                 "duration_ns" => preset.single_ns),
                Dict{String,Any}("name" => "native_2q", "arity" => 2, "kind" => "gate",
                                 "duration_ns" => preset.two_ns),
                Dict{String,Any}("name" => "readout", "arity" => 1, "kind" => "measurement",
                                 "duration_ns" => preset.readout_ns),
                Dict{String,Any}("name" => "reset", "arity" => 1, "kind" => "reset"),
            ],
            "noise_model" => Dict{String,Any}(),  # populated by pathway B
            "timing" => Dict{String,Any}(
                "single_qubit_gate_ns" => preset.single_ns,
                "two_qubit_gate_ns" => preset.two_ns,
                "readout_ns" => preset.readout_ns,
            ),
            "access" => Dict{String,Any}(
                "cloud_provider" => preset.cloud,
                "api_kind" => preset.api_kind,
                "api_endpoint" => "https://braket.$(region_of(arn)).amazonaws.com/",
                "tier" => "paid",
                "auth_required" => true,
                "pricing_notes" => "Per-shot pricing via AWS Braket task API.",
                "sdk_packages" => ["amazon-braket-sdk"],
            ),
            "provenance" => Any[
                Dict{String,Any}(
                    "field_path" => "meta.aliases (ARN)",
                    "value" => arn,
                    "source_url" => AWS_DOCS_URL,
                    "source_kind" => "vendor_doc",
                    "retrieved_at" => DateTime(today_date),
                    "local_path" => docs_rel,
                    "sha256" => docs_sha,
                    "notes" => "Canonical ARN list from AWS Braket developer guide, supported-devices page.",
                ),
            ],
        )

        open(out_path, "w") do io
            write(io, """
            # $(override.display)
            #
            # Auto-generated by scripts/ingest_braket.jl on $(today_date).
            # Source: $(AWS_DOCS_URL)
            # Pathway: A (docs-scrape; no AWS creds required). Numeric gate times
            # and qubit counts are vendor-baseline values — the live GetDevice
            # capabilities payload will overwrite these once pathway B is wired up.
            # Existing files with richer calibration_snapshots are preserved.
            """)
            TOML.print(io, doc; sorted=true)
        end
        @info "wrote" out_path
    end
end

function region_of(arn::AbstractString)
    m = match(r"arn:aws:braket:([a-z0-9-]*)::", arn)
    m === nothing && return "us-east-1"
    reg = m.captures[1]
    return isempty(reg) ? "us-east-1" : reg
end

end # module
