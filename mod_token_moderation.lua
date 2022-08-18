-- Token moderation
-- This module looks for a field on incoming JWT tokens called "moderator".
-- If it is true the user is added to the room as a moderator, otherwise they are set to a normal user.
local is_admin = require "core.usermanager".is_admin;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local timer = require 'util.timer';
local http = require "net.http";
local json = require "cjson";
local basexx = require "basexx";
local um_is_admin = require "core.usermanager".is_admin;

local function is_admin(jid)
        return um_is_admin(jid, module.host);
end

-- This is a plugin for the MUC module.
local mod_muc = module:depends("muc");

local host = module.host;
local parentHostName = string.gmatch(tostring(host), "%w+.(%w.+)")();
if parentHostName == nil then
	log("error", "Failed to start - unable to get parent hostname");
	return;
end

local parentCtx = module:context(parentHostName);
if parentCtx == nil then
	log("error",
		"Failed to start - unable to get parent context for host: %s",
		tostring(parentHostName));
	return;
end

local token_util = module:require "token/util".new(parentCtx);

-- no token configuration
if token_util == nil then
    return;
end

-- log() shows logs as "general". module:log() shows it as the MUC module.
module:log("info", "Loading token moderation plugin...");

local notification_url;
local notification_useragent;
local notification_user;
local notification_pass;
local notification_timeout;
local notification_retry_count;
local notification_retry_delay;

local function load_config()
    notification_url = module:get_option_string("muc_room_notification_url", nil);
	notification_useragent = module:get_option_string("muc_room_notification_useragent", nil);
	notification_user = module:get_option_string("muc_room_notification_user", nil);
	notification_pass = module:get_option_string("muc_room_notification_pass", nil);
	notification_timeout = module:get_option("muc_room_notification_timeout", 10);
	notification_retry_count = module:get_option("muc_room_notification_retry_count", 5);
	notification_retry_delay = module:get_option("muc_room_notification_retry_delay", 1);
	if (notification_url) then
		module:log("info", "Push notifications to %s are enabled.", notification_url);
	else
		module:log("info", "Missing configuration parameter: muc_room_notification_url. Push notifications are disabled.");
	end;
end
load_config();

function extractBodyFromToken(auth_token)
	if auth_token then
			-- Extract token body and decode it
			local dotFirst = auth_token:find("%.");
			if dotFirst then
					local dotSecond = auth_token:sub(dotFirst + 1):find("%.");
					if dotSecond then
							local bodyB64 = auth_token:sub(dotFirst + 1, dotFirst + dotSecond - 1);
							return json.decode(basexx.from_url64(bodyB64));
					end;
			end;
	end;
	return nil;
end;

-- https://github.com/jitsi-contrib/prosody-plugins/blob/main/event_sync/mod_event_sync_component.lua

-- Option for user to control HTTP response codes that will result in a retry.
-- Defaults to returning true on any 5XX code or 0
local notification_should_retry_for_code = module:get_option("notification_should_retry_for_code", function (code)
	return code >= 500;
 end)

--- Start non-blocking HTTP call
-- @param url URL to call
-- @param options options table as expected by net.http where we provide optional headers, body or method.
-- @param callback if provided, called with callback(response_body, response_code) when call complete.
-- @param timeout_callback if provided, called without args when request times out.
-- @param retries how many times to retry on failure; 0 means no retries.
local function async_http_request(url, options, callback, timeout_callback, retries)
    local completed = false;
    local timed_out = false;
    local retries = retries or notification_retry_count;

    local function cb_(response_body, response_code)
        if not timed_out then  -- request completed before timeout
            completed = true;
            if (response_code == 0 or notification_should_retry_for_code(response_code)) and retries > 0 then
                module:log("warn", "Push notification response code %d. Will retry after %ds", response_code, notification_retry_delay);
                timer.add_task(notification_retry_delay, function()
                    async_http_request(url, options, callback, timeout_callback, retries - 1)
                end)
                return;
            end

            module:log("debug", "%s %s returned code %s", options.method, url, response_code);

            if callback then
                callback(response_body, response_code);
            end;
        end;
    end;

    local request = http.request(url, options, cb_);

    timer.add_task(notification_timeout, function ()
        timed_out = true;

        if not completed then
            http.destroy_request(request);
            if timeout_callback then
                timeout_callback();
            end;
        end;
    end);

end;

local function send_notification(post_url, post_useragent, post_user, post_pass, id, nick, email, room, action, token)
	local post_headers = {};
	if (post_useragent) then
		post_headers["User-Agent"] = post_useragent;
	end;
	if (post_user) then
		post_headers["Authorization"] = "Basic " .. basexx.to_base64(post_user .. ":" .. post_pass);
	end;
	post_headers["Content-Type"] = "application/json";

	async_http_request(post_url, {
		method = "POST";
		insecure = true;
		headers = post_headers;
		body = json.encode {
				_id = id;
				_nick = nick;
				_email = email;
				_room = room;
				_action = action;
				_token = token;
		};
	}, function (response, code) --luacheck: ignore 212/response
		module:log("info", "Push notification posted with response code %d: %q", code, response);
	end);
end;

function setupAffiliation(room, origin, stanza)
	local body = extractBodyFromToken(origin.auth_token)
	if body then
		local jid = jid_bare(stanza.attr.from);
		-- If user is a moderator or an admin, set their affiliation to be an owner
		if body["moderator"] == true or is_admin(jid) then
				room:set_affiliation("token_plugin", jid, "owner");
		else
				room:set_affiliation("token_plugin", jid, "member");
		end;
	end;
end;

function occupantJoin(event)
	occupantAction(event, "enter");
end;

function occupantLeft(event)
	occupantAction(event, "leave");
end;

function occupantAction(event, action_name)
	local session = event.origin;
	-- local stanza = event.stanza;
	-- local session = prosody.full_sessions[stanza.attr.from];
	local room = event.room;
	local room_name = jid_split(event.nick);
	-- local room_name = session.jitsi_meet_room;
	-- local occupant = event.occupant;
	local nick = nil;
	local email = nil;
	local role = nil;
	local id = nil;
	if session then
		local body = extractBodyFromToken(session.auth_token);
		if body then
			id = body["contextid"];
			nick = body["context"]["user"]["name"];
			email = body["context"]["user"]["email"];
		end;
	end;
	if nick and email then
		module:log("info", "%s <%s> %s the room %s.", nick, email, action_name, room_name);
		if (notification_url) then
			send_notification(notification_url, notification_useragent, notification_user, notification_pass, id, nick, email, room_name, action_name, session.auth_token);
		end;
	end;
end;

function roomCreated(event)
	local room = event.room;
	local room_name = jid_split(room.jid);
	module:log("info", "Room %s created, adding token moderation hooks.", room_name);
	local _handle_normal_presence = room.handle_normal_presence;
	local _handle_first_presence = room.handle_first_presence;
	-- Wrap presence handlers to set affiliations from token whenever a user joins
	room.handle_normal_presence = function(thisRoom, origin, stanza)
		local pres = _handle_normal_presence(thisRoom, origin, stanza);
		setupAffiliation(thisRoom, origin, stanza);
		return pres;
	end;
	room.handle_first_presence = function(thisRoom, origin, stanza)
		local pres = _handle_first_presence(thisRoom, origin, stanza);
		setupAffiliation(thisRoom, origin, stanza);
		return pres;
	end;
	-- Wrap set affiliation to block anything but token setting owner (stop pesky auto-ownering)
	local _set_affiliation = room.set_affiliation;
	room.set_affiliation = function(room, actor, jid, affiliation, reason)
		-- This plugin has super powers
		if actor == "token_plugin" then
			return _set_affiliation(room, true, jid, affiliation, reason);
		-- Nobody else can assign owner (in order to block prosody/jisti built-in moderation functionality
		elseif affiliation == "owner" then
			return nil, "modify", "not-acceptable"
		-- Keep everything else as is
		else
			return _set_affiliation(room, actor, jid, affiliation, reason);
		end;
	end;
end;

module:hook("muc-room-created", roomCreated);
module:hook("muc-occupant-left", occupantLeft);
module:hook("muc-occupant-joined", occupantJoin);

module:hook_global('config-reloaded', load_config);

module:log("info", "Initialization completed.");
