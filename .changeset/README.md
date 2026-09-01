# Changesets

Every pull request must include a release decision:

```sh
npm run changeset
```

Select `@dials/neqmac`, `@dials/nitmac`, or both, then describe a visible change in user-facing language. For internal work that should not appear in either changelog, run `npm run changeset -- --empty`.

See [the release guide](../docs/releases.md) for the complete workflow.
