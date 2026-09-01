# Planning

Tracks planning-with-files (PWF) artifacts for structured task execution.

## Structure

  planning/
    active/           <- Current work-in-progress PWF files
      task_plan.md
      findings.md
      progress.md
    archive/          <- Completed issues
      YYYY-MM-issue-N-slug/

## Workflow

See `feature-workflow.md` convention in CLAUDE.md for the full sequence:
issue → /planning-init <N> → tests → code-check → atomic commits → /planning-archive.

**Repo-specific:** PWF files are never committed on feature branches (kept
untracked via `.git/info/exclude`) — they are ported to and committed on the
`newgraph` branch so PR diffs stay clean. Issues are tracked upstream at
appelmar/gdalcubes.

## Skills

- `/planning-init` — create this structure (you already ran it)
- `/planning-init <N>` — start issue N (branch + PWF baseline derived from issue body)
- `/planning-update` — sync checkboxes mid-session
- `/planning-archive` — archive completed work, create fresh active/
