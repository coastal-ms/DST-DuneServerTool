Owned read-only Atlas runtime sources

The DST host copies the manifest-listed sources into a versioned per-user runtime
folder. Source files contain no access keys, database snapshots, actor-address
caches or machine paths. Bootstrap contexts contain only verified build hashes
and image-relative name-pool offsets. Native discovery rejects other builds.

Opening the service loads the last saved snapshot and starts no observations.
Refresh performs a bounded capture. Start live enables the observation workers;
Stop live lets in-flight reads finish and saves a frozen snapshot. No observer
attaches to, signals or writes the game process. SQL uses DST's read-only wrapper.

The DST session/view/resource routes proxy the loopback host through the existing
authenticated DST origin. Remote owner/admin logins, including Tailscale, use that
same origin; collector keys never go to the remote browser. Linked-player access
is not expanded. Static seed maps remain in the reference atlas. The popout uses
the observer view and synchronizes the selected layers with its main view.
The private map host checks its owning backend's process identity and stops when
that backend exits. Closing a viewer while DST keeps serving leaves collection
available through the running backend.

The default keeps the existing collection periods and one-second display polling.
Saved live refresh choices range from one second to one minute. Slow choices also
reduce collection frequency; costly discovery jobs keep their existing minimum
periods, and each worker finishes its current read before starting another.
Recorded storm trails live in shared snapshot storage and survive runtime upgrades.

Current native support is the two recorded Linux server builds. Deep Desert has
live resources, worms, storms and supported vehicles. Hagga has current-world POIs
and gathering positions; its vehicles are saved positions. Fuel is saved data.
Spice-sand yield is the remaining field counter divided by ten before bonuses.

Python 3.10+ and PowerShell are currently required on the Windows host. The small
Linux O_RDONLY helpers are bundled with their owned assembly sources. Starting
collection verifies their hashes, restores missing helpers into a root-owned
persistent directory and rediscovers the current game process after a reboot.
Opening a saved map alone installs nothing. Embedded Python packaging is not
implemented yet.

Game art and community-rendered terrain are not bundled. Local assets belong in
the user's Atlas asset cache, with background names selected by the own server's
layout. Missing local game images use bundled vector icons, including an original white
flour-sand mound. The vector baseline retains the upstream Lucide ISC license.
Hagga uses the locally cached `hagga-background-v1.webp` (PNG fallback). Marker art
loads in one bounded response. Terrain prefers the smaller cached WebP images.
Selected Stravidium and Titanium layers also show seed-matched reference deposit
areas from the existing seed atlas. These are approximate areas, separately labeled
and counted; they do not establish individual-node coverage or remaining resources.

Edit these worktree sources directly. The earlier private research folder is not
a build dependency. Run tools/atlas/update-manifest.py after source changes.
