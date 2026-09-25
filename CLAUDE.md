@AGENTS.md

## Keep the specification up to date

After every user request, update the [specs/](specs/) folder in the same
change:

- Add a dated entry to [specs/requests.md](specs/requests.md) that says what
  was asked and what changed.
- Revise [specs/README.md](specs/README.md) so it describes the software as it
  is now. Rewrite or delete statements the request made obsolete; don't just
  append.

## One pull request per change

Put every change on its own branch and open a separate pull request for it:

- Never commit or push directly to `main`.
- Don't bundle unrelated requests into one PR.
- If a change depends on work that hasn't merged yet, stack its branch on
  that PR's branch and target that branch.
- Include the matching `specs/` update in the same PR as the change.
