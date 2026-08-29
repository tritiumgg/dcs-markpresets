# MarkPresets

Preset text buttons under the F10 map's mark dialog in DCS World.

Open a mark, click a button, and its text goes into the mark. Useful for the
things you write over and over without typing them out mid-flight.

Client-side and cosmetic. It reads the mark dialog and writes into its text box;
it does not touch the mission, the server, or anything else's UI.

## Get it

[Latest release](../../releases/latest) → `MarkPresets.zip`.

## Install

1. Extract `MarkPresets.zip` into `Saved Games\DCS`.
2. **First install only:** rename `Config\MarkPresetsConfig.lua.example` to
   `MarkPresetsConfig.lua`. On an upgrade, leave your existing config alone —
   the archive never overwrites it.
3. Restart DCS. Hooks load at startup only.

Files land at:

```
Saved Games\DCS\Scripts\Hooks\MarkPresets.lua
Saved Games\DCS\Config\MarkPresetsConfig.lua.example
```

## Use

Open the F10 map and place or open a mark. The panel appears under the dialog.
Click a preset to write its text into the mark; the mark is sent when you click
away, the same as typing it by hand.

Two things that are not obvious:

- Presets appear only while you are **in an aircraft**, never while spectating.
- They appear only in a mission or server one of your profiles matches.

## Configure

Everything lives in `Config\MarkPresetsConfig.lua`, and its own comments are the
reference. Edit it, then restart DCS.

A profile says where its presets apply — a mission, a server, or both:

```lua
MarkPresets = {
  -- ...
  profiles = {
    {
      serverPattern = "RotorHeads",   -- any server with RotorHeads in its name
      sections = {
        {
          header = "Contacts",
          presets = {
            { name = "SAM",      text = "SA-6 site" },
            { name = "Vehicles", text = "Vehicles: {|}" },   -- {|} = cursor lands here
          },
        },
      },
    },
  },
}
```

`missionPattern` and `serverPattern` match plain text anywhere in the name and
ignore case, so punctuation needs no escaping. `missionPattern = "*"` matches
everywhere. Profiles are tried in order and the first match wins.

Global options worth knowing:

- `autoCommit` sends the mark on the click instead of when you click away.
- `compact` tightens the layout.
- `layout = "strip"` puts all of your buttons in a horizontally scrolling strip.

## When it does not work

`Logs\MarkPresets.log` is the first place to look. Set `logLevel = "info"` in the
config to make it talkative — it prints the exact mission and server names as
they load, which is what you copy into a profile.

- Log empty below the banner → loaded fine, nothing matched. Set `logLevel` to
  `"info"` to see which profile was tried.
- No log at all → the hook never loaded. The reason is in `Logs\dcs.log`.
- `Config\MarkPresets-probe.marker` exists → a native call crashed DCS on a
  previous run and has been disabled. Delete the file to let it try again.

## Uninstall

Delete `Scripts\Hooks\MarkPresets.lua`. Optionally also
`Config\MarkPresetsConfig.lua`, `Config\MarkPresetsConfig.lua.example`,
`Config\MarkPresets-probe.marker` and `Logs\MarkPresets.log`. Nothing is appended
to `Export.lua` and no `Mods\tech\` folder is created.

## Releasing

Pushing to `main` bumps the version, builds `MarkPresets.zip` and publishes a
release. The bump follows [Conventional Commits](https://www.conventionalcommits.org):
`feat:` gives a minor, anything else a patch, and `!` or a `BREAKING CHANGE`
footer gives a major. Release notes are grouped from the commit subjects since
the last tag.

The version in `Scripts/Hooks/MarkPresets.lua` is the single source of truth; the
workflow rewrites it and commits the change.
