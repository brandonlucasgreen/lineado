## What changed

## Verification

Say plainly what you ran and what you did not. An unverified claim costs more
than a slow one.

- [ ] `xcodebuild … test` passes
- [ ] `scripts/check-shell.sh` passes
- [ ] Ran against a real install (`scripts/install-local.sh`), not just tests
- [ ] `scripts/verify-bundle.sh` passes on that build

### Against a live Linear key

Nothing in this repo has run against a live API key by default. If this PR
touches the query, the mapper or a write path, say which of these you did:

- [ ] Watched a poll land and checked the count against Linear's own view
- [ ] Exercised the write(s) this PR touches
- [ ] Cleared a due date (the one case the `JSONValue` type exists for)

### Not verified

