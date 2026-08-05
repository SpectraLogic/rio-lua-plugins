plugin = {}

function plugin.execute()
    rio:save_technical_metadata({ author = 'test' })
    rio:save_status("COMPLETED", nil)
end
