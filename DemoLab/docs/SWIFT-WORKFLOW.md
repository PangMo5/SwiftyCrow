# Swift recording and review workflow

The maintained workflow uses `swiftycrow-tools` and the offline Swift recorder.
All paths in JSON are absolute or relative to the explicitly selected repository
root. No Python, shell script, or Node runner is required for the steps below.
FFmpeg/ffprobe remain external video codecs and inspection tools.

Build the host tools with `swift build --package-path Tools`. Examples below use
`Tools/.build/debug/swiftycrow-tools`; use the release binary for repeated work.
The guest needs its own build plus the recorder and source app described in
[RECORDING.md](RECORDING.md). Transport is explicit: copy the repository, app,
archive, fixtures, and tools into the owned `swiftycrow-demo` VM. This command
does not discover, launch, stop, or modify another VM.

## Record and resume inside the VM

Copy `DemoLab/Scenarios/recording-plan.example.json` and set real guest paths.
List each desired film/locale and a fresh take directory. Use all five films
for each locale when preparing a complete review. App and source-app bundles,
archives, tools, catalogs, and scenario inputs are fingerprinted. The config
path stays fixed but its content is mutable because the app persists language
and region changes while recording.

```sh
Tools/.build/debug/swiftycrow-tools record-locales --source recording-plan.json --output DerivedData/batch-plan.json --check
Tools/.build/debug/swiftycrow-tools record-locales --source recording-plan.json --output DerivedData/batch-results.json
```

`--check` validates inputs and writes the proposed commands without launching
anything. Recording is sequential. A completed take resumes only when its
request fingerprint and runtime assertions still match. A failed or partial take
is preserved and reported; other locales continue. To retry it, give that take a
new directory in the plan. Failure produces a nonzero exit status after the
batch report is saved. Cancellation propagates to the child process.

The child environment removes OCR/translation injection and host-relay overrides.
All app actions still run through the native `demoqa story` driver. Copy the
chosen raw take directories back to their declared host paths after recording.

## Select, inspect, and approve takes

Write a decisions JSON containing a `takes` array. Each entry has `locale`,
`film`, `directory`, and `posterSeconds`. After visually inspecting a take, add
`review` with the report path. The current accepted decisions are in
`DemoLab/Edits/take-decisions.json`.

```sh
Tools/.build/debug/swiftycrow-tools select-takes --source decisions.json --output selection.json
Tools/.build/debug/swiftycrow-tools prepare-review --source selection.json --output DerivedData/ContactSheets
```

Selection validates the locale-specific pair, real translated AX text, language
picker evidence, runtime assertions, capture epoch, narration, and missed-slot
budget. It pins the original, recorder stats, scene, timeline, ready record,
translation evidence, and any human review by hash. It never chooses the newest
file automatically or equates passing machine checks with visual approval.

`prepare-review` decodes frames and creates contact sheets. Read those sheets and
the full video; add the review path to the decisions and rerun `select-takes`.
Export requires that review hash and a valid poster time. Changing any selected
input requires a new explicit selection.

## Export, combine, and install

```sh
Tools/.build/debug/swiftycrow-tools export-batch --source selection.json --media-root DerivedData/Exports
Tools/.build/debug/swiftycrow-tools merge-review-bundle --source selection.json --media-root DerivedData/Exports --output review-bundle.json
Tools/.build/debug/swiftycrow-tools verify-media --source review-bundle.json
Tools/.build/debug/swiftycrow-tools install-assets --source review-bundle.json --output DerivedData/InstalledReview
Tools/.build/debug/swiftycrow-tools site --media-root DerivedData/InstalledReview/media --output DerivedData/Site
```

Exports preserve full frames, frame counts, duration, and processing waits using
the existing Swift exporter. Re-running a batch retains completed exports only
when their selection and file hashes match. A partial export is preserved and
requires a new media directory; it is never silently overwritten. A complete bundle contains exactly one take per
film and locale. Partial selections can be exported, but combining into a final
bundle requires all 25. To retain already approved films while replacing a subset, pass
`--base-review <previous-review-bundle.json>` to `merge-review-bundle` and select
only the new takes. The existing bundle is verified first; only explicitly
selected film/locale pairs are replaced, and all other records keep their
original paths and hashes. No manual copying into a combined directory is needed.
Independent app/resource cohorts retain their own hashes; a merge never claims
that all takes came from a single new app archive.

Installation verifies all inputs before copying and checks destination hashes.
It stages `media/` and `manifest.json` together, then renames the new directory
into place. It refuses an existing destination, so approved assets are never
silently overwritten. Site publication remains a separate operation.

## Verify the current approved review

```sh
Tools/.build/debug/swiftycrow-tools select-takes --source DemoLab/Edits/take-decisions.json --output DemoLab/Edits/selected-takes.json
Tools/.build/debug/swiftycrow-tools merge-review-bundle --source DemoLab/Edits/selected-takes.json --media-root DemoLab/Edits/media --output DemoLab/Edits/review-bundle.json
Tools/.build/debug/swiftycrow-tools verify-media --source DemoLab/Edits/review-bundle.json
```

The first three steps need local camera originals. CI instead runs
`verify-media --source DemoLab/Edits/review-bundle.json --portable`: it checks
committed media, metadata, review hashes, the complete language matrix, narration,
and preserved runtime evidence. It explicitly does not claim to inspect absent
camera originals. The automation workflow also runs Swift tests, catalog checks,
document checks, and a site build with the approved review media.

The previous ignored Python/shell batch, selection, language-evidence, and install
helpers are superseded by these commands. Their historical files can be retained
with QA evidence but are not supported entry points. Independent browser playback
QA may still use browser tools such as Playwright; it is distinct from the Swift
recording/export workflow and is not replaced by hashing files or unit tests.

The former single-archive `media-manifest` command and `--recorded-catalog`
option are replaced by `select-takes` and `merge-review-bundle`. Existing
publication manifests remain historical evidence; do not relabel them as
current review bundles.
