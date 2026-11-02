# Repository workflow

- Use `jj` for local version control. The repository is colocated with Git for GitHub interoperability.
- Inspect work with `jj status`, `jj diff`, and `jj log`; use `jj git fetch` and `jj git push` for remote operations.
- Create task bookmarks with the `pangmo5/` prefix. Preserve unrelated changes in separate changes.
- Use `mise run generate`, `mise run format`, and `mise run format:check` for the pinned project tools.
- Run Swift and Xcode commands through `mise exec --` so they use the Xcode selected by `.xcode-version`.
