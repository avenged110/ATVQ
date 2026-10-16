# ATVQ

A tvOS 18 application for viewing FilmTracker's "Up Next" Queue with an included utility for automatically keeping the installation refreshed under Apple's idiotic iOS deployment terms (and for proxying Queue dispatches while Apple TV is asleep).

I don't expect anyone to actually use this aside from myself. It's a highly specific solution for an extremely narrow use case, arguably of any value to anyone.

## Installation and Usage

ATVQ may only be provisionally installed on tvOS devices you register in Xcode after authenticating with your Apple ID and generating a personal "team" certificate. ATVQ Deployer then keeps the provisioning profile refreshed automatically.

ATVQ Deployer (for macOS) is not signed with an Apple Developer ID and is not notarized. To launch it, you can either disable Gatekeeper, remove the quarantine flag manually with the command below (using the appropriate path for your installation, of course), navigate to System Settings > Privacy & Security and click "Open Anyway" after first attempting a launch, or build it yourself with Xcode (open `ATVQ Deployer.xcodeproj` in Xcode and choose Product > Build).

```sh
xattr -dr com.apple.quarantine "/Applications/ATVQ Deployer.app"
```

On first launch, you must grant ATVQ Deployer "Local Network" permission either from Apple's TCC popup alert or in System Settings > Privacy & Security > Local Network in order for it to proxy queue dispatches and discover and provision the selected Apple TV(s).

## System Requirements and Security

- macOS 15.6.0 or later, Apple Silicon only for ATVQ Deployer. tvOS 18.5 or later for ATVQ.
- "Local Network" permission via Apple's TCC system for ATVQ Deployer.
- Uses Apple's Hardened Runtime, and is compliant with Swift 6 (Strict Concurrency and Strict Memory Safety); built against Xcode 26.3.
- FilmTracker 1.0.1 or later.

## Support

There is none.

## Note

I am not a software engineer; all of the code for this project was written by Anthropic's Claude models. That said, I use all of the applications under this account regularly in my daily life, so while they're not perfect, I'm confident in their efficacy and general reliability.

## License

ATVQ and ATVQ Deployer are free software, licensed under the GNU General Public License, version 3 only (GPL-3.0-only). Copyright © 2026 avenged110. The full license text is in `COPYING`.
