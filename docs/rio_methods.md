# Rio Methods and Values
These are all globally available in plugin scripts: 

## Values
|Value                  |Description                                            |
|-----------------------|-------------------------------------------------------|
|input                  |Full path to file on stream-able media (NAS or S3)     |
|working_directory      |Temp space in cache -- will be deleted on completion.  |
|settings               |Map of user choices to schema() values                 |

## Methods
|Function                    |Description                                       |
|----------------------------|--------------------------------------------------|
|fun log_debug(s: String)    |Write s to Rio logs as DEBUG                      |
|fun log_info(s: String)     |Write s to Rio logs as INFO                       |
|fun log_warn(s: String)     |Write s to Rio logs as WARNING                    |
|fun log_error(s: String)    |Write s to Rio logs as ERROR                      |
|fun save_transcription(text: String) | Add (or replace) transcription text with text   |
|fun save_ai_metadata(m: Map<String, String>) | Add (or replace) AI metadata with m   |
|fun save__technical_metadata(m: Map<String, String>) | Add (or replace) technical metadata with m   |
|fun register_thumbnail(p: String) |Archive object at path p to Proxy namespace and register as Thumbnail |
|fun register_proxy(p: String) |Archive object at path p to Proxy namespace and register as Proxy |
|fun register_preview(p: String) |Archive object at path p to Proxy namespace and register as Preview |
|fun register_sidecar(p: String) |Archive object at path p to Proxy namespace and register as Sidecar |
|fun product_status(p: String, s: String, m?: String) |Set status s for product p with optional message m |
|fun save_status(s: String, m?: String) |Set queue task status s with optional message m |
|fun gpu_exec(c: String)    |Obtain exclusive semaphore and run blocking command c |

## ENUMs
|                      |Values                                                |
|----------------------|------------------------------------------------------|
|Products              |THUMBNAIL, PREVIEW, SIDECAR, PROXY, TRANSCRIPTION, AI |
|Product statuses      |INITIALIZING, ACTIVE, COMPLETED, FAILURE              |
|Queue task statuses   |PROCESSING, REPROCESSING, COMPLETED, FAILED           |


## Example
```lua
plugin = {}

function plugin.execute()
    rio:save_technical_metadata({ author = 'test' })
    rio:log_info("Processing object: " .. input)
    rio:save_status(rio_utils.get_status_name("completed"), nil)
end
```
