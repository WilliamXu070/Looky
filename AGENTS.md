---
name: agents
description: Coordination rules for updating QuickLook skills when insights are produced or bugs are fixed.
---

# QuickLook project agent workflow

## Rule: update skills on meaningful outputs

Every time one of these happens:

- A new insight/sentiment is generated (for example: recommendation, pattern, gotcha, or process improvement).
- A bug is fixed (confirmed by code/test change or clear corrective edit).

update the relevant skill references under `.codex/skills` in this repo.

## How to identify the relevant skill

Use the intent of the change:

- Build/linker, headers, Xcode, or architecture issues → `quicklook-build-pipeline`
- STEP fixture rendering/parsing behavior/regression → `quicklook-step-fixture-check`
- QuickLook extension cache, Finder registration, plugin visibility → `quicklook-plugin-troubleshoot`
- Release checks, package sanity, pre-tagging validation → `quicklook-release-readiness`

If a change touches both build + runtime/extension behavior, update both relevant skills.

## What to update

When a relevant change is made, add a brief note to the skill’s `SKILL.md` describing:

- What changed
- Why it matters
- The exact command(s) or check(s) to validate
- Any caveats or next step

Keep entries short and practical.

## Required update format

Use this content template for each skill update:

```md
## [Date] Update

### Problem context
- [short description of issue or unique insight]

### What changed
- [specific content change made in SKILL.md]

### Why it helped
- [impact on build, troubleshooting speed, confidence, etc.]

### Validation
- [commands/checklist or reproducible steps]
```

When you are describing an update in plain text, include:
- `content change:` a sentence-level summary of what was added/edited.
- `example usage:` concrete scenario showing what problem was solved and how the skill should now be used.

## Standard response format for this project

For any bug fix or generated insight, include:

1. summary of change  
2. affected skill references updated (or "no update needed" with rationale)
3. quick follow-up check

This keeps the Skills tab aligned with current team knowledge and avoids stale guidance.

### Example of skill usage entry

```md
## 2026-06-05 — Extension cache recovery

### Problem context
- QuickLook preview did not appear after replacing `QuickLookStep.app`, but Finder still showed old extension state.

### What changed
- Updated `quicklook-plugin-troubleshoot` with a step-by-step reset sequence and explicit verification checkpoints.
- Added explicit note to run `pluginkit -e use -i ...` after `pluginkit -r -a` and to restart Finder only if UI remains stale.

### Why it helped
- Reduces extension recovery time from trial-and-error to a deterministic command sequence.
- Clarifies the expected recovery order, preventing stale cache behavior.

### Validation
- run:
  - `pluginkit -r -u com.johnboiles.QuickLookStep.StepThumbnail`
  - `pluginkit -r -u com.johnboiles.QuickLookStep.StepPreview`
  - `pluginkit -r -a /Applications/QuickLookStep.app`
  - `qlmanage -r`
  - `qlmanage -r cache`
  - `pluginkit -e use -i com.johnboiles.QuickLookStep.StepThumbnail`
  - `pluginkit -e use -i com.johnboiles.QuickLookStep.StepPreview`
  - `killall QuickLookUIService && killall Finder`
```
