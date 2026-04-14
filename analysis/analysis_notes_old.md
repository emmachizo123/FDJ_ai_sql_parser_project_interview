# Analysis Notes

## 1. High-Level Overview

The two provided files represent Oracle PL/SQL-based transformation logic from different parts of a broader data pipeline.

- `bingo_data_hourly_load_CLEAN.sql` is primarily focused on **data ingestion and staging**:
  - extracting data from APIs
  - parsing XML payloads
  - loading staging tables
  - transforming and loading downstream target tables

- `value_segments_daily_load_CLEAN.pkb` is focused more on **business logic and analytical transformation**:
  - segmentation and classification
  - rule-based derivations
  - business-oriented transformation logic applied after core ingestion

Together, the two files show a realistic layered transformation architecture:

**External/API Inputs → Staging → Transformation → Business Classification / Analytical Outputs**

For the working prototype in Task 2, I selected one procedure from `bingo_data_hourly_load_CLEAN.sql` as requested.  
For Task 1 analysis, I reviewed **both files** to understand their purpose, inputs/outputs, Oracle-specific patterns, and how an LLM workflow could extract structured transformation metadata from them.

---

## 2. What the Packages / Procedures Do at a High Level

### File 1: `bingo_data_hourly_load_CLEAN.sql`

This file contains procedures that implement an ETL-style ingestion pipeline. At a high level, it:

- calls APIs to retrieve XML payloads
- parses XML into relational rows
- stages data into `STG_*` tables
- performs transformations such as:
  - timestamp parsing
  - timezone conversion
  - normalization
- loads downstream structures such as staging, dimension, or fact-like tables

A representative example is `Stage_User_Data`, which reads user registration data from XML and inserts standardized rows into `SCHEMA_ETL.STG_USERS`.

This file also shows procedural orchestration patterns, where one procedure calls another and drives time-based extraction windows.

---

### File 2: `value_segments_daily_load_CLEAN.pkb`

This package body appears to represent a different layer of the pipeline: a **business-rules and segmentation layer**.

At a high level, this file is oriented more toward:

- classification
- segmentation
- deriving business labels or value bands
- transformation logic based on conditions or thresholds

Compared with `bingo_data_hourly_load_CLEAN.sql`, this file is less about raw ingestion and more about interpreting already-available data into business-relevant outputs.

This distinction is important for migration:

- in the first file, the main challenge is structured extraction of ETL mechanics
- in the second file, the main challenge is preserving embedded business rules and their meaning

---

## 3. Main Inputs and Outputs

### Inputs observed across the two files

Across both files, the main inputs include:

- XML payloads (`XMLTYPE`)
- procedure parameters (e.g. dates, flags, control values)
- configuration values such as API details
- staging or source-system tables
- intermediate transformed data used in downstream logic
- business-rule inputs such as thresholds, conditions, and segmentation criteria

---

### Outputs observed across the two files

Across both files, the main outputs include:

- staging tables (e.g. `SCHEMA_ETL.STG_USERS`)
- transformed downstream tables
- analytical or classified outputs
- logging or audit entries
- row count or process monitoring information

---

## 4. Key Transformation Patterns

Several recurring transformation patterns are visible across the files.

### In `bingo_data_hourly_load_CLEAN.sql`

- API/XML ingestion
- XML → relational conversion using `XMLTABLE`
- insert-select staging patterns
- direct mappings from XML fields to relational columns
- type conversion (`TO_DATE`)
- timezone conversion (`fn_convert_timezone`)
- normalization (`LOWER`)
- orchestration across multiple procedures
- time-window-based looping and scheduling logic

### In `value_segments_daily_load_CLEAN.pkb`

- rule-based classification
- conditional transformation logic
- business segmentation
- derivation of categorized outputs from existing data
- analytical transformation rather than raw ingestion

---

## 5. Oracle-Specific Constructs / Patterns Requiring Migration Handling

The files use several Oracle-specific constructs that would need special handling during migration to platforms such as Databricks, Spark SQL, or AWS-based processing systems.

Examples include:

- `XMLTYPE` and `XMLTABLE`
  - Oracle-specific XML handling
  - would likely need replacement with Spark XML parsing or custom parsing logic

- `DUAL`
  - Oracle system table
  - not directly portable

- `SQL%ROWCOUNT`
  - PL/SQL cursor attribute
  - would need equivalent monitoring or result-count logic

- PL/SQL package/procedure structure
  - packages, procedures, functions, loops, and procedural flow
  - would need to be re-expressed in jobs, notebooks, orchestration pipelines, or Python/Scala code

- `TO_DATE`
  - Oracle date conversion semantics
  - needs migration-aware mapping

- `EXECUTE IMMEDIATE`
  - dynamic SQL
  - requires special handling in migration because it is harder to analyze statically

- `COMMIT`
  - explicit transaction control
  - transaction semantics differ in distributed platforms

- embedded business-rule logic
  - especially in the segmentation-oriented package
  - this is not just syntax migration; it is logic preservation

---

## 6. LLM Workflow to Translate SQL into Structured Transformation Output

### a. Context and Prompting Required

The LLM should be given:

- the full text of a single procedure/function
- a structured output schema
- explicit extraction instructions
- rules for handling uncertainty

The output schema should constrain the response into fields such as:

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

This approach reduces free-form prose and encourages machine-readable output that could later be stored in metadata platforms such as Databricks tables, AWS storage, or migration tracking repositories.

Different procedure types may need slightly different prompting emphasis:

- ETL-style procedures:
  - emphasize source/target lineage, column mappings, and load patterns

- business-rule-heavy procedures:
  - emphasize conditional logic, segmentation rules, thresholds, and semantic interpretation

---

### b. How to Trust / Validate the LLM Output

The LLM output should not be trusted directly.

Instead, I would apply a deterministic validation layer after extraction. In the prototype, this includes:

- output-shape validation:
  - required top-level fields must exist

- exact text checks:
  - procedure name should match the expected unit

- grounding checks:
  - values extracted into `source` and `target` should be traceable to the SQL text
  - claimed Oracle-specific features should appear in the SQL

- heuristic completeness checks:
  - empty `business_rules` is treated as a warning

Validation results are classified as:

- `pass`
- `warn`
- `fail`

This helps distinguish:
- structurally correct but incomplete outputs
- outputs with likely grounding problems
- outputs that are not trustworthy enough without review

For a production version, I would strengthen this further with:
- target-table exact matching
- target column vs select-expression count checks
- write-pattern checks (`INSERT`, `MERGE`, etc.)
- stronger field-level validation rather than only substring checks

---

### c. Accuracy vs Cost Trade-Off

The prototype is intentionally lightweight.

To balance accuracy with cost, I would:

- process one procedure at a time
  - reduces token usage
  - keeps prompts focused

- use a relatively small/efficient model such as `gpt-4o-mini`
  - good enough for structured extraction in a prototype
  - cheaper than using a larger model for every procedure

- avoid repeated LLM retries by default
  - only retry when validation indicates poor output

- rely on deterministic validation for trust
  - cheaper than multiple LLM verification passes

This gives a good cost/quality balance for a migration-assistance use case where hundreds of procedures may eventually need to be processed.

---

## 7. Chosen Procedure for the Prototype

For Task 2, I selected `Stage_User_Data` from `bingo_data_hourly_load_CLEAN.sql`.

I chose it because it is:

- small enough for a lightweight prototype
- representative of real transformation logic
- rich enough to demonstrate:
  - parameter extraction
  - source/target extraction
  - XML parsing
  - column mappings
  - transformation logic
  - Oracle-specific feature detection

This makes it a good fit for showing how an LLM-assisted parser can convert PL/SQL into structured metadata.

---

## 8. Assumptions

The following assumptions were made:

- XML structure matches the paths defined in `XMLTABLE`
- target schemas and table names are assumed to exist as referenced
- the prototype focuses on static analysis of SQL text, not execution
- the goal is structured transformation extraction, not full code migration
- the working tool is intentionally lightweight and designed for reviewability rather than production completeness
