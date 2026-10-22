# Releases

Dials uses Changesets to keep independent versions and changelogs for `neqMac` and `nitMac`. Every pull request must include a release decision.

For a user-visible change, run:

```sh
npm run changeset
```

Select `@dials/neqmac`, `@dials/nitmac`, or both. Choose `patch` for compatible fixes and performance improvements, `minor` for compatible features, and `major` for incompatible changes. Write the summary in user-facing language.

For internal work that should not appear in either changelog, run:

```sh
npm run changeset -- --empty
```

Both commands create a small Markdown file under `.changeset/`. CI rejects pull requests without a new changeset and validates the changesets that are present.

After changes reach `main`, the Release workflow creates or updates a single release pull request covering both apps, titled with each app's next version, such as `release: neqMac v0.2.0, nitMac v0.1.1`. It collects pending non-empty changesets, applies the highest requested bump independently to each affected app, updates each app's `package.json` and `CHANGELOG.md`, synchronizes `CFBundleShortVersionString` in its `Info.plist`, and deletes the consumed changeset files.

GitHub holds CI on the release pull request because the workflow opened it, and `main` requires those checks to pass. Approve the pending workflow runs on the pull request before merging it.

Merging the release pull request publishes each app whose version has no tag yet. Any push to `main` with no pending release notes does the same, so empty changesets left by internal pull requests never hold a release back. The workflow runs the tests, then builds each app, tags the tested commit as `@dials/<app>@<version>`, and creates a GitHub release named `<App> v<version>` with that version's changelog section and the zipped app attached. Each app is tagged and released on its own, so an app without pending changes is left alone.

The package versions in `Resources/neqMac/package.json` and `Resources/nitMac/package.json` are the sources of truth. Their `Info.plist` files are checked mirrors maintained by `npm run version:sync`; `npm run version:check` rejects drift.

The Release workflow needs the repository setting **Actions → General → Allow GitHub Actions to create and approve pull requests** enabled.
