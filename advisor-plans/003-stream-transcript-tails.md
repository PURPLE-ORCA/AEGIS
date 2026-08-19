# 003 — Stream transcript tails

Status: IMPLEMENTED (`4857b7a`)
Priority: P0 completion latency and peak memory
Baseline commit: `c9450ce`

## Why this matters

The bridge fallback readers use `String(contentsOfFile:)` and `components(separatedBy:)` to find one recent JSONL record. The current largest Codex transcript is 163,623,814 bytes. A plan-mode Stop can therefore read, decode, split, and retain several full-file representations before emitting the completion event.

Current pattern in `Sources/AegisBridge/main.swift:332-350`:

```swift
guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
for line in data.components(separatedBy: "\n").reversed() {
    // parse until the desired record appears
}
```

The same pattern appears in the AntiGravity readers at `:358-388`.

## Required outcome

Read JSONL backward in bounded chunks, parse complete lines newest-first, and stop at the first matching record. Peak memory must be bounded by chunk/record size rather than total transcript size. Message extraction and wrapper stripping must remain byte-for-byte compatible for valid UTF-8 JSONL.

## Scope

In scope:

- `Sources/AegisBridge/main.swift`
- A focused reusable tail-reader file under `Sources/AegisBridge/`
- `Package.swift` only if a small bridge-support target is required for tests
- New bridge tail-reader tests

Out of scope:

- Socket framing, canonical event names, provider normalization, terminal metadata, or agent PID capture
- App-side desktop watchers
- Changing the existing 4,000/500-character output caps
- Reading or committing real user transcripts as fixtures
- The four dirty finished-card files

## Implementation steps

1. Before editing, create a temporary 128MiB JSONL fixture under `/tmp`, run the current bridge fallback against it, and capture `/usr/bin/time -l` elapsed time and peak resident size. Do not copy a real transcript.
2. Extract a bridge-local `ReverseJSONLReader` that:
   - opens one `FileHandle`;
   - seeks to end;
   - reads fixed 64KiB chunks backward;
   - carries an incomplete leading fragment into the next chunk;
   - yields complete non-empty lines newest-first;
   - handles a file with or without a final newline;
   - never splits a line incorrectly at a chunk boundary.
3. Decode each complete line as UTF-8 only when it is considered. JSONL emitted by these providers is UTF-8; malformed records should be skipped without aborting older search.
4. Reimplement `codexAssistantFromTranscript`, `agUserRequestFromTranscript`, and `agAssistantFromTranscript` on the shared reader. Preserve all existing role/type/source checks, XML wrapper stripping, whitespace trimming, and output caps.
5. Keep scanning until a match or start-of-file. Memory must remain bounded even when the desired record is far from EOF. Do not impose an undocumented byte cap that changes correctness.
6. Keep `codexTranscriptPath` behavior unchanged in this plan; recursive path lookup is lower cost than full transcript loading and can be optimized independently later.
7. If executable-target code cannot be imported by tests, add the smallest possible `AegisBridgeSupport` library target containing only the reader and parsers. Do not move the whole bridge or introduce a new protocol layer.

Run the focused tests after extraction and again after all three migrations, followed by the shared verification protocol.

## Tests

Create generated temporary fixtures, never tracked large files. Cover:

- match in the final line;
- match before several irrelevant lines;
- no final newline;
- a JSON record spanning multiple 64KiB chunks;
- a multibyte UTF-8 scalar at a chunk boundary;
- malformed newest JSON followed by an older valid match;
- no match;
- Codex proposed-plan wrapper removal and 4,000-character cap;
- AntiGravity request metadata stripping and 500-character caps;
- a synthetic 128MiB file whose match is near EOF.

Where practical, expose a test-only byte-count result and assert the near-EOF case reads less than 256KiB.

## Before/after metrics

Use the same generated 128MiB fixture and `/usr/bin/time -l` before and after. Report:

- wall-clock latency;
- peak resident size;
- bytes read if instrumented;
- returned message hash/equality, without printing private content.

Success targets for a near-EOF match:

- under 100ms on the audit machine;
- less than 8MiB incremental peak RSS;
- less than 256KiB read;
- identical extracted output.

Also run the 30-sample app metric to prove no descriptor leak; `codex_session_descriptors` must remain zero after completion.

## Done criteria

- All three full-file readers are removed.
- Tests cover chunk, newline, malformed record, Unicode, and provider semantics.
- The 128MiB benchmark meets targets or the handoff explains a measured platform limit.
- Full tests, release build, bundle build, codesign, and diff checks pass.
- No real transcript content appears in tests, logs, or the commit.

## Escape hatches

- If a single JSONL record itself can exceed the chosen chunk size, grow only the carry buffer for that record; do not fall back to loading the whole file.
- If malformed UTF-8 makes reverse boundary recovery ambiguous, skip that complete record and continue; do not silently reinterpret bytes using a lossy encoding.
- If SwiftPM cannot test executable support without a library target, create the narrow support target described above instead of leaving the reader untested.

## Maintenance note

Any future transcript fallback must reuse the bounded reader. A new `String(contentsOfFile:)` JSONL search should fail review unless the file is explicitly size-bounded.
