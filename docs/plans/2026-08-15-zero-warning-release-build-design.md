# Zero-Warning Release Build Design

## Goal

Make Zetty's supported release pipeline free of actionable and avoidable warnings without suppressing diagnostics globally or weakening the build guarantees that protect installed-app routing.

Success means the generated-project, test, and Release-build commands emit no warning that represents deprecated code, unsafe concurrency, incomplete app metadata, duplicate static linkage, irrelevant metadata extraction, or ambiguous destination selection. Intentional informational notes may remain when they document correct behavior, such as the always-run build-stamp phase.

## Approaches considered

### 1. Fix each root cause (selected)

Modernize the deprecated API, use notification delivery that respects the app's main-actor isolation, complete the bundle metadata, and make the bridge target the single owner of its static package dependencies. Adjust the supported build invocation so Xcode receives an unambiguous generic macOS destination and its automatic App Intents metadata pass has the framework dependency it expects.

This keeps diagnostics useful and makes future warnings visible. The dependency cleanup uses a narrow module-facade pattern rather than moving application code between targets.

### 2. Suppress warning classes

Compiler flags and build settings could hide deprecation, concurrency, and package-graph warnings. This is rejected because it also hides future regressions and leaves duplicate code or unsafe assumptions intact.

### 3. Flatten the app and bridge targets

Moving `ZettyGhostty` sources into the app target would naturally deduplicate package links, but it would discard the existing bridge boundary and require restructuring the smoke-test target. This is disproportionate to the warning cleanup.

## Design

### Bounded process-path decoding

`proc_pidpath` already returns the byte count. Decode only those bytes as UTF-8 instead of asking `String(cString:)` to scan for a terminator. This removes the deprecated API and prevents reading past the returned payload.

### Main-thread notification observers

Replace the three closure-based `NotificationCenter` observers in `KeyInterceptor` with selector-based observers targeting one `@objc` main-actor method. AppKit emits these window, application, and menu notifications on the main thread, matching the class's existing isolation. Teardown removes the interceptor from `NotificationCenter` as a whole.

This removes the non-`Sendable` to `@Sendable` conversion without adding unchecked sendability or actor escapes.

### Application metadata

Add `LSApplicationCategoryType` with `public.app-category.developer-tools` to the generated Info.plist. Zetty is a developer terminal tool, so this is the appropriate macOS category.

Declare the system `AppIntents.framework` dependency on the app and bridge targets. Xcode 17F113 schedules metadata extraction for both targets even though Zetty declares no intents; without the dependency, the extractor warns instead of completing its no-op pass. Its own `--disable` and `--quiet-warnings` modes were evaluated but still emit a warning, so the dependency is the only configuration verified to produce a clean build without globally hiding diagnostics.

### Static package ownership

`GhosttyTerminal` and `ZettyCore` are static products currently linked by both `ZettyGhostty` and `zetty`. Make `ZettyGhostty` the app-facing facade for those modules:

- re-export `GhosttyTerminal` and `ZettyCore` from the bridge module;
- update app sources to import `ZettyGhostty` where they currently import either package directly;
- remove the two package products from the app target's dependency list;
- retain the package dependencies in `ZettyGhostty`, where the bridge requires them.

This gives each static product one link owner in the application graph while preserving the bridge framework and its tests. The re-export is internal to Zetty's build graph, so it does not create a public compatibility promise.

### Deterministic Release destination

Use Xcode's generic macOS destination in the packaging command. The project continues to build its configured universal architectures, but Xcode no longer has to choose between matching host architecture destinations.

The build-stamp phase remains always out of date. It must observe the current commit and dirty state on every build so Launch Services ranks the correct app copy; its informational note is intentional and is not treated as a warning.

## Verification

1. Regenerate the Tuist project after changing target dependencies or settings.
2. Run `mise exec -- swift test`.
3. Run `mise exec -- tuist test`.
4. Run a clean universal Release build through the packaging path.
5. Capture the full output and inspect every `warning:` plus Tuist warning block. No actionable or avoidable warning may remain.
6. Confirm the built app still contains both architectures, the expected version/build stamp, and the bridge/package frameworks required at runtime.

The existing intentional build-stamp note is acceptable. Any remaining warning must be fixed or explicitly justified in this document before completion.
