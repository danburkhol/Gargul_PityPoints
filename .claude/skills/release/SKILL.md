---
name: release
description: >
  Cut a new release of Gargul Pity Points: bump the addon version, lint, commit,
  tag and push so the GitHub Actions packager uploads the build to CurseForge.
  Use when the user wants to mark, cut, ship or publish a new version, bump the
  version and tag a release, or "release vX.Y.Z".
---

# Cutting a release

Releasing is driven entirely by a pushed git tag: `.github/workflows/release.yml`
runs the [BigWigs packager](https://github.com/BigWigsMods/packager) on any
`v*` tag, which zips the addon and uploads it to CurseForge using the
`CF_API_KEY` and `X_CURSE_PROJECT_ID` repo secrets. This skill's job is to get a
clean, version-bumped, linted commit tagged correctly and pushed.

## Version model (read before touching anything)

- The addon version lives in **one place only**: `## Version:` in
  [`Gargul_PityPoints.toc`](../../../Gargul_PityPoints.toc).
- This repo folder **is** the live in-game addon, so keep `## Version:` a literal
  (e.g. `0.4.0`), never the packager's `@project-version@` token, which would
  show up as garbage in game.
- Use [semver](https://semver.org): `MAJOR.MINOR.PATCH`. The git tag is the
  version prefixed with `v` (TOC `0.4.0` → tag `v0.4.0`). They must match.
- Don't change the SavedVariables schema (`DB.schema` and `migrate()` in
  `Core.lua`) as part of a release; that belongs in its own change.

## Steps

### 1. Resolve the new version

- Read the current `## Version:` from the TOC.
- Determine the target version from the user's request:
  - An explicit version (`release 0.4.0`) → use it verbatim.
  - A bump keyword (`patch` / `minor` / `major`) → increment accordingly.
  - Nothing specified → propose a `patch` bump of the current version and ask
    the user to confirm or override before continuing.
- Reject a target that is not strictly greater than the current version, and
  check the tag doesn't already exist (`git tag --list "v<new>"`).

### 2. Pre-flight checks

- `git status --porcelain`: the tree should contain only changes the user
  intends to ship. If there are unexpected modified files, stop and show them;
  don't bundle stray edits into a release.
- Confirm the branch is `main` and current with the remote
  (`git fetch` then compare), unless the user says otherwise.
- Confirm `## Interface:` in the TOC is right. It drives the game versions the
  packager sets on CurseForge, and it lists every Classic flavor Gargul
  supports, but the add-on has only been tested on TBC Anniversary (20506). If
  unsure, ask the user. Never guess it.
- Ask the user to confirm the release was tested in game. There is no Lua
  interpreter here, so lint is the only automated check.

### 3. Bump the version

Edit `## Version:` in the TOC to the new version. Nothing else needs editing for
a version-only release.

### 4. Lint: must be clean

Run luacheck over the addon's own Lua (the `.luacheckrc` excludes `Libs/`):

```
"C:/Users/agent/tools/luacheck/luacheck.exe" .
```

It must report **0 warnings**. Fix anything it flags, or, if the warning is a
genuinely new WoW global we read, add it to `read_globals` in `.luacheckrc`.

### 5. Commit and push main

```
git add Gargul_PityPoints.toc
git commit -m "Release v<new>"
git push origin main
```

### 6. Tag and push the tag

```
git tag -a v<new> -m "v<new>"
git push origin v<new>
```

The tag push is what triggers the release workflow. Do not create the tag before
`main` is pushed, so the tag points at a commit that exists on the remote.

### 7. Report and verify

Tell the user the release is building and give them the links to watch:

- Actions run: the repo's **Actions** tab (the "Release" workflow).
- Result: the CurseForge project's **Files** page once the upload finishes.

Do not claim the upload succeeded until the workflow run is green. If the user
wants confirmation, check the run's conclusion (e.g. via `gh run list` /
`gh run view`) rather than assuming. If it fails, a 401 from CurseForge almost
always means `CF_API_KEY` isn't a valid upload API token.

## Notes

- The packager generates the CurseForge changelog from git commits since the
  previous tag, so write meaningful commit messages; there's no manual
  CHANGELOG file to maintain.
- `.pkgmeta` lists Gargul (`gargul`) as a required dependency on CurseForge.
- Follow the repo's commit attribution convention for any commits you create.
