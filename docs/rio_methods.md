# Rio Methods and Values
These are all globally available in plugin scripts: 

## Values
|Value                  |Description                                            |
|-----------------------|-------------------------------------------------------|
|input_name             |Full path to file on streamable media (NAS or S3)      |
|output_path            |Temp space in cache -- will be deleted on completion.  | 

## Methods
|Function                    |Description                                       |
|----------------------------|--------------------------------------------------|
|fun log_debug(s: String)    |Write s to Rio logs as DEBUG                      |
|fun log_info(s: String)     |Write s to Rio logs as INFO                       |
|fun log_warn(s: String)     |Write s to Rio logs as WARNING                    |
|fun log_error(s: String)    |Write s to Rio logs as ERROR                      |
|fun save_metadata(m: Map<String, String>) | Add (or replace) metadata with m   |
|fun register_thumbnail(p: String) |Archive object at path p to Proxy namespace and register as Thumbnail |
|fun register_proxy(p: String) |Archive object at path p to Proxy namespace and register as Proxy |
|fun gpu_exec(c: String)    |Obtain exclusive semaphore and run blocking command c |

## Example
```lua
-- register an object as its own thumbnail
rio:register_thumbnail(input_path)
rio:log_info("Registered: " .. tostring(input path))
```

