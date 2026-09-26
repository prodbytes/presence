@AGENTS.md

## Keep the specification up to date

After every user request, update the [specs/](specs/) folder in the same
change:

- Add a dated entry to [specs/requests.md](specs/requests.md) that says what
  was asked and what changed.
- Revise the feature specs the request touches, one file per feature (the
  index is [specs/README.md](specs/README.md)), so they describe the
  software as it is now. Add a feature file, and list it in the index, when a
  request adds a feature. Rewrite or delete statements the request made
  obsolete; don't just append.

## One pull request per change

Every new feature or bug fix starts on a **new branch from `main`**, with its
own pull request:

- Never commit or push directly to `main`.
- Don't bundle unrelated requests into one PR.
- Start from an up-to-date `main` (`git checkout main && git pull`). Stack on
  an unmerged branch only when the new work truly depends on it, and then
  target that branch.
- Merge only when the user says so.
- Include the matching `specs/` update in the same PR as the change.
