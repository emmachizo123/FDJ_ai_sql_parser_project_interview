# AI-Powered SQL Transformation Parser

## Overview

This project is a lightweight prototype for extracting structured transformation metadata from Oracle PL/SQL.

It combines:

- LLM interpretation (to understand SQL transformation intent)
- deterministic checks (to keep output grounded and reviewable)

The goal is not full SQL migration. The goal is to turn procedure logic into machine-readable JSON that can later be stored in systems like Databricks or AWS.

---

## Contents

```text
project-root/
├── analysis/   high-level analysis of both SQL files
├── workflow/   workflow and validation design
├── src/        parser implementation (`parser.py`)
├── prompts/    prompt files used by the parser
├── schema/     output schema template
├── output/     generated JSON outputs
├── inputfiles/ provided SQL files
└── README.md
```

---

## Task Summary

### Task 1 - Analysis

- Reviewed both input files:
  - `inputfiles/bingo_data_hourly_load_CLEAN.sql`
  - `inputfiles/value_segments_daily_load_CLEAN.pkb`
- Identified ETL and transformation patterns (ingestion, staging, segmentation/classification)
- Documented Oracle-specific constructs that will need migration handling
- Defined an extraction workflow with validation and confidence scoring

### Task 2 - Parsing Tool

Prototype focus procedure: **`Stage_User_Data`** from `inputfiles/bingo_data_hourly_load_CLEAN.sql`.

The parser:

- extracts subprograms deterministically
- sends one procedure/function at a time to the LLM
- returns structured JSON (source, target, mappings, transformations, Oracle features)
- runs deterministic validation checks
- adds confidence + review recommendation metadata

### Task 3 - Workflow Design

Defined a practical orchestration flow for:

- validation and warning/error surfacing
- confidence-based routing
- optional human review for low-trust outputs

---

## How to Run

### 1) Set up the environment

**macOS / Linux / Git Bash**

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

**Windows PowerShell**

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

### 2) Set `OPENAI_API_KEY`

Choose one:

**Environment variable**

```bash
export OPENAI_API_KEY=your_key_here
```

PowerShell:

```powershell
$env:OPENAI_API_KEY = "your_key_here"
```

**`.env` file (recommended)**

Copy `.env.example` to `.env` and set:

```env
OPENAI_API_KEY=your_key_here
```

### 3) Run the parser

List available procedures/functions in the default file:

```bash
python src/parser.py --list-only
```

Run all procedures in `inputfiles/bingo_data_hourly_load_CLEAN.sql`:

```bash
python src/parser.py
```

Run a single procedure (recommended interview walkthrough):

```bash
python src/parser.py --procedure Stage_User_Data
```

Output:

`output/Stage_User_Data.json`

### 4) Run without LLM (debug / preprocessing only)

```bash
python src/parser.py --procedure Stage_User_Data --skip-llm
```

---

## Design Notes

- LLM handles interpretation; Python handles deterministic checks.
- Output is intentionally simple JSON for easy review and downstream storage.
- Confidence and warnings are meant to support triage, not replace human judgment.
- Current default scope is `bingo_data_hourly_load_CLEAN.sql`; use `--input` to target another file.
