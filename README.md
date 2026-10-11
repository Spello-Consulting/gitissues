# GitIssues

This is a native macOS SwiftUI application that you can use to create and edit GitHub issues across multiple repositories.

It's fairly new, but it's already better that some of the alternatives I've tried and rejected (Taska; Gitscout; GitKraken; etc.).

This app only intended for issue management, it won't help you with other aspects of Git / GitHub.

## Installing

Clone this repo and build the app on your Mac. I've tested on an Intel Mac (running Sequoia 15.7) and an Apple Silicon mac (running Tahoe 26.1). Just build the app and copy GitIssues.app to your Applications folder - you can use the GitUssues/build_for_relase.sh script to do this.

## GitHub Authentication

The first time you run the app you'll see a Connect to GitHub screen. Click the buttons and follow the process to authenticate the app to GitHub using your existing GitHub account. 

By default, GitIssues only requests access to public repos (that you own or are collaborating on). If you also want to edit issues in your private repos, go the GitIssues > Settings... and turn on _Allow private repository access_. Your will be taken through the GitHub authorisation process again.

## Running the tests

The unit tests live in the `GitIssuesTests` target. Run them from Xcode (Product > Test, or ⌘U), or from the command line:

```bash
xcodebuild test -project GitIssues/GitIssues.xcodeproj -scheme GitIssues -destination 'platform=macOS'
```

## Known Limitations

- Some performance enhancements may be warranted for users with a large number of issues.
- You cannot attach files or images to an issue at this time. This is a known limitation of the GitHub API. Once GitHub supports this, we'll add this functionality to the app.
- See https://github.com/NickElseySpelloC/gitissues/issues for other planned enhancements and bug fixes.