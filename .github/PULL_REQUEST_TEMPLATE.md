Thanks for contributing to Zetty!

## What & why

<!-- What does this PR change, and what problem does it solve? -->

## Checklist

- [ ] Read [`CONTRIBUTING.md`](../CONTRIBUTING.md) and [`AGENTS.md`](../AGENTS.md)
- [ ] `swift test` passes (and `mise exec -- tuist test` for app-layer changes)
- [ ] New `ZettyCore` logic has unit tests; no AppKit imports in `ZettyCore`
- [ ] No hardcoded colors — UI reads `ZTheme` tokens (see `CLAUDE.md` design rules)
- [ ] For UI changes: a screenshot or short clip
