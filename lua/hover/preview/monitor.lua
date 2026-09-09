---@module 'hover.preview.monitor'
---@brief Which monitor the terminal is on right now, for whichever playback
--- tier is about to open a window.
---@description
--- **The question this answers, once, synchronously, before a player opens.**
--- `preview.window` wants an mpv `--screen=N` that matches wherever the
--- reader actually is, not screen 0 by default; `preview.align_win` wants a
--- rectangle to centre the system player's window inside, on the right
--- monitor, not always the primary one. Both need the same fact — the
--- foreground terminal window's own bounds — so it is answered here once
--- rather than twice.
---
--- **Why the *foreground* window, and why that is a safe assumption.** `<CR>`
--- on a video hover is a deliberate keypress: whatever the reader just typed
--- into is, by definition, the window that had focus a moment ago. There is
--- no more direct way to ask "where is the reader" from inside a terminal
--- Neovim, which has no window handle of its own to report a screen position
--- from (`getwinpos()` answers -1,-1 outside a GUI front-end).
---
--- **Synchronous, unlike `align_win`'s poll.** That module waits several
--- seconds for a *new* window to appear; this one asks about a window that
--- already exists, so one quick query answers it — a short `vim.system(...)
--- :wait()` rather than a background poll.
---
--- **The screen index is Windows-only, and says so.** Matching mpv's own
--- `--screen=N` numbering against a monitor found by other means could only
--- be verified on Windows (confirmed 2026-09-09 against a real two-monitor
--- machine: `Screen.AllScreens` order matched mpv's). macOS and Linux still
--- answer the terminal's rectangle, which `align_win` can centre the system
--- player's window inside — mpv's own `--screen` support for a *windowed*
--- (non-fullscreen) placement on those platforms was not something this
--- could be tested against, so no index is guessed there.

local M = {}

---@internal
---@return string
local function script_windows()
  return [[
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class HoverMon {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
$hwnd = [HoverMon]::GetForegroundWindow()
$rect = New-Object HoverMon+RECT
[HoverMon]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
$cx = ($rect.Left + $rect.Right) / 2
$cy = ($rect.Top + $rect.Bottom) / 2

$screens = [System.Windows.Forms.Screen]::AllScreens
$index = 0
$matched = $screens[0]
for ($i = 0; $i -lt $screens.Length; $i++) {
  $b = $screens[$i].Bounds
  if ($cx -ge $b.X -and $cx -lt ($b.X + $b.Width) -and $cy -ge $b.Y -and $cy -lt ($b.Y + $b.Height)) {
    $index = $i
    $matched = $screens[$i]
    break
  }
}
$wa = $matched.WorkingArea
Write-Output "$index $($wa.X) $($wa.Y) $($wa.Width) $($wa.Height)"
]]
end

---@internal
--- No screen index (mpv's `--screen` support for this case is untested on
--- macOS from here) -- just the frontmost window's own bounds, for
-- `align_win` to centre inside.
---@return string
local function script_macos()
  return [[
tell application "System Events"
  set frontProc to first process whose frontmost is true
  set frontWin to front window of frontProc
  set p to position of frontWin
  set s to size of frontWin
end tell
return "-1 " & (item 1 of p) & " " & (item 2 of p) & " " & (item 1 of s) & " " & (item 2 of s)
]]
end

---@internal
--- Same reasoning as macOS: bounds only, no screen index. `xdotool` answers
--- nothing under Wayland, same as `align_win`'s own caveat there.
---@return string
local function script_linux()
  return [[
#!/usr/bin/env bash
if ! command -v xdotool >/dev/null 2>&1; then
  exit 0
fi
win="$(xdotool getactivewindow 2>/dev/null)"
[ -z "$win" ] && exit 0
geom="$(xdotool getwindowgeometry --shell "$win" 2>/dev/null)"
x="$(echo "$geom" | grep '^X=' | cut -d= -f2)"
y="$(echo "$geom" | grep '^Y=' | cut -d= -f2)"
w="$(echo "$geom" | grep '^WIDTH=' | cut -d= -f2)"
h="$(echo "$geom" | grep '^HEIGHT=' | cut -d= -f2)"
[ -z "$w" ] && exit 0
echo "-1 $x $y $w $h"
]]
end

---@internal
---@return "windows"|"macos"|"linux"|nil
local function detect_platform()
  local function check(mod)
    local ok, fn = pcall(require, mod)
    return ok and fn() or false
  end
  if check("lib.nvim.cross.platform.is_windows") then
    return "windows"
  end
  if check("lib.nvim.cross.platform.is_macos") then
    return "macos"
  end
  if check("lib.nvim.cross.platform.is_linux") then
    return "linux"
  end
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    return "windows"
  end
  if vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1 then
    return "macos"
  end
  if vim.fn.has("unix") == 1 then
    return "linux"
  end
  return nil
end

--- Where the terminal is right now: which screen (Windows only; `nil`
--- elsewhere) and its rectangle. `nil` when it cannot be answered at all --
--- a caller then falls back to whatever it did before this module existed.
---@param timeout_ms integer|nil default 1000
---@return { screen: integer|nil, x: integer, y: integer, w: integer, h: integer }|nil
function M.detect(timeout_ms)
  local platform = detect_platform()
  if not platform then
    return nil
  end

  local argv, ext
  if platform == "windows" then
    argv, ext =
      { "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File" },
      ".ps1"
  elseif platform == "macos" then
    argv, ext = { "osascript" }, ".applescript"
  else
    argv, ext = { "bash" }, ".sh"
  end

  local content = ({
    windows = script_windows,
    macos = script_macos,
    linux = script_linux,
  })[platform]()

  local path = vim.fn.stdpath("cache") .. "/hover_detect_monitor" .. ext
  local fd = io.open(path, "w")
  if not fd then
    return nil
  end
  fd:write(content)
  fd:close()

  argv[#argv + 1] = path

  local ok, result = pcall(function()
    return vim.system(argv, { text = true }):wait(timeout_ms or 1000)
  end)
  if not ok or not result or result.code ~= 0 or type(result.stdout) ~= "string" then
    return nil
  end

  local screen, x, y, w, h = result.stdout:match("(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%d+)%s+(%d+)")
  if not x then
    return nil
  end
  screen = tonumber(screen)
  return {
    screen = (screen and screen >= 0) and screen or nil,
    x = tonumber(x),
    y = tonumber(y),
    w = tonumber(w),
    h = tonumber(h),
  }
end

return M
