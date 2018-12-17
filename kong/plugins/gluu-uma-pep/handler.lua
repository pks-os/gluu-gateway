local BasePlugin = require "kong.plugins.base_plugin"
local access = require "kong.plugins.gluu-uma-pep.access"

local handler = BasePlugin:extend()
handler.PRIORITY = 998

-- Your plugin handler's constructor. If you are extending the
-- Base Plugin handler, it's only role is to instanciate itself
-- with a name. The name is your plugin name as it will be printed in the logs.
function handler:new()
  handler.super.new(self, "gluu-uma-pep")

  local name_prefix = "gluu_uma_"
  self.metric_client_authenticated = name_prefix .. "client_authenticated"
  self.metric_client_granted = name_prefix .. "client_granted"

    -- access token should be per plugin instance
  self.access_token = { expire = 0 }
end

function handler:access(config)
  -- Eventually, execute the parent implementation
  -- (will log that your plugin is entering this context)
  handler.super.access(self)

  return access(self, config)
end

return handler
