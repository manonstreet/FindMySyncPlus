# gh-pages

This branch exists to serve one file: `appcast.xml`, the Sparkle update feed for
FindMySync+, at

    https://manonstreet.github.io/FindMySyncPlus/appcast.xml

**It is deliberately an orphan branch, unrelated to any release branch.** The feed URL is
compiled into every copy of the app that ships, so it has to outlive branch names. Release
branches come and go — `v1.6-beta` was renamed to `v2.0-beta` before either shipped — and a
feed URL that named one of them would die with it. GitHub Pages keeps the branch in a
setting rather than in the URL, so the source can be re-pointed without breaking installed
copies.

`appcast.xml` is written by Sparkle's `generate_appcast` at release time and signed with the
EdDSA key held in the maintainer's login keychain. Its `enclosure` points at the DMG
attached to the GitHub release, so there is one artifact, downloaded by people and by
Sparkle alike.

**Publish the appcast only after the release asset is live**, or the feed points at a 404.

An empty channel is valid and means no update is available.
