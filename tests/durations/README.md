# CI test durations

The test shards of the Release, Debug and Test durations workflows download the repository's one
`test-durations` artifact here (`.github/actions/test-durations`): one `<lane>.tsv` per CI lane
(`macos`, `linux`, `windows`, `wasm`), in the format of `tests/durations.tsv`, one `<seconds>\t<name>`
line per test. A shard passes its lane's file to `super-c test --test-durations=...`, which assigns each
test, the longest first, to the shard with the least time so far. A lane without a file (no artifact
yet, or it expired) uses `tests/durations.tsv`, which is measured on a developer machine.

Every Release run refreshes them: each test shard records the times of the tests it ran, and the
`durations` job merges them per lane, replaces the artifact, and deletes every other durations
artifact (`.github/actions/test-durations-save`; a lane no shard measured keeps its file). The
`Test durations` workflow (`.github/workflows/test-durations.yml`) does the same on demand, without a
release. The files are not committed.
