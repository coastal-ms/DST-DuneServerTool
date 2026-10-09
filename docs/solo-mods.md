# Solo mods

Close Dune before installing mods or changing the enabled list. In Solo Mode, open Solo mods, select the Dune Awakening installation folder, and save it. Install the mod runtime once, then use Install mod ZIP to import downloaded packages.

Mods are kept in the Dune Server Tool `Mods` folder. Open Mods Folder opens that directory so you can edit a mod's INI as its author describes. Existing installed folders are preserved: a duplicate ZIP is rejected rather than overwriting your settings. To replace a mod, close Dune, move its old folder out of Mods, and import the replacement.

Enable the mods you want and choose Launch with Mods. Launch Normally bypasses the runtime. After the game exits, DST's independent helper restores previous launch files. If a session was interrupted, close Dune and use Restore normal launch. Files changed by another application are preserved and reported.

This loader supports UE4SS Lua packages with `Scripts/main.lua` and native packages with `dlls/main.dll`. Packages can contain a `mod.json` manifest. Declared required mods, versions, conflicts and loading order are checked. Missing dependencies are shown; install them yourself from their authors. Launcher and runtime-version declarations do not block launching or display warnings. WPS services are not emulated; supply any framework dependencies as separate mods. Standalone PAK-only packages and other launcher formats are not supported by this runtime.

Use Refresh to view the loader log and launch errors. DST does not download dependencies, fix mods or certify gameplay compatibility. Follow the mod author's instructions and test in Solo mode.

Help → Skip intro / splash screens applies to every Dune launch from DST, with or without mods. The option uses the game's startup arguments and requires no mod.
