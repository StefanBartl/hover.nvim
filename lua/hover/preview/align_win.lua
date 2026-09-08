---@module 'hover.preview.align_win'
---@brief Best-effort: centre whatever window a system-opened player creates.
---@description
--- **Experimental, cross-platform, and silent when it cannot.** `preview.
--- external` hands a video off to whatever the OS opens it with — no argv of
--- its own, so there is no `--geometry` to pass the way `media.core.player`
--- passes mpv one. The only way left to approximate it is to watch for the
--- window that appears right after the hand-off and move it ourselves.
---
--- **Why this can fail, and does not report when it does, on every
--- platform.** Which app opens a video is whatever is registered on this
--- machine, not something this plugin controls, and moving another
--- process's window from outside it is something every desktop restricts to
--- a different degree:
---
---   - **Windows.** A classic window (VLC, MPC-HC) moves cleanly with
---     `SetWindowPos`. The stock handler for a video, "Films & TV", is a UWP
---     app running inside a shared `ApplicationFrameHost.exe` container, and
---     that container's window has historically ignored being moved from
---     outside it. Measured on this machine 2026-09-09: the registered
---     handler for `.mp4` *is* that UWP app.
---   - **macOS.** `System Events` can move most apps' windows, but only once
---     the terminal running Neovim has been granted Accessibility permission
---     (System Settings → Privacy & Security → Accessibility) — without it,
---     every `tell` below answers nothing, not an error.
---   - **Linux.** `xdotool` (preferred) or `wmctrl` can move a window under
---     X11. Under Wayland, the compositor's own security model refuses this
---     to any external tool by design, on every desktop this was checked
---     against — there is no escape hatch, only silence.
---
--- There is no reliable way to tell any of these apart in advance, so this
--- never surfaces an error on any of them: it centres the window when it
--- can, and does nothing differently from the plain fallback when it cannot.
---
--- **Each platform's script is disposable**, written fresh to
--- `stdpath("cache")` and run hidden, rather than shipped as a separate
--- asset: this feature has nothing else to keep in sync with it, and a
--- fresh write is one small file, not worth an rtp-relative path lookup this
--- codebase otherwise has no need for. All three share the same shape:
--- snapshot the visible top-level windows before the hand-off, poll for a
--- new one for a few seconds, and move whichever new one looks like a real
--- player rather than a toast notification.

local M = {}

---@internal
--- Windows: `EnumWindows` before and after, `SetWindowPos` on the first new,
--- visible, reasonably-sized window. See the module doc for the UWP caveat.
---@return string
local function script_windows()
  return [[
param(
  [int]$TimeoutMs = 6000,
  [int]$PollMs = 300,
  [int]$MinWidth = 250,
  [int]$MinHeight = 150
)

$ErrorActionPreference = "SilentlyContinue"

Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class HoverWin32 {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

function Get-VisibleWindows {
  $result = @{}
  $cb = {
    param($hWnd, $lParam)
    if ([HoverWin32]::IsWindowVisible($hWnd)) {
      $len = [HoverWin32]::GetWindowTextLength($hWnd)
      if ($len -gt 0) {
        $sb = New-Object System.Text.StringBuilder ($len + 1)
        [HoverWin32]::GetWindowText($hWnd, $sb, $sb.Capacity) | Out-Null
        $result[$hWnd] = $sb.ToString()
      }
    }
    return $true
  }
  [HoverWin32]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
  return $result
}

$before = Get-VisibleWindows
$deadline = (Get-Date).AddMilliseconds($TimeoutMs)
$found = $null

while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds $PollMs
  $after = Get-VisibleWindows
  foreach ($hwnd in $after.Keys) {
    if (-not $before.ContainsKey($hwnd)) {
      $rect = New-Object HoverWin32+RECT
      if ([HoverWin32]::GetWindowRect($hwnd, [ref]$rect)) {
        $w = $rect.Right - $rect.Left
        $h = $rect.Bottom - $rect.Top
        if ($w -ge $MinWidth -and $h -ge $MinHeight) {
          $found = @{ hwnd = $hwnd; w = $w; h = $h }
          break
        }
      }
    }
  }
  if ($found) { break }
}

if ($found) {
  $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $x = $area.X + [Math]::Max(0, [int](($area.Width - $found.w) / 2))
  $y = $area.Y + [Math]::Max(0, [int](($area.Height - $found.h) / 2))
  # SWP_NOSIZE (0x0001) | SWP_NOZORDER (0x0004): move only, touch neither the
  # size the player chose for itself nor which window is on top of which.
  [HoverWin32]::SetWindowPos($found.hwnd, [IntPtr]::Zero, $x, $y, 0, 0, 0x0005) | Out-Null
  [HoverWin32]::SetForegroundWindow($found.hwnd) | Out-Null
}
]]
end

---@internal
--- macOS: `System Events` enumerates every visible process's windows by
--- name (there is no numeric handle exposed this plainly for an arbitrary
--- app), diffs before/after, and moves the first new one. Needs the
--- terminal to have Accessibility permission -- absent that, every `tell`
--- below answers nothing, which the surrounding `try` already treats the
--- same as "did not find one".
---@return string
local function script_macos()
  return [[
on windowList()
  set result to {}
  tell application "System Events"
    try
      repeat with proc in (every process whose visible is true)
        try
          repeat with w in (every window of proc)
            set end of result to ((name of proc) & "||" & (name of w))
          end repeat
        end try
      end repeat
    end try
  end tell
  return result
end windowList

set beforeList to windowList()
set deadline to (current date) + 6
set foundProc to ""
set foundWin to ""

repeat while (current date) < deadline
  delay 0.3
  set afterList to windowList()
  repeat with entry in afterList
    if beforeList does not contain entry then
      set AppleScript's text item delimiters to "||"
      set parts to text items of entry
      set AppleScript's text item delimiters to ""
      if (count of parts) is 2 then
        set foundProc to item 1 of parts
        set foundWin to item 2 of parts
        exit repeat
      end if
    end if
  end repeat
  if foundProc is not "" then exit repeat
end repeat

if foundProc is not "" then
  try
    tell application "Finder" to set screenBounds to bounds of window of desktop
    set screenW to (item 3 of screenBounds) - (item 1 of screenBounds)
    set screenH to (item 4 of screenBounds) - (item 2 of screenBounds)
    tell application "System Events"
      tell process foundProc
        set winSize to size of window foundWin
        set winW to item 1 of winSize
        set winH to item 2 of winSize
        set newX to ((screenW - winW) / 2) as integer
        set newY to ((screenH - winH) / 2) as integer
        if newX < 0 then set newX to 0
        if newY < 0 then set newY to 0
        set position of window foundWin to {newX, newY}
        set frontmost to true
      end tell
    end tell
  end try
end if
]]
end

---@internal
--- Linux: `xdotool` if present (search, geometry, move, activate, all one
--- tool); `wmctrl` as a cruder fallback that can move a window but not query
--- its size, so it lands at a fixed offset rather than a true centre.
--- Neither can do anything under Wayland, by that compositor's own design --
--- the script still exits cleanly, having simply found nothing to move.
---@return string
local function script_linux()
  return [[
#!/usr/bin/env bash
TIMEOUT_S=6
POLL_S=0.3

have() { command -v "$1" >/dev/null 2>&1; }

deadline=$(( $(date +%s) + TIMEOUT_S ))

if have xdotool; then
  before="$(xdotool search --onlyvisible . 2>/dev/null)"
  found=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep "$POLL_S"
    after="$(xdotool search --onlyvisible . 2>/dev/null)"
    for id in $after; do
      if ! grep -qx "$id" <<< "$before"; then
        found="$id"
        break
      fi
    done
    [ -n "$found" ] && break
  done
  if [ -n "$found" ]; then
    geom="$(xdotool getdisplaygeometry 2>/dev/null)"
    screen_w="$(echo "$geom" | awk '{print $1}')"
    screen_h="$(echo "$geom" | awk '{print $2}')"
    wgeom="$(xdotool getwindowgeometry --shell "$found" 2>/dev/null)"
    win_w="$(echo "$wgeom" | grep '^WIDTH=' | cut -d= -f2)"
    win_h="$(echo "$wgeom" | grep '^HEIGHT=' | cut -d= -f2)"
    if [ -n "$screen_w" ] && [ -n "$win_w" ]; then
      x=$(( (screen_w - win_w) / 2 ))
      y=$(( (screen_h - win_h) / 2 ))
      [ "$x" -lt 0 ] && x=0
      [ "$y" -lt 0 ] && y=0
      xdotool windowmove "$found" "$x" "$y" 2>/dev/null
      xdotool windowactivate "$found" 2>/dev/null
    fi
  fi
elif have wmctrl; then
  before="$(wmctrl -l 2>/dev/null | awk '{print $1}')"
  found=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep "$POLL_S"
    after="$(wmctrl -l 2>/dev/null | awk '{print $1}')"
    for id in $after; do
      if ! grep -qx "$id" <<< "$before"; then
        found="$id"
        break
      fi
    done
    [ -n "$found" ] && break
  done
  if [ -n "$found" ]; then
    # No size query in wmctrl alone: a fixed offset, not a true centre.
    wmctrl -ir "$found" -e 0,100,100,-1,-1 2>/dev/null
    wmctrl -ia "$found" 2>/dev/null
  fi
fi
exit 0
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
  -- lib.nvim absent: fall back to Neovim's own, coarser flags rather than
  -- doing nothing on a machine that otherwise has everything it needs.
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

--- Try, in the background, to centre whatever new window appears on screen in
--- the next few seconds. Never blocks, never raises, never reports back --
--- there is nothing meaningful to tell the reader beyond what `preview.
--- external`'s own badge already says, and "it did not work this time" is an
--- expected outcome on several real setups (a UWP default handler, an
--- unpermitted terminal, a Wayland session), not a bug to surface.
---@return nil
function M.try_centre_new_window()
  local platform = detect_platform()
  if not platform then
    return
  end

  local argv, ext
  if platform == "windows" then
    argv, ext =
      {
        "powershell.exe",
        "-NoProfile",
        "-NonInteractive",
        "-WindowStyle",
        "Hidden",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
      }, ".ps1"
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

  local path = vim.fn.stdpath("cache") .. "/hover_align_video_window" .. ext
  local fd = io.open(path, "w")
  if not fd then
    return
  end
  fd:write(content)
  fd:close()

  argv[#argv + 1] = path
  -- No `detach = true`: measured 2026-09-09 on Windows, a detached
  -- `vim.system` call here did not survive to actually run the poll --
  -- plain `vim.system` (async, no `:wait()`) already does not block the
  -- editor, which is the only thing detaching was for in the first place.
  pcall(vim.system, argv, {})
end

return M
