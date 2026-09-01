std = "luajit"
cache = true

-- "vim" itself is mutable (plugins assign vim.g.* freely), so it must live in
-- `globals`, not `read_globals`.
globals = {
  "vim",
}

exclude_files = {
  "TESTS/*.lua",
}

-- Long lines are handled by stylua's column_width; don't duplicate the check.
max_line_length = false
