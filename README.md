# GitIssues

This is a native macOS SwiftUI application that you can use to create and edit GitHub issues across multiple repositories.

It's fairly new, but it's already better that some of the alternatives I've tried and rejected (Taska; Gitscout; GitKraken; etc.).

This app only intended for issue management, it won't help you with other aspects of Git / GitHub.

## Installing

Clone this repo and build the app on your Mac. I've tested on an Intel Mac (running Sequoia 15.7) and an Apple Silicon mac (running Tahoe 26.1). Just build the app and copy GitIssues.app to your Applications folder - you can use the GitUssues/build_for_relase.sh script to do this.

## GitHub Authentication

The first time you run the app you'll see a Connect to GitHub screen. Click the buttons and follow the process to authenticate the app to GitHub using your existing GitHub account. 

By default, GitIssues only requests access to public repos (that you own or are collaborating on). If you also want to edit issues in your private repos, go the GitIssues > Settings... and turn on _Allow private repository access_. Your will be taken through the GitHub authorisation process again.

## Labels

Right-click an issue and choose **Labels…** to add or remove labels. The same item appears when several issues are selected (**Labels for N Issues…**, also available as a button in the multi-selection panel), including issues from different repositories.

- Each label has a three-state checkbox: ticked (every selected issue has it), dashed (some do) or empty (none do). Click to change it: empty → add to all; ticked → remove from all; dashed → add to all, then remove from all, then back to leave as is.
- **Save only changes the labels you clicked.** Labels you didn't touch stay as they are on every issue, so issues with different labels keep their differences.
- Labels are matched across repositories **by name** (ignoring case). A label that only some of the selected repositories have is marked "in 2 of 3 repositories". Adding it to an issue in a repository that doesn't have it **creates the label there** (using the colour shown); the dialog tells you which repositories before you save.
- The **+** button creates a new label in every selected repository that doesn't already have that name.
- With several issues, the updates run in the background and appear in the progress bar at the bottom. Kanban labels (`kanban-…`) are never shown or changed here.

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

## Releasing to the Mac App Store

Maintainer notes for publishing a new build. Manage the app at [App Store Connect](https://appstoreconnect.apple.com/apps); the live listing is at [apps.apple.com](https://apps.apple.com/au/app/gitissues/id6759181744?mt=12).

**Prerequisites (already done):** a paid Apple Developer Program membership (not just a free Apple ID); the app registered in App Store Connect (macOS, name `GitIssues`, bundle ID `com.spelloconsulting.gitissues`, SKU `1000`, user access Full Access); Xcode installed; and the store metadata filled in (see [App Store Connect reference](#app-store-connect-reference)).

### Releasing a new version

1. **Bump the version.** In Xcode, go to GitIssues > Targets > GitIssues > General and increment the version number.
2. **Commit, push and tag** (replace `v1.2.3` with the new version):

   ```bash
   git tag v1.2.3
   git push origin v1.2.3
   ```

3. **Check the signing settings** (see [Signing](#signing)).
4. **Build for release.** Product > Scheme > Edit Scheme > Archive, set Build Configuration to **Release**. Then Product > Destination > **Any Mac**, and Product > **Archive**.
5. **Upload.** Window > Organizer, select the new archive, click **Distribute App**, choose **App Store Connect**, then **Distribute**.
6. **Submit for review** in App Store Connect:
   1. The uploaded build appears under **TestFlight**. Make sure its status is "Ready to Submit" (fix any export-compliance questions if asked).
   2. Go to Distribution and click **+** to add a new version. You should now see "Prepare for Submission". Check the version number and update any other metadata.
   3. Click **Save**, then **Add for Review**, then on the next page **Resubmit to App Review**.
   4. Confirm the status is now "Waiting for Review".
7. **Wait.** Review typically takes 24–48 hours for Mac apps. Approved builds go live immediately or on the date you scheduled. If rejected, read the Resolution Center feedback.

**Resubmitting after a rejection:** fix the issues and upload a new build (steps 1–5). In App Store Connect, select the rejected submission under macOS App in the sidebar, scroll to Build, remove the old build and click **Add build** to choose the new one. Click **Save**, then **Update Review**, then **Resubmit to App Review**.

### Signing

In Xcode, GitIssues > Targets > GitIssues > Signing & Capabilities:

- **Signing:** *Automatically manage signing* on; Team `SPELLO CONSULTING PTY LTD`; Bundle Identifier `com.spelloconsulting.gitissues`; macOS Signing Certificate left as *Development* (Xcode re-signs with the Apple Distribution certificate when you distribute from the Organizer).
- **App Sandbox:** Outgoing Connections (Client) on; User Selected File set to Read Only; everything else off or None.
- **Hardened Runtime (Release):** no runtime exceptions ticked.

#### If the upload fails with "Signing certificate is invalid. It may have been revoked or expired."

Xcode doesn't say which certificate is bad. Find out in a terminal:

```bash
security find-identity -v -p codesigning
```

Look for `CSSMERR_TP_CERT_REVOKED` (or an expired cert) next to the distribution certs. A revoked certificate can't be reinstated, so replace it:

1. Xcode > Settings > Accounts, select the Spello Consulting team, click **Manage Certificates…**.
2. Click **+** and create **Apple Distribution** and **Mac Installer Distribution**.
3. Confirm *Automatically manage signing* is still on.
4. Create a **new archive** (Product > Archive). Don't reuse the old one, because it was signed with the bad certificate. Leave *Automatically manage signing* selected in the Distribute wizard.
5. Optional cleanup: in Keychain Access (login keychain > My Certificates), delete the old revoked entries. Identify them by **expiry date, not name**: Apple still names the Mac Installer Distribution certificate "3rd Party Mac Developer Installer", so an old and a new certificate can look identical. Never click "Revoke" on a valid certificate in Xcode.

Notes:

- Only the Apple Distribution and Mac Installer Distribution certificates matter for App Store uploads. Developer ID and Apple Development certificates are not used.
- The current Apple Distribution and Mac Installer Distribution certificates were created on 27 Nov 2026 and **expire on 27 Nov 2027**. Check them before the first upload after that date.

### App Store Connect reference

**Required metadata** (all complete): description; keywords (max 100 characters); support URL; at least one Mac screenshot (1280×800 or 1440×900); App Review Information (explain the GitHub OAuth sign-in flow, and either provide a demo GitHub account or say the reviewer can use their own); privacy policy URL (required because of GitHub OAuth); age rating questionnaire; pricing; and App Privacy.

**App Privacy.** The App Privacy "nutrition label" in App Store Connect must match the app's privacy manifest, and an Admin must complete it before the first submission. The manifest declares:

| Setting | Value |
|---|---|
| Privacy tracking enabled | No |
| Collected data: User ID | Linked to user; not used for tracking; purpose: App Functionality |
| Collected data: Name | Linked to user; not used for tracking; purpose: App Functionality |
| Accessed API: User Defaults | Reason `CA92.1` (access info from the same app) |

**Keywords:** `github,issues,bug,tracker,repository,developer,markdown,git,code,project,task,kanban,todo,workflow`

<details>
<summary>App Store description</summary>

**GitIssues — GitHub Issues, Without the Browser**

GitIssues is a focused, native macOS app for managing GitHub issues across all your repositories. No browser tabs, no distractions — just your issues, organised and accessible from your desktop.

Sign in with your GitHub account and get straight to work. GitIssues gives you a clean, fast interface for the things you actually do with issues every day: creating them, updating them, labelling them, assigning them, and closing them — across every repo you have access to.

**Key Features**

- Browse and search issues across multiple repositories from a single window.
- Create new issues with full Markdown support and live preview.
- Edit issue titles, descriptions, labels and comments.
- Open and close issues without leaving the app.
- Filter by state (open, closed), repository, visibility (public, private) and your involvement (creator, assignee, collaborator).
- Rich Markdown rendering for issue descriptions and comments.
- View and add comments on any issue.
- Share, pin, clone and delete issues.
- Sort the issue in a variety of ways.
- Fast, native macOS experience - built with SwiftUI.
- Secure GitHub OAuth sign-in - your credentials are never stored by the app.
- Lightweight and private — no analytics, no tracking, no data collection beyond what's needed to connect to GitHub.

**Built for developers who live in GitHub Issues and want a faster, cleaner way to stay on top of them.**

</details>

## Known Limitations

- With a very large number of issues (hundreds), the very first load after installing, or after clearing the cache, can take 8-10 seconds to complete; open issues appear within a couple of seconds. Later launches use the local cache.
- You cannot attach files or images to an issue at this time. This is a known limitation of the GitHub API. Once GitHub supports this, we'll add this functionality to the app.
- See https://github.com/NickElseySpelloC/gitissues/issues for other planned enhancements and bug fixes.