# TrayForge

A system tray icon for Windows that opens a menu of your commands on click: launch apps, run PowerShell/CMD scripts, control your system. Everything is configured in a single `config.json` file or via the built-in GUI editor.

Nothing to install — only the PowerShell built into Windows is required.

## Features

- Native tray icon (left/right click opens the menu)
- Two menu styles: **text with icons** and **large icons** (switchable on the fly)
- **PowerShell**, **CMD** commands plus automatic interpreter detection by file extension
- Multiple commands per menu item — executed sequentially in a single session
- Hidden, normal, or minimized console window; the window can stay open after execution
- Per-command working directory + global default folder
- Item icons from `.ico`, `shell32.dll`, `imageres.dll`, or any exe (by index)
- Confirmation prompts before dangerous actions and a "Done" notification after launch
- Separators between menu items
- GUI config editor — no manual JSON editing required
- Config reload: after editing `config.json`, simply restart the tray ("Exit" → `start-hidden.vbs`)

## Quick Start

1. Clone the repository or download the `TrayForge` folder.
2. Run `start-hidden.vbs` (double-click) — a tray icon will appear.
3. Click the icon — a menu with example commands opens.
4. Open the editor: right-click the tray icon → **Config Editor...**
   (or double-click `edit-config.vbs`) and set up your own commands.

## Autostart on Windows Login

1. Press `Win + R`, type `shell:startup`, press Enter.
2. Copy a shortcut to `start-hidden.vbs` into the opened folder.

## config.json Format

The file supports `//` and `/* ... */` comments (they are stripped before parsing).
Example:

```jsonc
{
    // Tray icon: "file.ico", "shell32.dll,44", "imageres.dll,-109" or a path to an exe
    "icon": "imageres.dll,76",

    // Tooltip shown when hovering over the tray icon
    "tooltip": "My Commands",

    // Menu style: "text" (text with icons) | "icons" (grid of large icons)
    "mode": "text",

    // Default folder for command windows ("%USERPROFILE%", "C:\\path")
    "defaultCwd": "%USERPROFILE%",

    // Array of menu items
    "commands": [
        {
            "name": "Empty Recycle Bin",
            "icon": "imageres.dll,54",
            "shell": "powershell",
            "command": "Clear-RecycleBin -Force",
            "window": "hidden",
            "notify": true
        },
        {
            "name": "Start dev server",
            "icon": "shell32.dll,220",
            "shell": "powershell",
            "commands": [          // multiple commands — one session, in order
                "cd test",
                "npm run dev"
            ],
            "window": "normal"     // the window stays open
        }
    ]
}
```

### Global Parameters (file root)

| Parameter    | Type   | Default           | Description |
|--------------|--------|-------------------|-------------|
| `icon`       | string | PowerShell icon   | Tray icon in the special format: path to an `.ico`, `"file,index"` (dll/exe), or an exe name. See the "Icon Format" section below. If the icon fails to load, a fallback is used. |
| `tooltip`    | string | `TrayCommands`    | Tooltip text when hovering over the tray icon. |
| `mode`       | string | `text`            | Menu style on click: `text` — classic text menu with small icons on the left; `icons` — popup panel of large icon buttons (up to 6 per row), labels shown as tooltips. Can also be switched without editing the config — via the "View" item in the menu itself. |
| `defaultCwd` | string | `%USERPROFILE%`   | Working directory for command windows when an item has no own `cwd`. Supports environment variables (`%USERPROFILE%`, `%APPDATA%`). A relative path is resolved against the script folder. |
| `commands`   | array  | required          | List of menu items. Without it, startup aborts with an error. |

### Command Parameters (an element of the `commands` array)

| Parameter        | Type         | Values                              | Default                        | Description |
|------------------|--------------|-------------------------------------|--------------------------------|-------------|
| `name`           | string       | any text                            | required                       | Item label in the menu; in `icons` mode — tooltip on button hover. |
| `icon`           | string       | see "Icon Format"                   | empty                          | Item icon. If missing or not found, the item is displayed without an icon. |
| `shell`          | string       | `powershell`, `pwsh`, `cmd`, `auto` | `powershell`                   | What to execute the command with. `powershell`/`pwsh` — PowerShell (PowerShell 7+ is used automatically if installed, otherwise the built-in 5.1); `cmd` — CMD interpreter (`%ComSpec%`); `auto` — detected from the first word of the command: `.bat`/`.cmd` extensions → CMD, `.ps1`/`.psm1` → PowerShell, everything else → CMD. |
| `command`        | string       | any command                         | —                              | A single command. At least one of `command`/`commands` is required: without them `-Test` reports an error and the item won't appear in the icons panel. `commands` takes priority. |
| `commands`       | array of strings | list of commands                | —                              | Multiple commands in **one session**, executed in order. Joined with `&` for CMD and with `;` for PowerShell. Blank lines are discarded. |
| `window`         | string       | `hidden`, `normal`, `minimized`     | `hidden`                       | Console window mode: `hidden` — no window is shown at all; `normal` — a regular visible window; `minimized` — starts minimized to the taskbar. |
| `cwd`            | string       | folder path                         | `defaultCwd` → home folder     | Working directory for this command. Environment variables are expanded (`%USERPROFILE%`); a relative path is resolved against the script folder. If the folder doesn't exist, the default is used. |
| `keepOpen`       | boolean      | `true`, `false`                     | `true` for visible windows, `false` for `hidden` | Keep the window open after execution. For CMD this selects `/k` instead of `/c`; for PowerShell it adds `-NoExit`. Set `false` explicitly to make a visible console close automatically. |
| `confirm`        | boolean      | `true`                              | `false`                        | Show a "Run: *name*?" dialog with Yes/No buttons before execution. Useful for shutting down the PC, deleting files, etc. |
| `notify`         | boolean      | `true`                              | `false`                        | Show a balloon notification near the clock ("Done") after the command **starts**. This signals launch, not completion — completion isn't tracked for hidden windows. |
| `separatorAfter` | boolean      | `true`                              | `false`                        | Draw a horizontal separator right below this menu item (ignored in `icons` mode). |

### Icon Format

An `icon` value (for both the tray and items) understands three notations:

| Notation               | Example                   | Meaning |
|------------------------|---------------------------|---------|
| path to `.ico`         | `"my.ico"`                | A standalone icon file. |
| `"file,index"`         | `"shell32.dll,220"`, `"imageres.dll,-109"` | Icon number `index` from a DLL or EXE (a minus as in `-109` means a resource ID rather than a positional index). |
| exe name/path          | `"taskmgr.exe"`           | The first icon of the executable. |

Search order for non-absolute paths: script folder → `System32` → Windows folder → additionally the `PATH` variable for `.exe`. Environment variables like `%SystemRoot%` are expanded.

To find an icon number, run
`powershell -NoProfile -ExecutionPolicy Bypass -File tray.ps1 -Test` — for each command you'll see whether the icon loaded at 16 and 32 px.

## How the Menu Works

- **Left click** on the icon opens the menu (or the icon panel). **Right click** opens the same context menu.
- The bottom of the menu always has service items: the "text ↔ icons" view toggle, **Config Editor...**, and **Exit**.
- The config is read **once at startup**: to apply changes to `config.json`, exit via "Exit" and start again (`start-hidden.vbs`). The "text ↔ icons" view toggle, on the contrary, takes effect immediately without touching the file.
- Clicking the balloon notification near the clock also opens the menu.
- If the config fails to load at startup, an error dialog appears and the app exits.

## GUI Editor

Launch: double-click `edit-config.vbs` or the **Config Editor...** menu item.

- global settings (icon, tooltip, menu style, default folder);
- add / edit / delete / reorder commands;
- all command fields in a convenient form with validation before saving;
- saves human-readable JSON with comments; warns about unsaved changes on exit.

## Validate Config Without Launching the GUI

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tray.ps1 -Test
```

Prints the number of commands, the menu mode, and per item — the interpreter and icon load status.

### Script Parameters

| Script            | Parameter     | Description |
|-------------------|---------------|-------------|
| `tray.ps1`        | `-ConfigPath <path>` | Optional. Alternative path to the config (defaults to `config.json` next to the script). |
| `tray.ps1`        | `-Test`       | Validate the config and icons, print a report, and exit without starting the tray. |
| `edit-config.ps1` | `-SelfTest`   | Editor self-check: config serialization round-trip without opening a window. |

## Files

| File               | Purpose |
|--------------------|---------|
| `tray.ps1`         | Tray application (main script) |
| `config.json`      | Commands configuration |
| `edit-config.ps1`  | GUI config editor |
| `edit-config.vbs`  | Editor launcher via double-click (no console) |
| `start-hidden.vbs` | Tray launcher via double-click (no console) |

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 (built-in) or PowerShell 7+

## License

MIT
