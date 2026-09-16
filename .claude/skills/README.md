# Agent skills

Skills bundled with this repository so that any contributor — or any AI agent
working in it — has the same context without a separate install step.

Claude Code picks these up automatically. Other agents may need
`npx skills` or their own discovery mechanism.

## Authored here

| Skill | Purpose |
|---|---|
| `dartnative-plugin` | How to **build** a DartNative plugin: `dart:ffi` bindings, the dispatcher-slot callback contract, `@_cdecl` Swift bridges, the Android C++/JNI bridge, `NativeElement`, `ViewType.claim`, `PluginMutation`, and the podspec/Gradle constraints. Maintained as part of this project. |

## Shipped to consumers (lives elsewhere)

The skill for people **using** this package is not in this directory. It is at
[`../../skills/google-mobile-ads-kit-usage/SKILL.md`](../../skills/google-mobile-ads-kit-usage/SKILL.md)
— the top-level `skills/` folder is the layout the Dart `skills` CLI discovers,
so an app that depends on this package installs it with `dart run skills@ get`.
Scaffolded with `dart run skills@ create`; keep the directory name and the
frontmatter `name:` identical (the CLI validates the package-name prefix).

Only `skills/` is published. This directory, `.config/`, and `CLAUDE.md` are
excluded by `.pubignore` — they are for contributors, and the vendored skills
below carry third-party licences that should not be redistributed inside the
package.

## Vendored from upstream

Copies, not forks — do not edit these. Refresh with `npx skills add <ref>` and
copy the result back in.

| Skill | Upstream | Covers |
|---|---|---|
| `dart-native` | `dartnative/dartnative@dart-native` | Writing DartNative apps: widget APIs, native lowerings, what is and isn't Flutter-compatible |
| `dart-native-porting` | `dartnative/dartnative@dart-native-porting` | Porting a Flutter app to DartNative |
| `dart-write-documentation` | `dart-lang/skills@dart-write-documentation` | `///` API doc conventions — this is a published package, so doc quality is user-facing |
| `dart-use-doc-examples` | `dart-lang/skills@dart-use-doc-examples` | `{@example}` directives, so sample code in docs stays compiled and correct |
| `dart-run-static-analysis` | `dart-lang/skills@dart-run-static-analysis` | `dart analyze` / `dart fix --apply` |
| `dart-add-unit-test` | `dart-lang/skills@dart-add-unit-test` | Unit tests with `package:test` |
| `dart-resolve-package-conflicts` | `dart-lang/skills@dart-resolve-package-conflicts` | `pub get` version conflicts — DartNative resolves SDK packages through its own closed resolution, which can surprise you |

Upstream skills remain under their own licenses and are the property of their
respective authors. They are included here for convenience; see
<https://skills.sh> for canonical copies and terms.

## Division of labour

`dart-native` documents the framework from a **plugin consumer's** point of view
and does not cover plugin authoring. `dartnative-plugin` fills exactly that gap.
When working on native bridge code, load both.
