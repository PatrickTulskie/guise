## 0.2.1

### Added

* Re-running the wizard for an existing identity starts from its current values (#17)

### Fixed

* An identity's secret file is shredded once it moves into 1Password (#17)
* A re-run creates the identity's directory where its basedir points, instead of duplicating a moved workspace (#17)

## 0.2.0

### Breaking Changes

* **`setup` defaults to a separate GitHub account** - pass `--owner`/`--app-id`/`--pem` or `--kind app` for an app bot (#11)
* **New identities store their secret in a file** - pass `--store op` for 1Password (#11)

### Added

* Friendlier setup wizard: arrow-key menus, a signing-key walkthrough, and one last look before anything is written (#12)
* Re-running `setup` for an app identity by name, or bare for the default, reuses its saved owner and App ID (#11)
* A container to run `setup` against without touching your machine (#10)

### Changed

* Docs and `doctor` recommend a classic PAT with the `repo` scope (#11)
* CI runs on PRs against any base branch (#14)

## 0.1.0

Initial release.

* Guided setup wizard (#6)
* `guise basedir` moves the workspace after setup, and varies per identity (#5)
* `guise version`, `--version` and `-v` (#7)
* MIT license (#8)
* Renamed from `agent-id` to `guise` (#1)
