-- luacheck configuration for Rio plugins.
-- The Rio host runs LuaJIT and injects the globals below into every plugin's
-- environment. Declaring them as read_globals stops luacheck flagging them as
-- undefined / accidentally-global.

std = "luajit"

read_globals = {
    "rio",              -- host bridge object (rio:log_info, rio:save_techinical_metadata, ...)
    "input",            -- full path to the source file
    "working_directory",-- output workspace (will be deleted upn successful completion)
    "settings"          -- config object passed in with user choices
    "output_directory", -- alias used by older plugins
}
