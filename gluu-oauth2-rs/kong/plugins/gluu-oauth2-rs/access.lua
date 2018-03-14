local helper = require "kong.plugins.gluu-oauth2-rs.helper"
local responses = require "kong.tools.responses"
local singletons = require "kong.singletons"
local ngx_re_gmatch = ngx.re.gmatch
local PLUGINNAME = "gluu-oauth2-rs"
local CLIENT_PLUGIN_NAME = "gluu-oauth2-client-auth"

--- Retrieve a RPT token in the `Authorization` header.
-- @param request ngx request object
-- @param conf Plugin configuration
-- @return RPT token or nil
-- @return err
local function retrieve_token(request)
    local authorization_header = request.get_headers()["authorization"]
    if authorization_header then
        local iterator, iter_err = ngx_re_gmatch(authorization_header, "\\s*[Bb]earer\\s+(.+)")
        if not iterator then
            return nil, iter_err
        end

        local m, err = iterator()
        if err then
            return nil, err
        end

        if m and #m > 0 then
            return m[1]
        end
    end
end

--- Fetch given requested path. Example: /posts
-- @return path
local function getPath()
    local path = ngx.var.request_uri
    ngx.log(ngx.DEBUG, PLUGINNAME .. ": request_uri " .. path)
    local indexOf = string.find(path, "?")
    if indexOf ~= nil then
        return string.sub(path, 1, (indexOf - 1))
    end
    return path
end

--- Check response of /uma-rs-check-access
-- @param umaRSResponse: Full response of uma-rs-check-access command
-- @param rpt: rpt token
-- @param httpMethod: HTTP method
-- @param path: Requested path Example: /posts
--
local function check_uma_rs_response(umaRSResponse, rpt, httpMethod, path)
    if helper.is_empty(umaRSResponse.status) then
        return responses.send_HTTP_FORBIDDEN("UMA Authorization Server Unreachable")
    end

    if umaRSResponse.status == "error" and helper.is_empty(umaRSResponse.data) then
        return responses.send_HTTP_UNAUTHORIZED("Unauthorized")
    elseif umaRSResponse.data.error == "invalid_request" then
        ngx.log(ngx.DEBUG, PLUGINNAME .. ": Path is not protected! - http_method: " .. httpMethod .. ", rpt: " .. (rpt or "nil") .. ", path: " .. path)
        ngx.header["UMA-Warning"] = "Path is not protected by UMA. Please check protection_document."
        return { access = true, isPathProtected = false }
    elseif umaRSResponse.data.error == "internal_error" then
        ngx.log(ngx.DEBUG, PLUGINNAME .. ": Unknown internal server error occurs. Check oxd-server log")
        ngx.status = 500
        ngx.header.content_type = "application/json; charset=utf-8"
        ngx.say([[{ "message": "Unknown internal server error occurs. Check oxd-server log" }]])
        return ngx.exit(500)
    end

    if umaRSResponse.status == "ok" then
        if umaRSResponse.data.access == "granted" then
            return { access = true, isPathProtected = true }
        end

        if umaRSResponse.data.access == "denied" then
            local ticket = umaRSResponse.data.ticket
            if not helper.is_empty(ticket) and not helper.is_empty(umaRSResponse.data["www-authenticate_header"]) then
                ngx.log(ngx.DEBUG, "Set WWW-Authenticate header with ticket")
                ngx.header["WWW-Authenticate"] = umaRSResponse.data["www-authenticate_header"]
                return responses.send_HTTP_UNAUTHORIZED("Unauthorized")
            end

            return responses.send_HTTP_FORBIDDEN("UMA Authorization Server Unreachable")
        end
    end
end

local _M = {}

--- Start execution. Call by handler.lua
-- @param conf: Global configuration oxd_id, client_id and client_secret
-- @return ACCESS GRANTED and Unauthorized
function _M.execute(conf)
    ngx.log(ngx.DEBUG, "Enter in gluu-oauth2-rs plugin")
    local httpMethod = ngx.req.get_method()
    local reqToken = retrieve_token(ngx.req)
    local path = getPath()

    ngx.log(ngx.DEBUG, PLUGINNAME .. ": Access - http_method: " .. httpMethod .. ", reqToken: " .. (reqToken or "nil") .. ", path: " .. path)

    if helper.is_empty(reqToken) then
        ngx.log(ngx.DEBUG, PLUGINNAME .. " : Unauthorized! Token not found in header")
        -- Check access and return permission ticket in header
        local umaRSResponse = helper.check_access(conf, "", path, httpMethod)
        check_uma_rs_response(umaRSResponse, reqToken, httpMethod, path)

        -- Unauthorized! Token not found in header
        return responses.send_HTTP_UNAUTHORIZED("Unauthorized! Token not found in header")
    end

    -- Check RPT token is in gluu-oauth2-rs cache
    local clientPluginCacheToken = singletons.cache:get(reqToken, nil, function() end)

    if helper.is_empty(clientPluginCacheToken) then
        ngx.log(ngx.DEBUG, PLUGINNAME .. " : Unauthorized! gluu-oauth2-client-auth cache is not found")
        return responses.send_HTTP_UNAUTHORIZED("Unauthorized! gluu-oauth2-client-auth cache is not found")
    else
        -- Check Token is already exist with same path and method
        if clientPluginCacheToken.permissions and clientPluginCacheToken.permissions.path == path and clientPluginCacheToken.permissions.method == httpMethod then
            ngx.log(ngx.DEBUG, PLUGINNAME .. ": Token already exist with same path and method")
            --        -- If path is not protected then send header with UMA-Wanrning
            --        if not cacheToken.isPathProtected then
            --            ngx.log(ngx.DEBUG, PLUGINNAME .. ": Path is not protected! - http_method: " .. httpMethod .. ", rpt: " .. (rpt or "nil") .. " ip: " .. ip .. ", path: " .. path)
            --            ngx.header["UMA-Warning"] = "Path is not protected by UMA. Please check protection_document."
            --        end
            return -- ACCESS GRANTED
        end
    end

    ngx.log(ngx.DEBUG, PLUGINNAME .. ": Token not exist with requested path and method")

    -- Get oauth2-consumer credential for getting all modes(oauth_mode, uma_mode, mix_mode) in here.
    local oauth2Credential = singletons.cache:get(singletons.dao.gluu_oauth2_client_auth_credentials:cache_key(clientPluginCacheToken.client_id), nil, function() end)
    ngx.log(ngx.DEBUG, PLUGINNAME .. ": Token type : " .. clientPluginCacheToken.token_type)
    ngx.log(ngx.DEBUG, PLUGINNAME .. ": oauth_mode : " .. tostring(oauth2Credential.oauth_mode) .. ", uma_mode : " .. tostring(oauth2Credential.uma_mode) .. ", mix_mode : " .. tostring(oauth2Credential.mix_mode))

    if clientPluginCacheToken.token_type == "UMA" then
        ngx.log(ngx.DEBUG, PLUGINNAME .. ": Enter in process when token is UMA")
        if oauth2Credential.oauth_mode then
            ngx.log(ngx.DEBUG, PLUGINNAME .. " : 401 Unauthorized. OAuth(not UMA) token required.")
            return responses.send_HTTP_UNAUTHORIZED("Unauthorized")
        end

        -- Check UMA-RS access -> oxd
        local umaRSResponse = helper.check_access(conf, reqToken, path, httpMethod)

        if not umaRSResponse then
            ngx.log(ngx.DEBUG, PLUGINNAME .. " : Failed to access resources. umaRSResponse is false")
            return responses.send_HTTP_FORBIDDEN("Failed to access resources")
        end

        -- Check uma_rs_acceess response
        local checkUMARsResponse = check_uma_rs_response(umaRSResponse, reqToken, httpMethod, path)
        if checkUMARsResponse.access == true then
            -- Update rpt in gluu-oauth2-client-auth plugin
            singletons.cache:invalidate(reqToken)
            clientPluginCacheToken.associated_rpt = umaRSResponse.rpt
            clientPluginCacheToken.permissions = { path = path, method = httpMethod }
            ngx.log(ngx.DEBUG, "RPT token " .. umaRSResponse.rpt)
            singletons.cache:get(reqToken, { ttl = clientPluginCacheToken.exp_sec }, function() return clientPluginCacheToken end)

            -- Set bi-map cache with RPT token
            singletons.cache:invalidate(umaRSResponse.rpt)
            singletons.cache:get(umaRSResponse.rpt, { ttl = clientPluginCacheToken.exp_sec }, function() return clientPluginCacheToken end)
            return -- ACCESS GRANTED
        end

        ngx.log(ngx.DEBUG, PLUGINNAME .. " : Failed to access resources. access is false")
        return responses.send_HTTP_FORBIDDEN("Failed to access resources")
    end

    --- Flow when Token is OAuth
    if clientPluginCacheToken.token_type == "OAuth" then
        ngx.log(ngx.DEBUG, PLUGINNAME .. ": Enter in process when token is OAuth")
        if oauth2Credential.uma_mode then
            ngx.log(ngx.DEBUG, PLUGINNAME .. " : UMA Token required for UMA mode.")
            return responses.send_HTTP_FORBIDDEN("UMA Token required for UMA mode.")
        end

        if oauth2Credential.oauth_mode then
            ngx.log(ngx.DEBUG, PLUGINNAME .. " : Authorized. Allow - OAuth mode")
            return -- Access Granted
        end

        if not oauth2Credential.mix_mode then
            return responses.send_HTTP_FORBIDDEN("Enable anyone mode.")
        end

        -- Check UMA-RS access -> oxd
        local umaRSResponse = helper.get_rpt_with_check_access(conf, path, httpMethod)

        if not umaRSResponse then
            ngx.log(ngx.DEBUG, PLUGINNAME .. " : Failed to access resources. umaRSResponse is false")
            return responses.send_HTTP_FORBIDDEN("Failed to access resources")
        end

        -- Check uma_rs_acceess response
        local checkUMARsResponse = check_uma_rs_response(umaRSResponse, reqToken, httpMethod, path)
        if checkUMARsResponse.access == true then
            -- Update rpt in gluu-oauth2-client-auth plugin
            singletons.cache:invalidate(reqToken)
            clientPluginCacheToken.associated_rpt = umaRSResponse.rpt
            clientPluginCacheToken.permissions = { path = path, method = httpMethod }
            ngx.log(ngx.DEBUG, "RPT token " .. umaRSResponse.rpt)
            singletons.cache:get(reqToken, { ttl = clientPluginCacheToken.exp_sec }, function() return clientPluginCacheToken end)

            -- Set bi-map cache with RPT token
            singletons.cache:invalidate(umaRSResponse.rpt)
            singletons.cache:get(umaRSResponse.rpt, { ttl = clientPluginCacheToken.exp_sec }, function() return clientPluginCacheToken end)
            return -- ACCESS GRANTED
        end

        ngx.log(ngx.DEBUG, PLUGINNAME .. " : Failed to access resources. access is false")
        return responses.send_HTTP_FORBIDDEN("Failed to access resources")
    end

    return responses.send_HTTP_FORBIDDEN("Unknown (unsupported) status code from oxd server for uma_rs_check_access operation.")
end

return _M