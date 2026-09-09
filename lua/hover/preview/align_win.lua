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
---   - **Windows.** A classic, restored window (VLC, MPC-HC) moves with
---     `SetWindowPos`; a maximized one is restored first, or the move is a
---     silent no-op. Neither reaches a true borderless-fullscreen window,
---     which many players remember as their last session state and which
---     this script cannot distinguish from "correctly aligned" once it
---     covers the monitor either way -- reported 2026-09-09 against VLC,
---     which is what `preview.external`'s known-player list (launched with
---     an anti-fullscreen flag) exists to avoid in the first place. The
---     stock handler for a video, "Films & TV", is a UWP app running inside
---     a shared `ApplicationFrameHost.exe` container, and that container's
---     window has historically ignored being moved from outside it.
---     Measured on this machine 2026-09-09: the registered handler for
---     `.mp4` *is* that UWP app.
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
  [int]$MinHeight = 150,
  # The monitor to centre inside, from `preview.monitor`'s detection --
  # -1 (the default) means "not given", and PrimaryScreen is the fallback,
  # exactly as before that module existed.
  [int]$TargetX = -1,
  [int]$TargetY = -1,
  [int]$TargetW = -1,
  [int]$TargetH = -1
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
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
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
  if ($TargetW -ge 0) {
    $areaX = $TargetX; $areaY = $TargetY; $areaW = $TargetW; $areaH = $TargetH
  } else {
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $areaX = $area.X; $areaY = $area.Y; $areaW = $area.Width; $areaH = $area.Height
  }
  $x = $areaX + [Math]::Max(0, [int](($areaW - $found.w) / 2))
  $y = $areaY + [Math]::Max(0, [int](($areaH - $found.h) / 2))
  # A maximized window ignores SetWindowPos outright -- restore it first, or
  # the move below is a silent no-op. This does not reach a true borderless
  # fullscreen window (one resized to cover the monitor without ever calling
  # the OS "maximize", which is not IsZoomed and has no restore to ask for);
  # that case is why preview.external tries a known player with an
  # anti-fullscreen flag before ever getting here.
  if ([HoverWin32]::IsZoomed($found.hwnd)) {
    [HoverWin32]::ShowWindow($found.hwnd, 9) | Out-Null  # SW_RESTORE
    Start-Sleep -Milliseconds 100
  }
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
---@param target { x: integer, y: integer, w: integer, h: integer }|nil
---@return string
local function script_macos(target)
  local target_decl = target
      and ("set haveTarget to true\nset targetX to %d\nset targetY to %d\nset targetW to %d\nset targetH to %d"):format(
        target.x,
        target.y,
        target.w,
        target.h
      )
    or "set haveTarget to false"
  return ([[
%s

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
    if haveTarget then
      set screenX to targetX
      set screenY to targetY
      set screenW to targetW
      set screenH to targetH
    else
      -- No detected monitor: the screen the *script* runs on, same as before
      -- `preview.monitor` existed. Not necessarily where the reader is.
      tell application "Finder" to set screenBounds to bounds of window of desktop
      set screenX to item 1 of screenBounds
      set screenY to item 2 of screenBounds
      set screenW to (item 3 of screenBounds) - (item 1 of screenBounds)
      set screenH to (item 4 of screenBounds) - (item 2 of screenBounds)
    end if
    tell application "System Events"
      tell process foundProc
        set winSize to size of window foundWin
        set winW to item 1 of winSize
        set winH to item 2 of winSize
        set newX to (screenX + (screenW - winW) / 2) as integer
        set newY to (screenY + (screenH - winH) / 2) as integer
        if newX < screenX then set newX to screenX
        if newY < screenY then set newY to screenY
        set position of window foundWin to {newX, newY}
        set frontmost to true
      end tell
    end tell
  end try
end if
]]):format(target_decl)
end

---@internal
--- Linux: `xdotool` if present (search, geometry, move, activate, all one
--- tool); `wmctrl` as a cruder fallback that can move a window but not query
--- its size, so it lands at a fixed offset rather than a true centre.
--- Neither can do anything under Wayland, by that compositor's own design --
--- the script still exits cleanly, having simply found nothing to move.
---@param target { x: integer, y: integer, w: integer, h: integer }|nil
---@return string
local function script_linux(target)
  local target_decl = target
      and ("TARGET_X=%d\nTARGET_Y=%d\nTARGET_W=%d\nTARGET_H=%d\n"):format(
        target.x,
        target.y,
        target.w,
        target.h
      )
    or ""
  return ([[
#!/usr/bin/env bash
TIMEOUT_S=6
POLL_S=0.3
%s
have() { command -v "$1" >/dev/null 2>&1; }

deadline=$(( $(date +%%s) + TIMEOUT_S ))

if have xdotool; then
  before="$(xdotool search --onlyvisible . 2>/dev/null)"
  found=""
  while [ "$(date +%%s)" -lt "$deadline" ]; do
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
    if [ -n "${TARGET_W:-}" ]; then
      # A detected monitor, from preview.monitor -- not necessarily screen 0,
      # which is all `getdisplaygeometry` alone would ever answer.
      screen_x="$TARGET_X"; screen_y="$TARGET_Y"; screen_w="$TARGET_W"; screen_h="$TARGET_H"
    else
      geom="$(xdotool getdisplaygeometry 2>/dev/null)"
      screen_x=0; screen_y=0
      screen_w="$(echo "$geom" | awk '{print $1}')"
      screen_h="$(echo "$geom" | awk '{print $2}')"
    fi
    wgeom="$(xdotool getwindowgeometry --shell "$found" 2>/dev/null)"
    win_w="$(echo "$wgeom" | grep '^WIDTH=' | cut -d= -f2)"
    win_h="$(echo "$wgeom" | grep '^HEIGHT=' | cut -d= -f2)"
    if [ -n "$screen_w" ] && [ -n "$win_w" ]; then
      x=$(( screen_x + (screen_w - win_w) / 2 ))
      y=$(( screen_y + (screen_h - win_h) / 2 ))
      [ "$x" -lt "$screen_x" ] && x=$screen_x
      [ "$y" -lt "$screen_y" ] && y=$screen_y
      xdotool windowmove "$found" "$x" "$y" 2>/dev/null
      xdotool windowactivate "$found" 2>/dev/null
    fi
  fi
elif have wmctrl; then
  before="$(wmctrl -l 2>/dev/null | awk '{print $1}')"
  found=""
  while [ "$(date +%%s)" -lt "$deadline" ]; do
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
    # No size query in wmctrl alone: a fixed offset from the target's
    # top-left corner (or 100,100 on screen 0 without one), not a true centre.
    off_x=$(( ${TARGET_X:-0} + 100 ))
    off_y=$(( ${TARGET_Y:-0} + 100 ))
    wmctrl -ir "$found" -e 0,"$off_x","$off_y",-1,-1 2>/dev/null
    wmctrl -ia "$found" 2>/dev/null
  fi
fi
exit 0
]]):format(target_decl)
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

  -- Which monitor the terminal is on right now -- the same fact
  -- `preview.window` asks `preview.monitor` for, so mpv and the system
  -- player centre in the same place rather than one of them defaulting to
  -- whichever screen this script happens to run on.
  local ok_mon, monitor = pcall(require, "hover.preview.monitor")
  local detected
  if ok_mon and type(monitor) == "table" and type(monitor.detect) == "function" then
    local ok_detect, result = pcall(monitor.detect)
    detected = ok_detect and result or nil
  end
  local target = detected and { x = detected.x, y = detected.y, w = detected.w, h = detected.h }
    or nil

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

  local content
  if platform == "windows" then
    content = script_windows()
  elseif platform == "macos" then
    content = script_macos(target)
  else
    content = script_linux(target)
  end

  local path = vim.fn.stdpath("cache") .. "/hover_align_video_window" .. ext
  local fd = io.open(path, "w")
  if not fd then
    return
  end
  fd:write(content)
  fd:close()

  argv[#argv + 1] = path
  if platform == "windows" and target then
    -- macOS/Linux bake the target into the generated script text (no PID or
    -- CLI-arg passing needed there); PowerShell's own `param()` block takes
    -- it as real arguments instead.
    argv[#argv + 1] = "-TargetX"
    argv[#argv + 1] = tostring(target.x)
    argv[#argv + 1] = "-TargetY"
    argv[#argv + 1] = tostring(target.y)
    argv[#argv + 1] = "-TargetW"
    argv[#argv + 1] = tostring(target.w)
    argv[#argv + 1] = "-TargetH"
    argv[#argv + 1] = tostring(target.h)
  end
  -- No `detach = true`: measured 2026-09-09 on Windows, a detached
  -- `vim.system` call here did not survive to actually run the poll --
  -- plain `vim.system` (async, no `:wait()`) already does not block the
  -- editor, which is the only thing detaching was for in the first place.
  pcall(vim.system, argv, {})
end

return M
