# Marketing concepts: 2026-09-12

This folder preserves every logo direction reviewed during the v1.2.0 marketing pass.

## Selected direction

`logo-concept-05-shield-recovery-selected.png` became the project mark. It combines a protected boundary, a portable bundle, and a recovery path in one readable silhouette. The idea stays clear at small sizes and does not borrow Brave's lion mark.

`hero-concept-01-selected.png` became the README hero. It pairs the selected mark with an actual WhatIf capture and one direct promise: update the portable browser while leaving the installed copy alone.

## Other directions

| File | Decision |
| --- | --- |
| `logo-concept-01-container-road.png` | Rejected because the suitcase, road, and status mark created too many competing ideas. |
| `logo-concept-02-scoped-window.png` | Rejected because it looked like a generic application-export icon. |
| `logo-concept-03-flat-window-rejected.png` | Rejected because the generated file contained a rendered checkerboard rather than real transparency. |
| `logo-concept-04-bp-monogram.png` | Strong typography, but the overlapping forms read as an extra letter at small sizes. |
| `logo-concept-06-flat-shield-rejected.png` | Rejected because the generated file contained a rendered checkerboard and lost the selected concept's detail balance. |

## Quality checks

- The selected logo is an RGBA PNG with alpha set to zero outside the mark.
- The README hero is exactly 1280 by 640 pixels.
- The terminal shown in the hero comes from a real PowerShell 5.1 WhatIf run against an isolated fixture.
- The README also includes the uncropped product captures for WhatIf, fresh install, and rollback.

The working prompts are preserved in [PROMPTS.md](PROMPTS.md).
