# Workflow Design

## Overview

This workflow is designed around the Task 2 parsing tool and shows how LLM-based extraction can be surrounded with deterministic validation and trust controls.

The design intentionally separates:

- **LLM-based interpretation**
- **deterministic validation**
- **confidence scoring / review routing**

This separation is important because the LLM is useful for interpreting SQL structure and transformation meaning, but it should not be the only source of truth.

The same workflow can support both:

- ETL-style procedures such as `Stage_User_Data` from `bingo_data_hourly_load_CLEAN.sql`
- more business-rule-heavy procedures such as those found in `value_segments_daily_load_CLEAN.pkb`

The difference is mainly in what fields are emphasized during extraction:
- ETL-focused procedures emphasize source/target lineage and mappings
- segmentation-focused procedures emphasize rules, conditions, and classifications

---

## End-to-End Workflow

1. SQL file ingestion  
2. Procedure extraction  
3. Pre-processing  
4. LLM-based extraction  
5. Deterministic validation  
6. Confidence scoring  
7. Output storage  
8. Optional human review  

---

## Step-by-Step Breakdown

### 1. SQL Ingestion

- Input: SQL/PLSQL file (Oracle package body)
- File is read as raw text
- No database execution is required

This keeps the workflow lightweight and aligned to the task requirement of using the files as source material for parsing and analysis.

---

### 2. Procedure Extraction

- Deterministic parsing using regex
- Extracts individual:
  - `PROCEDURE`
  - `FUNCTION`

Each subprogram is processed independently.

Why this matters:
- reduces prompt size
- lowers cost
- makes validation easier
- makes outputs easier to review

---

### 3. Pre-processing (Deterministic)

This step performs simple cleanup before the LLM step:

- remove comments
- normalize whitespace
- extract:
  - procedure name
  - parameter block
  - cleaned body text

This ensures a more consistent and focused LLM input.

It also creates useful debug-friendly metadata that can be written into the output record.

---

### 4. LLM Extraction

Input to the LLM includes:

- full text of a single procedure/function
- structured schema template
- prompt instructions

The LLM returns structured JSON containing fields such as:

- procedure name
- summary
- input parameters
- source information
- target information
- column mappings
- business rules
- Oracle-specific features
- output characteristics
- warnings / confidence

For ETL-style procedures, the LLM mainly extracts:
- source/target lineage
- transformations
- load patterns

For business-rule-heavy procedures, the LLM can instead emphasize:
- conditional logic
- classifications
- segmentation semantics

---

## 5. Deterministic Validation

The extracted JSON is validated using rule-based checks.  
In the current prototype, these are lightweight but intentionally visible.

### a. Output-Shape Validation
- required top-level fields present
- helps detect malformed or incomplete responses

### b. Exact Matching
- procedure name is present
- procedure name is consistent with the extracted SQL unit

### c. Grounding Checks (Substring-Based)
- values in `source` and `target` should appear in the SQL text
- Oracle-specific features should appear in the SQL text

### d. Heuristic Checks
- empty `business_rules` is flagged as a warning

These checks do not prove full semantic correctness, but they increase trust and make failures visible.

---

## 6. Confidence Scoring

A simple scoring model is applied after validation:

- start with score 10
- subtract:
  - 3 points per validation error
  - 1 point per warning

Final confidence bands:

- **High confidence**
- **Medium confidence**
- **Low confidence**

This provides a lightweight trust signal without requiring extra LLM calls.

---

## 7. Error Handling and Flagging

Validation results determine how the output should be treated.

| Status | Action |
|------|--------|
| Pass | Accept output |
| Warn | Accept with caution |
| Fail | Flag for review |

This makes the orchestration more robust than a simple “LLM output = final answer” flow.

---

## 8. Output Storage

The final output is written as JSON and includes:

- source metadata
- preprocessing metadata
- LLM extraction
- validation results
- confidence score
- human review recommendation

This output shape is intentionally easy to review and could be extended later into:

- Databricks tables
- AWS S3 / Glue metadata
- migration inventories
- lineage repositories

---

## 9. Human Review (Optional Trust Layer)

Human review is triggered when:

- validation fails
- confidence is low

A reviewer could then:

- correct field mappings
- improve business rules
- refine prompt instructions
- feed changes back into the workflow

This is important for migration scenarios where some SQL units may contain ambiguous logic or business semantics that are difficult to infer perfectly from text alone.

---

## Trust Model

The trust model is layered:

1. **LLM extraction**
   - interprets SQL and returns structured metadata

2. **Output-shape checks**
   - ensure the expected top-level structure exists

3. **Deterministic grounding checks**
   - improve confidence that extracted values are traceable to SQL text

4. **Confidence scoring**
   - provides a simple signal for acceptance vs review

This avoids relying solely on the LLM output.

---

## Scalability Considerations

The workflow is designed so that it can scale beyond the single-procedure prototype:

- each procedure is processed independently
- the process can be parallelized externally
- outputs are already machine-readable
- validation metrics can be recorded for monitoring
- the same architecture can support both ingestion-focused and rule-focused procedures

This is useful in migration projects where large numbers of SQL units must be analyzed and tracked consistently.

---

## Future Enhancements

A production-ready version could be extended with:

- more robust parsing (AST/grammar-based instead of regex only)
- full JSON Schema validation
- richer structural checks such as:
  - target table validation
  - target column vs select-expression count checks
  - write-pattern checks (`INSERT`, `MERGE`, `UPDATE`)
- more precise semantic validation
- retry logic only for failed/low-confidence outputs
- integration with downstream migration workflows or metadata repositories

---

## Summary

This workflow demonstrates a practical and lightweight orchestration design for combining LLMs with deterministic validation in a SQL migration-support use case.

It is intentionally designed to balance:

- **flexibility** — using the LLM to interpret SQL structure and semantics
- **trustworthiness** — using deterministic checks and confidence scoring
- **reviewability** — keeping the output lightweight and easy to inspect
- **scalability** — allowing many procedures to be processed consistently over time
