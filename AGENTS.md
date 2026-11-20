# Landing changes

By default, publish each completed, tested change to this repository's `main` branch. Honor requests to keep work local or to use a different branch.

- Sync with `origin/main` before starting. Preserve unrelated worktree changes.
- Run the relevant checks, stage the files for the completed change, and commit with a subject that describes what changed. That subject becomes the changelog entry.
- On `main`, the configured post-commit hook pushes the commit to GitHub. If the hook is inactive, push explicitly. When working through a pull request, use a descriptive title and land it when ready.
- Verify that the source commit reached `origin/main` and that `Record landed changes` recorded it in `version.json` and `CHANGELOG.md`. If another commit landed first, integrate it and retry the push. Fast-forward the local checkout after GitHub records the version.
