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

After changes reach `main`, the Release PR workflow creates or updates a `release: version apps` pull request. It collects pending non-empty changesets, applies the highest requested bump independently to each affected app, updates each app's `package.json` and `CHANGELOG.md`, synchronizes `CFBundleShortVersionString` in its `Info.plist`, and deletes the consumed changeset files.

Merging the Release PR records the app versions in the repository. It does not create Git tags, package the apps, publish GitHub releases, or force both apps to release together.

The package versions in `Resources/neqMac/package.json` and `Resources/nitMac/package.json` are the sources of truth. Their `Info.plist` files are checked mirrors maintained by `npm run version:sync`; `npm run version:check` rejects drift.

The Release PR workflow needs the repository setting **Actions → General → Allow GitHub Actions to create and approve pull requests** enabled.
