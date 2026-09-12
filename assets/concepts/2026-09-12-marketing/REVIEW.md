# Product and marketing review

Date: 2026-09-12

## Reviewed flow

| Step | Evidence | Health |
| --- | --- | --- |
| Repository discovery | Public metadata, current README, tracked files, release state, and recent history were inspected. | Complete |
| WhatIf preview | PowerShell 5.1 resolved the current Nightly asset and reported the update without changing fixture files. | Passed |
| Stable download and install | The official stable ZIP was downloaded, its SHA256 digest and Brave publisher were verified, the fixture profile was backed up, and the new bundle was installed. | Passed |
| Rollback | The retained Brave executable publisher was verified before the previous bundle was restored. | Passed |
| System boundary | The installed Brave executable hash, machine-wide policy state, live browser processes, and portable wrapper process were checked before and after fixture runs. | Passed |
| README conversion path | The selected hero, direct release links, real screenshots, quick start, safety details, and independent-project notice are present. | Passed |
| Brand selection | Six mark directions were reviewed. The shield-and-recovery emblem was selected after small-size, transparency, relevance, and trademark checks. | Passed |

## Findings resolved

- The previous README did not contain a hero or product screenshots.
- The release link claimed a ZIP was available even though no GitHub release existed.
- The documentation said `app.old` was deleted while also advertising rollback.
- The documentation overstated that the system installation was provably untouched.
- The default machine-wide registry change was broader than the product promise.
- Digest and publisher checks could continue after verification uncertainty.
- ETag state could skip a needed retry after an incomplete update.

## Verification boundary

The reviewed fixtures cover the updater's primary command-line flow on this Windows machine. They do not prove behavior on every hardware configuration, network, or Portapps release.
