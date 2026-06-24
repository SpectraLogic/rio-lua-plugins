-- luacheck configuration for Rio plugins.
-- The Rio host runs LuaJIT and injects the globals below into every plugin's
-- environment. Declaring them as read_globals stops luacheck flagging them as
-- undefined / accidentally-global.

std = "luajit"

read_globals = {
    "rio",              -- host bridge object (rio:log_info, rio:save_metadata, ...)
    "input",            -- full path to the source file
    "input_name",       -- documented alias for the source path
    "input_path",       -- alias used by some runners/plugins
    "output_path",      -- temp cache dir, cleaned up on completion
    "pludin_dir",       -- plugin diectory (useful for finding libs and imports)
    "output_directory", -- alias used by older plugins
    "json",             -- some plugins still reference json as a global
}
