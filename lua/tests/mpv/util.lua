local util = require("neovimpv.mpv.util")

local link1 = "https://youtu.be/foobar"
local link2 = "https://youtu.be/bazqux"
local link3 = "https://youtu.be/quux"

local success, err

local function assert_equal(msg, a, b)
  if not vim.deep_equal(a, b) then
    error("\nassertion failed: " .. msg .. "\n" .. vim.inspect(a) .. " != " .. vim.inspect(b))
  end
end

-- find_closest_link
(function()
  assert_equal(
    "line with one link",
    { util.find_closest_link(link1, 1) },
    { link1, true }
  )

  assert_equal(
    "line with one link and space padding before",
    { util.find_closest_link(
      (" "):rep(10) .. link1,
      1
    ) },
    { link1, false }
  )

  assert_equal(
    "line with two links, closer to start of first",
    { util.find_closest_link(
      link1 .. (" "):rep(10) .. link2,
      1
    ) },
    { link1, false }
  )

  assert_equal(
    "line with two links, closer to end of first",
    { util.find_closest_link(
      link1 .. (" "):rep(10) .. link2,
      link1:len() + 3
    ) },
    { link1, false }
  )


  assert_equal(
    "line with two links, closer to start of second",
    { util.find_closest_link(
      link1 .. (" "):rep(10) .. link2,
      link1:len() + 7
    ) },
    { link2, false }
  )
end)();

-- links_by_line
(function()
  assert_equal(
    "line with one link",
    { util.links_by_line(link1, 1) },
    { { link1 }, true }
  )

  assert_equal(
    "line with one link with padding before",
    { util.links_by_line((" "):rep(10) .. link1, 1) },
    { { link1 }, false }
  )

  assert_equal(
    "line with two links",
    { util.links_by_line(
      link1 .. " " .. link2,
      1
    ) },
    { { link1, link2 }, false }
  )

  assert_equal(
    "line with two links, starting after first link",
    { util.links_by_line(
      link1 .. " " .. link2,
      2 + link1:len()
    ) },
    { { link2 }, false }
  )

  assert_equal(
    "line with two links, ending before second link",
    { util.links_by_line(
      link1 .. " " .. link2,
      1,
      1 + link1:len()
    ) },
    { { link1 }, false }
  )

  assert_equal(
    "line with two links, ending before second link",
    { util.links_by_line(
      link1 .. " " .. link2,
      1,
      1 + link1:len()
    ) },
    { { link1 }, false }
  )

  assert_equal(
    "line with three links",
    { util.links_by_line(
      link1 .. " " .. link2 .. " " .. link3,
      1
    ) },
    { { link1, link2, link3 }, false }
  )
end)()

-- try_markdown
local home_filename = "~/.local/foo"
local relative_filename = "foo"
local absolute_filename = "/bin/cat"

vim.fn.writefile({}, vim.fn.expand(home_filename))
vim.fn.writefile({}, relative_filename)
success, err = pcall(function()
  assert_equal(
    "relative path, no markdown",
    util.try_path_and_markdown(relative_filename),
    nil
  )

  assert_equal(
    "home path",
    util.try_path_and_markdown(home_filename),
    vim.fn.expand(home_filename)
  )

  assert_equal(
    "absolute path",
    util.try_path_and_markdown(absolute_filename),
    absolute_filename
  )

  assert_equal(
    "markdown",
    util.try_path_and_markdown("[hello world](" .. relative_filename .. ")"),
    relative_filename
  )
end)
vim.fn.delete(vim.fn.expand(home_filename))
vim.fn.delete(relative_filename)
if not success then error(err) end

-- try_smart_youtube
(function()
  assert_equal(
    "search with implicit first result",
    util.try_smart_youtube("ytdl://ytsearch: test"),
    "paste"
  )

  assert_equal(
    "search with explicit single result",
    util.try_smart_youtube("ytdl://ytsearch1: test"),
    "paste"
  )

  assert_equal(
    "search with explicit multiple results",
    util.try_smart_youtube("ytdl://ytsearch10: test"),
    "new_one"
  )
end)()
