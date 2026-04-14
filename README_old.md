# AI-Powered SQL Transformation Parser

## Overview

This project demonstrates a lightweight approach to extracting structured transformation metadata from Oracle PL/SQL using a combination of:

- LLM-based interpretation (semantic understanding)
- deterministic validation (trust and consistency)

The goal is **not full SQL migration**, but structured extraction of transformation logic into machine-readable JSON that can be stored in platforms such as Databricks or AWS.

---

## Contents

```text
project-root/
├── analysis/   -> high-level analysis of SQL files
├── workflow/   -> orchestration and validation design
├── src/        -> parsing tool (`parser.py`)
├── prompts/    -> LLM prompt files
├── schema/     -> output schema template
├── output/     -> generated JSON outputs
├── inputfiles/ -> provided SQL files
└── README.md
```

---

## Task Summary

### Task 1 - Analysis

- Reviewed both SQL files:
  - `inputfiles/bingo_data_hourly_load_CLEAN.sql`
  - `inputfiles/value_segments_daily_load_CLEAN.pkb`
- Identified key transformation patterns (ingestion, staging, segmentation/classification)
- Documented Oracle-specific constructs requiring migration handling
- Designed LLM extraction + deterministic validation approach

### Task 2 - LLM Parsing Tool

Prototype focus procedure:

**`Stage_User_Data`** (from `bingo_data_hourly_load_CLEAN.sql`)

The tool:

- extracts procedure/function text deterministically
- sends one unit at a time to the LLM with schema + prompts
- produces structured JSON output including:
  - source and target
  - column mappings
  - transformations
  - Oracle-specific features
- applies deterministic validation and confidence scoring

### Task 3 - Workflow Design

Designed a lightweight orchestration flow to support:

- deterministic validation of LLM output
- error detection and warning flagging
- confidence scoring
- optional human review routing

---

## How to Run

### 1. Setup environment

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

### 2. Set API key

Choose one option.

**Option 1 - Environment variable**

```bash
export OPENAI_API_KEY=your_key_here
```

PowerShell:

```powershell
$env:OPENAI_API_KEY = "your_key_here"
```

**Option 2 - `.env` file (recommended)**

Copy `.env.example` to `.env` in project root and set:

```env
OPENAI_API_KEY=your_key_here
```

### 3. Run the parser

List available procedures/functions:

```bash
python src/parser.py --list-only
```

Run all procedures in default input (`inputfiles/bingo_data_hourly_load_CLEAN.sql`):

```bash
python src/parser.py
```

Run a single procedure (recommended for interview walkthrough):

```bash
python src/parser.py --procedure Stage_User_Data
```

Output path:

`output/Stage_User_Data.json`

### 4. Run without LLM (debug mode)

```bash
python src/parser.py --procedure Stage_User_Data --skip-llm
```

---

## Key Design Principles

- Separation of concerns:
  - LLM -> extraction
  - Python -> validation and scoring
- Structured schema for consistent output shape
- Deterministic checks for grounding and trust
- Confidence-based handling for review routing

---

## Notes

- This is a lightweight prototype focused on design and approach
- Default parser scope is `bingo_data_hourly_load_CLEAN.sql`; use `--input` to target other files
- Assumptions and analysis details are documented in `analysis/analysis_notes.md`
- Workflow details are documented in `workflow/workflow_design.md`
