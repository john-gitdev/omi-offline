# Coding Guidelines

## Behavior

- Never ask for permission to access folders, run commands, search the web, or use tools. Just do it.
- Never ask for confirmation. Just act. Make decisions autonomously and proceed without checking in.

## Setup

### Install Pre-commit Hook
Run once to enable auto-formatting on commit:
```bash
ln -s -f ../../scripts/pre-commit .git/hooks/pre-commit
```

### Mobile App Setup
```bash
cd app && bash setup.sh ios    # or: bash setup.sh android
```

## App (Flutter)

### Localization Required

- All user-facing strings must use l10n. Use `context.l10n.keyName` instead of hardcoded strings. Add new keys to ARB files using `jq` (never read full ARB files - they're large and will burn tokens). See skill `add-a-new-localization-key-l10n-arb` for details.
- **Translate all locales**: When adding new l10n keys, provide real translations for all 33 non-English locales — do not leave English text in non-English ARB files. Use the `omi-add-missing-language-keys-l10n` skill to generate proper translations. Ensure `{parameter}` placeholders match the English ARB exactly.
- After modifying ARB files in `app/lib/l10n/`, regenerate the localization files:
```bash
cd app && flutter gen-l10n
```

### Verifying UI Changes (agent-flutter)

After editing Flutter UI code, **verify the change programmatically** — do not just hot restart and hope.

Marionette is already integrated in debug builds (`marionette_flutter: ^0.3.0`). Install agent-flutter once: `npm install -g agent-flutter-cli`.

**Edit → Verify → Evidence loop:**
```bash
# 1. Edit Dart code, then hot restart
kill -SIGUSR2 $(pgrep -f "flutter run" | head -1)

# 2. Connect (must reconnect after every hot restart)
AGENT_FLUTTER_LOG=/tmp/flutter-run.log agent-flutter connect

# 3. See what's on screen
agent-flutter snapshot -i              # list interactive widgets
agent-flutter snapshot -i --json       # structured data for parsing

# 4. Interact
agent-flutter press @e3                # tap by ref
agent-flutter press 540 1200           # tap by coordinates (ADB fallback)
agent-flutter dismiss                  # dismiss system dialogs (location, permissions)
agent-flutter find type button press   # find and tap (more stable than @ref)
agent-flutter fill @e5 "hello"         # type into textfield
agent-flutter scroll down              # scroll current view

# 5. Screenshot evidence for PRs
agent-flutter screenshot /tmp/after-change.png
```

**Key rules:**
- Refs go stale frequently (Flutter rebuilds aggressively) — always re-snapshot before every interaction. Use `press x y` as fallback.
- `AGENT_FLUTTER_LOG` must point to the flutter run stdout log file (not logcat). This is how agent-flutter finds the correct VM Service URI.
- `find type X` or `find text "label"` is more stable than hardcoded `@ref` numbers.
- When adding new interactive widgets, use `Key('descriptive_name')` so agents can use `find key` (survives i18n and theme changes).
- Android: auto-detects via ADB. iOS: requires `AGENT_FLUTTER_LOG` or explicit URI.
- **App flows & exploration skill**: See `app/e2e/SKILL.md` for navigation architecture, screen map, widget patterns, and known flows. Read this when developing features or exploring the app.

### Firebase Prod Config
Never run `flutterfire configure` — it overwrites prod credentials. Prod config files in `app/ios/Config/Prod/`, `app/lib/firebase_options_prod.dart`, `app/android/app/src/prod/`.

## Formatting

Always format code after making changes. The pre-commit hook handles this automatically, but you can also run manually:

### Dart (app/)
```bash
dart format --line-length 120 <files>
```
Note: Files ending in `.gen.dart` or `.g.dart` are auto-generated and should not be formatted manually.

### C/C++ (firmware: omi/)
```bash
clang-format -i <files>
```

## Git

### Rules
- Always commit to the current branch — never switch branches.
- Never squash merge PRs — use regular merge.
- Make individual commits per file, not bulk commits.
- The pre-commit hook auto-formats staged code — no need to format manually before committing.
- If push fails because the remote is ahead, pull with rebase first: `git pull --rebase && git push`.
- Never push or create PRs unless explicitly asked — commit locally by default.

### RELEASE command
When the user says "RELEASE", create a branch from `main`, make individual commits per changed file, push/create a PR, merge without squash, then switch back to `main` and pull.

## Testing
Run `app/test.sh` before committing app changes.
