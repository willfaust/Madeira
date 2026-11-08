# Agent skills

Skills for coding agents (Claude Code and others that read `.claude/skills/`) that help with Madeira's
Swift app code: SwiftUI and concurrency review, building and driving the app in the iOS Simulator, and
workflow checks. They are public, MIT-licensed projects by other people. Nothing here is copied: each
skill is a symlink into a git submodule under `third_party/agent-skills/`, pinned to a commit, so
updating one is a submodule bump and its licence and history stay with its author.

| Skill | From | Path in that repo |
| --- | --- | --- |
| `swiftui-pro` | [twostraws/SwiftUI-Agent-Skill](https://github.com/twostraws/SwiftUI-Agent-Skill) (Paul Hudson) | `swiftui-pro` |
| `swift-concurrency-pro` | [twostraws/Swift-Concurrency-Agent-Skill](https://github.com/twostraws/Swift-Concurrency-Agent-Skill) (Paul Hudson) | `swift-concurrency-pro` |
| `swift-concurrency-patterns` | [rshankras/claude-code-apple-skills](https://github.com/rshankras/claude-code-apple-skills) | `skills/swift/concurrency-patterns` |
| `run-simulator` | [rshankras/claude-code-apple-skills](https://github.com/rshankras/claude-code-apple-skills) | `skills/ios/run-simulator` |
| `flow-walkthrough` | [rshankras/claude-code-apple-skills](https://github.com/rshankras/claude-code-apple-skills) | `skills/testing/flow-walkthrough` |
| `ios-simulator-skill` | [conorluddy/ios-simulator-skill](https://github.com/conorluddy/ios-simulator-skill) | `ios-simulator-skill/skills/ios-simulator-skill` |

## Using them

The submodules are marked `update = none`, so a normal `git clone --recurse-submodules` (and the build
scripts) do not fetch them. To get the skills:

```sh
git submodule update --init --checkout third_party/agent-skills/*
```

Until then the symlinks dangle and agents ignore them. To update one to its latest commit, then commit
the new pin:

```sh
git submodule update --init --checkout --remote third_party/agent-skills/<name>
git add third_party/agent-skills/<name> && git commit -s
```

## Notes

- The Simulator skills (`run-simulator`, `flow-walkthrough`, `ios-simulator-skill`) can build and drive
  Madeira's SwiftUI screens, but not run games: the Windows runtime needs JIT on a device.
- `ios-simulator-skill` needs Python 3.12+ and `idb`; its scripts make no network calls.
- These are third-party instructions an agent will follow. Review a submodule bump as you would review
  code before merging it.
- Licences: each repository carries its own MIT licence file inside its submodule.
