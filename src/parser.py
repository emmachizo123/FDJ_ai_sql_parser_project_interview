"""
Lightweight end-to-end pipeline for extracting structured transformation metadata
from Oracle PL/SQL package bodies.

Workflow:
1. Read an input SQL/PLSQL package body from disk.
2. Split the package into individual PROCEDURE/FUNCTION text chunks.
3. Preprocess each subprogram to produce a clean promptable representation.
4. Send one subprogram at a time to an LLM for schema-constrained JSON extraction.
5. Apply deterministic validation checks to the returned JSON.
6. Convert validation results into a simple confidence score.
7. Write one output JSON file per processed subprogram.

Typical usage:
    python src/parser.py --procedure Stage_User_Data

Useful options:
    python src/parser.py --list-only
    python src/parser.py --skip-llm
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

from openai import OpenAI

# Project root (parent of src/)
PROJECT_ROOT = Path(__file__).resolve().parent.parent

DEFAULT_INPUT = PROJECT_ROOT / "inputfiles" / "bingo_data_hourly_load_CLEAN.sql"
SCHEMA_PATH = PROJECT_ROOT / "schema" / "transformation_schema.json"
OUTPUT_DIR = PROJECT_ROOT / "output"
SYSTEM_PROMPT_PATH = PROJECT_ROOT / "prompts" / "system_prompt.txt"
USER_PROMPT_TEMPLATE_PATH = PROJECT_ROOT / "prompts" / "user_prompt_template.txt"

SUBPROGRAM_RE = re.compile(
    r"^\s*(PROCEDURE|FUNCTION)\s+(\w+)\s*\(",
    re.IGNORECASE | re.MULTILINE,
)
PACKAGE_BODY_RE = re.compile(
    r"PACKAGE\s+BODY\s+(?:[\w$]+\.)?(\w+)\s+AS\b",
    re.IGNORECASE,
)


def load_dotenv_file() -> None:
    """
    Load environment variables from a project-root `.env` file when available.

    This helper is optional by design:
    - If `python-dotenv` is installed, the function tries to load `.env`.
    - If `python-dotenv` is not installed, the function silently does nothing.
    - If no `.env` file exists, the function also does nothing.

    Why this exists:
    It makes local development easier by allowing `OPENAI_API_KEY` to be stored
    in `.env` instead of being manually exported in every shell session.
    """
    try:
        from dotenv import load_dotenv
    except ImportError:
        return

    env_path = PROJECT_ROOT / ".env"
    if env_path.is_file():
        load_dotenv(env_path)


def load_schema_keys() -> list[str]:
    """
    Read the schema template file and return its top-level keys.

    The current project uses a lightweight JSON template such as:
        {
          "procedure_name": "string",
          "summary": "string",
          ...
        }

    Those top-level keys are treated as required output fields during
    deterministic validation of the LLM response.

    Returns:
        list[str]: Top-level keys expected in the extracted JSON payload.

    Note:
        This implementation is appropriate for the current simple template schema.
        If the project later moves to formal JSON Schema (draft-07 or similar),
        this function should be updated to read fields from `required` or
        `properties` instead.
    """
    data = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    return list(data.keys())


REQUIRED_OUTPUT_KEYS = load_schema_keys()


# --- Step 1–2: ingestion + procedure boundaries ---


def read_sql_file(path: Path) -> str:
    """
    Read the input SQL/PLSQL file from disk as text.

    Args:
        path: Path to the SQL or PL/SQL source file.

    Returns:
        str: Full file contents as a Unicode string.

    Why `errors="replace"` is used:
        Real-world SQL files can sometimes contain unexpected or imperfect
        character encodings. Using `replace` prevents the script from failing
        outright on a decode problem and keeps the prototype robust.
    """
    return path.read_text(encoding="utf-8", errors="replace")


def extract_package_name(sql: str) -> str | None:
    """
    Extract the Oracle package body name from the supplied SQL text.

    Example match:
        CREATE OR REPLACE PACKAGE BODY SCHEMA_ETL.PKG_API_DATA_LOADER AS

    In the example above, this function returns:
        PKG_API_DATA_LOADER

    Args:
        sql: Full package body text.

    Returns:
        str | None:
            The package body name if found, otherwise None.

    Why this matters:
        The package name is later used to find the package terminator line
        (e.g. `END PKG_API_DATA_LOADER;`), which helps define safe boundaries
        for procedure/function extraction.
    """
    match = PACKAGE_BODY_RE.search(sql)
    return match.group(1) if match else None


def extract_subprograms(sql: str) -> list[dict[str, str]]:
    """
    Split a package body into top-level PROCEDURE/FUNCTION text chunks.

    This is a deterministic, regex-based chunking step. It does not attempt to
    fully parse PL/SQL grammar; instead, it identifies top-level subprogram
    declarations and slices the package body into manageable units.

    Strategy:
    1. Extract the package body name.
    2. Find the package terminator line: `END <package_name>;`
    3. Search the package body for top-level `PROCEDURE` or `FUNCTION` headers.
    4. Slice from the current subprogram start to the next subprogram start,
       or to the package end if it is the last one.

    Args:
        sql: Full Oracle package body text.

    Returns:
        list[dict[str, str]]: A list of dictionaries, each with:
            - "kind": "PROCEDURE" or "FUNCTION"
            - "name": subprogram name
            - "text": full text chunk for that subprogram

    Limitations:
        This is intentionally lightweight and suitable for the interview task.
        A production-grade solution would likely use a more robust parser or
        grammar-aware approach.
    """
    pkg = extract_package_name(sql)
    if not pkg:
        return []

    end_pkg = re.search(
        rf"^\s*END\s+{re.escape(pkg)}\s*;",
        sql,
        re.MULTILINE | re.IGNORECASE,
    )
    if not end_pkg:
        return []

    body = sql[: end_pkg.start()]
    matches = list(SUBPROGRAM_RE.finditer(body))
    out: list[dict[str, str]] = []

    for i, match in enumerate(matches):
        kind, name = match.group(1).upper(), match.group(2)
        start = match.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else end_pkg.start()
        chunk = body[start:end].strip()
        out.append({"kind": kind, "name": name, "text": chunk})

    return out


# --- Step 3: preprocessing ---


def strip_sql_comments(sql: str) -> str:
    """
    Remove SQL/PLSQL comments from a text block.

    Supported comment styles:
    - Block comments: /* ... */
    - Single-line comments: -- ...

    Args:
        sql: Raw SQL/PLSQL text.

    Returns:
        str: SQL text with comments removed.

    Why this matters:
        Comments are useful for humans, but they can add noise to:
        - prompt input
        - pattern matching
        - deterministic validation
    """
    stripped = re.sub(r"/\*.*?\*/", "", sql, flags=re.DOTALL)
    stripped = re.sub(r"--[^\n]*", "", stripped)
    return stripped


def normalize_whitespace(sql: str) -> str:
    """
    Collapse repeated whitespace into single spaces and trim edges.

    Args:
        sql: SQL/PLSQL text.

    Returns:
        str: A compact single-line-style representation of the text.

    Why this matters:
        A normalized version is useful for:
        - previews in output JSON
        - simpler string-based validation
        - cleaner prompt inputs
    """
    return re.sub(r"\s+", " ", sql).strip()


def preprocess_subprogram(text: str, fallback_name: str = "") -> dict[str, Any]:
    """
    Produce a lightweight preprocessed representation of a single subprogram.

    This step keeps both:
    - the original raw text (best for LLM analysis)
    - a cleaned compact version (useful for previews and debugging)

    It also attempts to extract coarse header information such as:
    - subprogram name
    - parameter block

    Args:
        text: Full text of a single procedure or function.
        fallback_name: Name discovered earlier during chunking; used if the
            header regex cannot recover the name from the raw text.

    Returns:
        dict[str, Any]: Dictionary with:
            - "name": detected or fallback subprogram name
            - "parameter_block": raw parameter block text if found
            - "body_text_clean": comment-stripped, whitespace-normalized text
            - "raw_text": original unchanged text chunk

    Why this matters:
        This provides a consistent interface between extraction/chunking and the
        LLM step without trying to fully parse PL/SQL.
    """
    raw = text
    cleaned = normalize_whitespace(strip_sql_comments(text))
    match = re.search(
        r"(PROCEDURE|FUNCTION)\s+(\w+)\s*(\((?:[^()]|\([^()]*\))*\))?\s*(?:RETURN\s+[\w\s().%$]+\s*)?(IS|AS)\b",
        raw,
        re.IGNORECASE | re.DOTALL,
    )
    name = (match.group(2) if match else "") or fallback_name
    params = (match.group(3) or "").strip()

    return {
        "name": name,
        "parameter_block": params,
        "body_text_clean": cleaned,
        "raw_text": raw,
    }


# --- Step 4: LLM ---


def apply_user_prompt_template(template: str, schema_json: str, procedure_text: str) -> str:
    """
    Populate the user-prompt template with the schema and procedure text.

    The prompt template is expected to contain these placeholders:
    - {{schema_json}}
    - {{procedure_text}}

    Args:
        template: Raw prompt template text loaded from file.
        schema_json: Schema template serialized as JSON/text.
        procedure_text: Raw procedure/function text to analyze.

    Returns:
        str: Final user prompt ready to send to the LLM.

    Why plain string replacement is used:
        This avoids accidental formatting issues caused by braces that may appear
        inside SQL text or JSON examples.
    """
    return template.replace("{{schema_json}}", schema_json).replace("{{procedure_text}}", procedure_text)


def build_llm_messages(
    system_prompt: str,
    user_template: str,
    schema_json: str,
    procedure_text: str,
) -> list[dict[str, str]]:
    """
    Build the chat message payload for the OpenAI Chat Completions API.

    Args:
        system_prompt: System-level instruction text defining LLM behavior.
        user_template: User prompt template containing placeholders.
        schema_json: Schema template that constrains output shape.
        procedure_text: The specific subprogram text to analyze.

    Returns:
        list[dict[str, str]]: Chat messages in OpenAI format.

    Why this matters:
        Separating the system prompt from the user prompt keeps the design clear:
        - system prompt controls behavior and constraints
        - user prompt supplies task-specific content
    """
    user = apply_user_prompt_template(user_template, schema_json, procedure_text)
    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user},
    ]


def call_llm(messages: list[dict[str, str]], model: str) -> dict[str, Any]:
    """
    Send the prepared chat messages to the LLM and parse the JSON response.

    Args:
        messages: Chat payload consisting of system and user messages.
        model: OpenAI model name, for example `gpt-4o-mini`.

    Returns:
        dict[str, Any]: Parsed JSON response from the model.

    Raises:
        json.JSONDecodeError: If the returned content cannot be parsed as JSON.
        Exception: Any upstream API/client error is allowed to bubble up and is
            handled by the caller.

    Important detail:
        `response_format={"type": "json_object"}` requests JSON output from the
        model. This improves reliability but does not replace downstream
        validation.
    """
    client = OpenAI()
    resp = client.chat.completions.create(
        model=model,
        messages=messages,
        response_format={"type": "json_object"},
    )
    content = resp.choices[0].message.content or "{}"
    return json.loads(content)


def format_llm_error(exc: BaseException) -> str:
    """
    Rewrite common OpenAI API errors into more helpful human-readable messages.

    Args:
        exc: The original exception raised by the OpenAI client.

    Returns:
        str: A more descriptive error message.

    Why this exists:
        Some API failures are technically correct but confusing in practice.
        For example, a valid API key can still fail because the account has no
        available quota or billing is not configured.
    """
    text = str(exc)

    if "insufficient_quota" in text:
        return (
            f"{text}\n\n"
            "Your API key is being accepted; OpenAI returned insufficient_quota "
            "(no usable credits / billing).\n"
            "Check plan, payment method, and usage limits: "
            "https://platform.openai.com/account/billing\n"
            "Org or project budget caps (in OpenAI dashboard) can also block spend."
        )

    if "429" in text and "rate" not in text.lower():
        return (
            f"{text}\n\n"
            "HTTP 429 often means rate limits or quota. If the message mentions "
            "quota/billing, fix billing first."
        )

    return text


# --- Step 5–6: validation + scoring ---


def flatten_strings(obj: Any) -> list[str]:
    """
    Recursively collect all string leaf values from a nested Python object.

    Supported container types:
    - dict
    - list
    - scalar strings

    Args:
        obj: Nested structure such as a parsed JSON object.

    Returns:
        list[str]: All string leaf values longer than two characters.

    Why this matters:
        It enables simple grounding checks by flattening nested `source` or
        `target` objects into comparable strings without caring about their
        internal nesting depth.
    """
    out: list[str] = []

    if isinstance(obj, str):
        if len(obj) > 2:
            out.append(obj)
    elif isinstance(obj, dict):
        for value in obj.values():
            out.extend(flatten_strings(value))
    elif isinstance(obj, list):
        for value in obj:
            out.extend(flatten_strings(value))

    return out


def validate_extraction(
    data: dict[str, Any],
    expected_procedure_name: str,
    source_sql_upper: str,
) -> dict[str, Any]:
    """
    Run lightweight deterministic validation checks against the LLM output.

    Validation categories:
    1. Structural checks:
       - required top-level keys exist
       - procedure_name is populated
    2. Identity checks:
       - extracted procedure name matches the expected chunk name
    3. Grounding checks:
       - source/target strings appear in the SQL text
       - claimed Oracle features appear in the SQL text
    4. Completeness checks:
       - warn if business_rules is empty

    Args:
        data: Parsed JSON returned by the LLM.
        expected_procedure_name: Procedure/function name discovered during
            deterministic chunking.
        source_sql_upper: Uppercased comment-stripped SQL text used for
            case-insensitive grounding checks.

    Returns:
        dict[str, Any]: Validation result with:
            - "status": one of pass, warn, fail
            - "errors": hard validation failures
            - "warnings": softer trust/completeness issues

    Note:
        These checks are intentionally lightweight. They are designed to support
        the interview prototype, not to fully prove semantic correctness.
    """
    errors: list[str] = []
    warnings: list[str] = []

    for key in REQUIRED_OUTPUT_KEYS:
        if key not in data:
            errors.append(f"missing_required_key:{key}")

    proc = str(data.get("procedure_name", "")).strip()
    if proc and proc.upper() != expected_procedure_name.upper():
        warnings.append(
            f"procedure_name_mismatch:json={proc!r} expected={expected_procedure_name!r}"
        )
    if not proc:
        errors.append("procedure_name_empty")

    if not errors:
        exp_upper = expected_procedure_name.upper()
        if exp_upper not in source_sql_upper:
            errors.append("procedure_name_not_in_source_text")

    # Target / source grounding: string leaves should appear in source (simple)
    for label in ("target", "source"):
        block = data.get(label)
        if isinstance(block, dict) and block:
            for value in flatten_strings(block):
                if len(value) > 3 and value.upper() not in source_sql_upper:
                    warnings.append(f"{label}_ungrounded:{value[:80]}")

    # Oracle features: substring check
    feats = data.get("oracle_specific_features")
    if isinstance(feats, list):
        for feat in feats:
            if isinstance(feat, str) and feat and feat.upper() not in source_sql_upper:
                warnings.append(f"oracle_feature_not_found:{feat}")

    # Business rules: soft — warn if empty
    br = data.get("business_rules")
    if isinstance(br, list) and len(br) == 0:
        warnings.append("business_rules_empty")

    status = "pass"
    if errors:
        status = "fail"
    elif warnings:
        status = "warn"

    return {
        "status": status,
        "errors": errors,
        "warnings": warnings,
    }


def confidence_from_validation(validation: dict[str, Any]) -> dict[str, Any]:
    """
    Convert validation results into a simple numeric score and qualitative label.

    Scoring model:
    - Start at 10
    - Subtract 3 points per error
    - Subtract 1 point per warning
    - Clamp score to the range [0, 10]

    Confidence bands:
    - 8 to 10  -> high
    - 5 to 7   -> medium
    - 0 to 4   -> low

    Args:
        validation: Output from `validate_extraction`.

    Returns:
        dict[str, Any]: Dictionary with:
            - "confidence": high / medium / low
            - "confidence_score": integer score from 0 to 10

    Why this matters:
        This gives the prototype a simple trust signal that can be used for:
        - display
        - filtering
        - human review routing
    """
    score = 10
    score -= 3 * len(validation["errors"])
    score -= 1 * len(validation["warnings"])
    score = max(0, min(10, score))

    if score >= 8:
        label = "high"
    elif score >= 5:
        label = "medium"
    else:
        label = "low"

    return {"confidence": label, "confidence_score": score}


def merge_confidence_into_payload(data: dict[str, Any], conf: dict[str, Any]) -> None:
    """
    Copy confidence information into the extracted payload in-place.

    Args:
        data: LLM-extracted JSON object.
        conf: Confidence dictionary returned by `confidence_from_validation`.

    Side effects:
        Mutates `data` by adding:
        - confidence
        - confidence_score (if not already present)

    Why this exists:
        It keeps the extracted payload self-contained so that the extraction
        object can still be inspected independently of the outer wrapper record.
    """
    data["confidence"] = conf["confidence"]
    if "confidence_score" not in data:
        data["confidence_score"] = conf["confidence_score"]


# --- CLI ---


def parse_args() -> argparse.Namespace:
    """
    Define and parse command-line arguments for the script.

    Supported options:
    - --input: path to SQL file
    - --procedure: process only one named procedure/function
    - --output-dir: destination for JSON outputs
    - --model: OpenAI model name
    - --skip-llm: run only deterministic preprocessing/chunking
    - --list-only: print discovered subprogram names and exit

    Returns:
        argparse.Namespace: Parsed command-line arguments.

    Why this matters:
        The script is intentionally designed as a small CLI utility so that it
        can be demonstrated easily and reviewed without extra infrastructure.
    """
    parser = argparse.ArgumentParser(description="PL/SQL → JSON transformation extractor")
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT, help="SQL file path")
    parser.add_argument(
        "--procedure",
        type=str,
        default=None,
        help="Process only this procedure/function name (default: all)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=OUTPUT_DIR,
        help="Directory for JSON results",
    )
    parser.add_argument("--model", type=str, default="gpt-4o-mini", help="OpenAI chat model")
    parser.add_argument(
        "--skip-llm",
        action="store_true",
        help="Run extraction + preprocessing only (no API call)",
    )
    parser.add_argument(
        "--list-only",
        action="store_true",
        help="List procedure names and exit",
    )
    return parser.parse_args()


def main() -> int:
    """
    Orchestrate the full extraction workflow for one or more PL/SQL subprograms.

    High-level flow:
    1. Load environment variables (optional `.env`)
    2. Parse CLI arguments
    3. Read input SQL file
    4. Extract package subprograms
    5. Optionally list subprogram names and exit
    6. Load schema and prompt files
    7. Select all or one named subprogram
    8. For each selected subprogram:
       - preprocess
       - optionally skip LLM and write debug output
       - call the LLM
       - validate the response
       - score confidence
       - write JSON output file

    Returns:
        int: Process exit code.
            - 0 on success
            - 1 on input/config/API errors

    Why this function matters:
        It is the orchestration layer that ties together deterministic parsing,
        LLM extraction, validation, scoring, and output persistence.
    """
    load_dotenv_file()
    args = parse_args()

    sql_path: Path = args.input
    if not sql_path.is_file():
        print(f"Input not found: {sql_path}", file=sys.stderr)
        return 1

    text = read_sql_file(sql_path)
    subs = extract_subprograms(text)
    if not subs:
        print("No PROCEDURE/FUNCTION units found (is this a PACKAGE BODY?).", file=sys.stderr)
        return 1

    if args.list_only:
        for sub in subs:
            print(f"{sub['kind']}\t{sub['name']}")
        return 0

    schema_template = SCHEMA_PATH.read_text(encoding="utf-8")
    args.output_dir.mkdir(parents=True, exist_ok=True)

    system_prompt = ""
    user_template = ""
    if not args.skip_llm:
        try:
            system_prompt = SYSTEM_PROMPT_PATH.read_text(encoding="utf-8").strip()
            user_template = USER_PROMPT_TEMPLATE_PATH.read_text(encoding="utf-8")
        except OSError as exc:
            print(f"Failed to read prompt files: {exc}", file=sys.stderr)
            return 1

    selected = subs
    if args.procedure:
        needle = args.procedure.strip().upper()
        selected = [sub for sub in subs if sub["name"].upper() == needle]
        if not selected:
            print(f"Procedure not found: {args.procedure}", file=sys.stderr)
            return 1

    for sub in selected:
        pre = preprocess_subprogram(sub["text"], sub["name"])
        source_upper = strip_sql_comments(sub["text"]).upper()

        record: dict[str, Any] = {
            "source_file": str(sql_path.relative_to(PROJECT_ROOT)),
            "subprogram_kind": sub["kind"],
            "expected_name": sub["name"],
            "preprocessing": {
                "parameter_block": pre["parameter_block"],
                "body_preview": pre["body_text_clean"][:500]
                + ("…" if len(pre["body_text_clean"]) > 500 else ""),
            },
            "llm_extraction": None,
            "validation": None,
            "confidence": None,
            "confidence_score": None,
            "human_review_recommended": False,
        }

        if args.skip_llm:
            out_path = args.output_dir / f"{sub['name']}_preprocess_only.json"
            record["note"] = "LLM step skipped"
            out_path.write_text(json.dumps(record, indent=2), encoding="utf-8")
            print(f"Wrote {out_path}")
            continue

        if not os.environ.get("OPENAI_API_KEY"):
            print("OPENAI_API_KEY is not set. Use --skip-llm to test extraction.", file=sys.stderr)
            return 1

        try:
            messages = build_llm_messages(
                system_prompt,
                user_template,
                schema_template,
                pre["raw_text"],
            )
            extracted = call_llm(messages, args.model)
        except Exception as exc:
            print(f"LLM error for {sub['name']}: {format_llm_error(exc)}", file=sys.stderr)
            return 1

        validation = validate_extraction(extracted, sub["name"], source_upper)
        conf = confidence_from_validation(validation)

        merge_confidence_into_payload(extracted, conf)
        record["llm_extraction"] = extracted
        record["validation"] = validation
        record["confidence"] = conf["confidence"]
        record["confidence_score"] = conf["confidence_score"]
        record["human_review_recommended"] = (
            validation["status"] == "fail" or conf["confidence"] == "low"
        )

        out_path = args.output_dir / f"{sub['name']}.json"
        out_path.write_text(json.dumps(record, indent=2), encoding="utf-8")
        print(
            f"Wrote {out_path}  "
            f"[{validation['status']}]  "
            f"confidence={conf['confidence']} ({conf['confidence_score']}/10)"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())