# Contributing to Zetty

Thanks for your interest! Bug reports, feature requests, and pull requests
are all welcome.

## Getting a build running

[`DEVELOPMENT.md`](DEVELOPMENT.md) covers building, testing and releasing. The
short version, with [mise](https://mise.jdx.dev) for Tuist:

```sh
mise install
mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build
```

Read [`AGENTS.md`](AGENTS.md) before diving in — it's the full contributor
guide (repo layout, subsystem internals, build gotchas), and
[`DESIGN.md`](DESIGN.md) is the visual spec. The design rules in
[`CLAUDE.md`](CLAUDE.md) are enforced in review — in particular: no
hardcoded colors (use `ZTheme` tokens), and keep `ZettyCore` pure
(no AppKit imports).

## Pull requests

- Keep PRs focused — one fix or feature per PR.
- Pure logic belongs in `ZettyCore` with unit tests; AppKit wiring stays in
  the app layer.
- Run the test suite before submitting; add tests for new `ZettyCore` code.
- Match the existing commit style: a short lowercase subject saying what the
  change does, with no `feat:`/`fix:` prefix, and a body in plain prose
  explaining *why* — see `git log`.
- For anything substantial, consider opening an issue first to discuss the
  approach.

## Bug reports

Include macOS version, Zetty version (About Zetty, or `Build:` commit from
the release notes), steps to reproduce, and what you expected vs. what
happened. `zetty status --json` output often helps for CLI/session issues, and
[`DEVELOPMENT.md`](DEVELOPMENT.md#diagnostic-logs) shows how to collect logs.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
