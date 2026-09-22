# dev-ci

Generic public GitHub Actions execution harness.

This repository intentionally contains no project-specific target mapping. Validation requests use opaque target/suite identifiers plus an exact source commit SHA; private repository selection, build logic, and detailed diagnostics are resolved outside this repository.

The public workflow is triggered either by adding one JSON request under `requests/` or manually through `workflow_dispatch`.

Request shape:

```json
{
  "target": "t001",
  "revision": "0123456789abcdef0123456789abcdef01234567",
  "suite": "s001"
}
```

Public workflow output is intentionally limited to generic bootstrap status and PASS/FAIL. Do not add project names, private repository names, private build commands, or detailed test output here.
