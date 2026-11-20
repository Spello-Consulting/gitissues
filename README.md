# GitIssues

This is a native macOS SwiftUI application that you can use to create and edit GitHub issues across multiple repositories.

It's fairly new, but it's already better that some of the alternatives I've tried and rejected (Taska; Gitscout; GitKraken; etc.).

This app only intended for issue management, it won't help you with other aspects of Git / GitHub.

## Installing

Clone this repo and build the app on your Mac. I've tested on an Intel Mac (running Sequoia 15.7) and an Apple Silicon mac (running Tahoe 26.1). Just build the app and copy GitIssues.app to your Applications folder - you can use the GitUssues/build_for_relase.sh script to do this.

## GitHub Authentication

The first time you run the app you'll see a Connect to GitHub screen. Click the buttons and follow the process to authenticate the app to GitHub using your existing GitHub account. 

By default, GitIssues only requests access to public repos (that you own or are collaborating on). If you also want to edit issues in your private repos, go the GitIssues > Settings... and turn on _Allow private repository access_. Your will be taken through the GitHub authorisation process again.

## Sorting

The **Sort** menu in the filter bar offers six orders: Updated, Created or Issue # (each newest/high first or oldest/low first). What it does depends on the view:

- **List view.** Issues are sorted by the selected option. Pinned issues stay at the top.
- **Kanban view.** The same six options apply to every column, and pinned state is ignored. The menu also has a **Kanban Dragged** switch (on by default):
  - **On:** cards you have dragged keep the position you gave them, ahead of cards you have never dragged. Cards that share a position, and cards you have never dragged, follow the selected sort option.
  - **Off:** your dragged positions are ignored and the selected sort option decides the whole order. You can still drag a card to another column to change its status, but not to reorder cards within a column. Switching back on restores your dragged order.

Dragged positions are stored as a hidden comment at the end of the issue description (`<!-- gitissues:order=... -->`), so they are invisible on GitHub. Dropping a card between cards that have no stored position (or share one) may also update the stored position of a few neighbouring cards, so that the card lands exactly where you dropped it.

## Performance and the local cache

GitIssues keeps a copy of your issue list on your Mac (a single JSON file in the app's sandbox, under `Application Support/IssueCache/`), so:

- **Launch is fast.** The cached list appears immediately. If the cache is under 10 minutes old, the app then makes one small request for anything that changed; otherwise it reloads everything in the background while you work.
- **Background sync is incremental.** Each sync (every 30 seconds by default, see _Background Sync_ in Settings) fetches only issues updated since the last one, and merges them in. Every 10 minutes it does a full reload, which is how issues deleted or transferred on github.com disappear from the list.
- **Refresh is incremental too.** The toolbar button and ⌘R make the same one small request. To re-download everything (for example to pick up an issue you deleted on github.com right now), use View > **Reload All Issues** (⇧⌘R).
- **Issues you delete elsewhere clean themselves up.** If you open an issue, or drag its Kanban card, and it no longer exists on GitHub, it is removed from the list straight away.

The cache is deleted when you sign out or change the private-repository permission. If the list ever looks out of date, go to GitIssues > Settings... > General > _Local Cache_ and click **Clear Cache & Reload**.

To see where time goes, set the log level to _Information_ in Settings > Logging and search the log for `[PERF]`.

## Running the tests

The unit tests live in the `GitIssuesTests` target. Run them from Xcode (Product > Test, or ⌘U), or from the command line:

```bash
xcodebuild test -project GitIssues/GitIssues.xcodeproj -scheme GitIssues -destination 'platform=macOS'
```

## Known Limitations

- With a very large number of issues (hundreds), the very first load after installing, or after clearing the cache, can take 8-10 seconds to complete; open issues appear within a couple of seconds. Later launches use the local cache.
- You cannot attach files or images to an issue at this time. This is a known limitation of the GitHub API. Once GitHub supports this, we'll add this functionality to the app.
- See https://github.com/NickElseySpelloC/gitissues/issues for other planned enhancements and bug fixes.