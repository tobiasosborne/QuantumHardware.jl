# Minimal schema validator for v0.
#
# NOT a full JSON Schema implementation — just enough to enforce the rules
# that matter most: required top-level sections, required fields, enum values,
# and the dual source-of-truth rule (every provenance entry has a real
# local_path and a valid sha256).
#
# Enum membership is loaded from `schema/device.schema.json` $defs so there
# is one source of truth (see ENUMS in QuantumHardware.jl).
#
# Upgrade to JSONSchema.jl in a future session once Draft 2020-12 support
# stabilises. The hand-rolled path buys us fast feedback with zero deps.

struct ValidationError <: Exception
    path::String
    msg::String
end

Base.showerror(io::IO, e::ValidationError) =
    print(io, "ValidationError at `", e.path, "`: ", e.msg)

const _REQUIRED_TOP = (
    "meta", "organization", "family", "device", "topology",
    "native_gates", "noise_model", "timing", "access", "provenance",
)

const _SHA256_RE = r"^[a-f0-9]{64}$"
const _SOURCES_PATH_RE = r"^sources/\d{4}/\d{2}/\d{2}/"

"""
    load_enums(schema_json_path) -> Dict{Symbol, Vector{String}}

Read `schema/device.schema.json`, extract every `\$defs.<name>.enum` array,
return a Symbol-keyed dictionary. Single source of truth — both `validator.jl`
and any external consumer should use this rather than re-declaring lists.
"""
function load_enums(schema_json_path::AbstractString)
    raw = JSON3.read(read(schema_json_path, String))
    defs = raw[Symbol(raw"$defs")]
    out = Dict{Symbol, Vector{String}}()
    for (name, def) in pairs(defs)
        haskey(def, :enum) || continue
        out[Symbol(name)] = String[String(v) for v in def.enum]
    end
    return out
end

function _require(cond::Bool, path::String, msg::String)
    cond || throw(ValidationError(path, msg))
end

function _enum(val, allowed, path::String)
    val ∈ allowed || throw(ValidationError(path, "`$val` not in $allowed"))
end

"""
    validate_device(d::AbstractDict; filename="<unknown>") -> Nothing

Run v0.1 schema checks against a TOML-parsed dict. Throws `ValidationError`
on the first failure — fail fast. Returns `nothing` on success.

Checks:
- All required top-level sections are present.
- `meta.schema_version == "0.1"`.
- `meta.id` and `meta.org_slug` match their slug patterns.
- `organization.kind`, `family.modality`, `device.status`, `topology.kind`,
  `access.api_kind`, `access.tier` all fall within their controlled vocab.
- `native_gates` is a non-empty array of tables with `name`, `arity`, `kind`.
- `provenance` is a non-empty array; every entry has a 64-hex `sha256` and a
  `local_path` starting with `sources/YYYY/MM/DD/`.
"""
function validate_device(d::AbstractDict; filename::AbstractString="<unknown>")
    for k in _REQUIRED_TOP
        _require(haskey(d, k), filename, "missing top-level section `$k`")
    end

    meta = d["meta"]
    _enum(meta["schema_version"], ("0.1",), "$filename:meta.schema_version")
    _require(occursin(r"^[a-z0-9][a-z0-9-]*[a-z0-9]$", meta["id"]),
             "$filename:meta.id", "id must be kebab-case slug, got `$(meta["id"])`")
    _require(occursin(r"^[a-z0-9][a-z0-9_]*[a-z0-9]$", meta["org_slug"]),
             "$filename:meta.org_slug", "org_slug must be snake-case, got `$(meta["org_slug"])`")

    org = d["organization"]
    _enum(org["kind"], ENUMS[:org_kind], "$filename:organization.kind")
    _require(occursin(r"^[A-Z]{3}$", org["country"]),
             "$filename:organization.country", "expected ISO alpha-3, got `$(org["country"])`")

    fam = d["family"]
    _enum(fam["modality"], ENUMS[:modality], "$filename:family.modality")

    dev = d["device"]
    _enum(dev["status"], ENUMS[:status], "$filename:device.status")
    _require(isa(dev["num_qubits"], Integer) && dev["num_qubits"] >= 0,
             "$filename:device.num_qubits", "must be a non-negative integer")

    topo = d["topology"]
    _enum(topo["kind"], ENUMS[:topology_kind], "$filename:topology.kind")
    _require(isa(topo["reconfigurable"], Bool),
             "$filename:topology.reconfigurable", "must be a boolean")

    gates = d["native_gates"]
    _require(isa(gates, AbstractVector) && !isempty(gates),
             "$filename:native_gates", "must be a non-empty array")
    for (i, g) in pairs(gates)
        for k in ("name","arity","kind")
            _require(haskey(g, k), "$filename:native_gates[$i]", "missing `$k`")
        end
        _enum(g["kind"], ENUMS[:native_gate_kind], "$filename:native_gates[$i].kind")
    end

    acc = d["access"]
    _enum(acc["api_kind"], ENUMS[:api_kind], "$filename:access.api_kind")
    _enum(acc["tier"], ENUMS[:access_tier], "$filename:access.tier")
    _require(isa(acc["auth_required"], Bool),
             "$filename:access.auth_required", "must be a boolean")

    prov = d["provenance"]
    _require(isa(prov, AbstractVector) && !isempty(prov),
             "$filename:provenance", "must be a non-empty array")
    for (i, p) in pairs(prov)
        for k in ("field_path","value","source_url","source_kind","retrieved_at","local_path","sha256")
            _require(haskey(p, k), "$filename:provenance[$i]", "missing `$k`")
        end
        _require(occursin(_SHA256_RE, p["sha256"]),
                 "$filename:provenance[$i].sha256",
                 "must be 64 lowercase hex chars, got `$(p["sha256"])`")
        _require(occursin(_SOURCES_PATH_RE, p["local_path"]),
                 "$filename:provenance[$i].local_path",
                 "must start with sources/YYYY/MM/DD/, got `$(p["local_path"])`")
    end

    return nothing
end

"""
    validate_device_file(path::AbstractString) -> Nothing

Convenience wrapper: parse the TOML at `path` and run `validate_device`.
"""
function validate_device_file(path::AbstractString)
    dict = TOML.parsefile(path)
    validate_device(dict; filename=path)
    return nothing
end

"""
    verify_archive_integrity(dev_toml::AbstractDict, root::AbstractString) -> Nothing

For each provenance entry, check that `root/<local_path>` exists and that its
SHA-256 matches. This is the strong integrity check — run it in CI.
"""
function verify_archive_integrity(dev_toml::AbstractDict, root::AbstractString)
    for (i, p) in pairs(dev_toml["provenance"])
        path = joinpath(root, p["local_path"])
        isfile(path) || throw(ValidationError(
            "provenance[$i].local_path",
            "archive file not found on disk: `$path`",
        ))
        actual = bytes2hex(open(sha256, path))
        actual == p["sha256"] || throw(ValidationError(
            "provenance[$i].sha256",
            "archive content hash mismatch:\n  expected `$(p["sha256"])`\n  actual   `$actual`\n  path    `$path`",
        ))
    end
    return nothing
end
