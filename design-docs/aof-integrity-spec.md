# Append Only File (AOF) Integrity Header Specification

This document defines the specification for the AOF integrity header introduced in Valkey. The header is designed to provide data integrity guarantees (detecting bit rot, torn writes, and missing log entries) and to carry optional replication metadata.

## 1. Format Rationale

The AOF integrity header is stored in a **structured text format** (ASCII/UTF-8) rather than a binary or Base64-encoded format. 

### Why Text Format?
1. **Readability and Debuggability**: AOF is historically a human-readable format based on RESP (REdis Serialization Protocol). Keeping the header in text format allows developers and administrators to inspect, debug, and edit AOF files using standard text tools (e.g., `cat`, `grep`, `tail`, `vi`).
2. **Tooling Compatibility**: Existing diagnostic tools (like `valkey-check-aof`) can easily parse or skip text-based annotations without needing complex decoding libraries.
3. **Backward Compatibility**: The header starts with a `#` character, which is treated as a comment by older Valkey/Redis versions. This ensures that older loaders will simply ignore the header rather than failing with a syntax error, allowing for safer downgrades or cross-version compatibility (if integrity checks are disabled).
4. **Efficiency**: For the metadata fields we store (integer lengths, offsets, and hex IDs), a direct text representation (decimal/hexadecimal) has negligible overhead compared to binary and is more space-efficient than Base64 encoding.

---

## 2. Formal Grammar (ABNF)

The AOF integrity header MUST conform to the following Augmented Backus-Naur Form (ABNF) grammar (RFC 5234):

```abnf
AOF-HEADER      = "#HDR:" VERSION ";" *FIELD CRLF
VERSION         = "v1" / TOKEN
FIELD           = FIELD-KEY ":" FIELD-VALUE ";"
FIELD-KEY       = "len" / "checksum" / "replid" / "reploff" / TOKEN
FIELD-VALUE     = 1*DIGIT / TOKEN
TOKEN           = 1*(%x30-39 / %x41-5A / %x61-7A / "-" / "_") 
                  ; One or more alphanumeric characters, hyphens, or underscores
CRLF            = %x0D %x0A ; \r\n
```

### Key Rules:
- The header MUST start with `#HDR:`.
- The version string (currently `v1`) immediately follows the header prefix and ends with a semicolon `;`.
- Fields are key-value pairs separated by colons `:` and terminated by semicolons `;`.
- The entire header line MUST end with `CRLF` (`\r\n`).

---

## 3. Well-Known Fields

While the grammar supports arbitrary extension fields, the following fields are standardized:

| Field Name | Type | Description |
| :--- | :--- | :--- |
| `len` | Decimal Integer | The length of the upcoming RESP command block in bytes. |
| `checksum` | Decimal Integer | The continuous CRC64 checksum of the AOF stream up to this point. |
| `replid` | Hex String (40 chars) | (Optional) The replication ID associated with this state (used for replication restore). |
| `reploff` | Decimal Integer | (Optional) The replication offset associated with this state (used for replication restore). |

Example of a standard integrity header:
```text
#HDR:v1;len:45;checksum:1234567890123456789;
```

Example of a header containing replication metadata:
```text
#HDR:v1;len:45;checksum:1234567890123456789;replid:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2;reploff:100500;
```

---

## 4. Versioning and Extensibility

### Header Versioning
- The version token (e.g., `v1`) defines the schema and parsing rules for the header.
- If a future change requires breaking the grammar or changing the fundamental validation model (e.g., changing the checksum algorithm from CRC64 to something else), the version MUST be bumped (e.g., to `v2`).
- A parser encountering an **unknown version** (e.g., a `v1` parser reading a `v2` header) MUST treat this as a fatal error and abort loading, as it cannot guarantee the integrity of the stream.

### Forward Compatibility (Extensibility)
- Within a known version (such as `v1`), the parser MUST ignore any unrecognized fields. 
- For example, a standard Valkey server that only implements integrity checks (and not replication restore) will parse `len` and `checksum` from the header:
  `#HDR:v1;len:45;checksum:123;replid:abc;reploff:789;`
  and will safely ignore the `replid` and `reploff` fields.
- This allows new metadata to be added to the header without breaking older deployments running the same header version.
