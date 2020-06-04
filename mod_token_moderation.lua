-- Token moderation
-- This module looks for a field on incoming JWT tokens called "moderator".
-- If it is true the user is added to the room as a moderator, otherwise they are set to a normal user.
local is_admin = require "core.usermanager".is_admin;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local http = require "net.http";
local json = require "cjson";
local basexx = require "basexx";

-- This is a plugin for the MUC module.
local mod_muc = module:depends("muc");

-- log() shows logs as "general". module:log() shows it as the MUC module.
module:log("info", "Loading token moderation plugin...");

local notification_url = module:get_option_string("muc_room_notification_url", nil);

if (notification_url) then
	module:log("info", "Push notifications to %s are enabled.", notification_url);
else
	module:log("info", "Missing configuration parameter: muc_room_notification_url. Push notifications are disabled.");
end;

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

local function send_notification(post_url, id, nick, email, room, action, token)
	http.request(post_url, {
		insecure = true;
		headers = {
				["Content-Type"] = "application/json";
		};
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
		-- If user is a moderator, set their affiliation to be an owner
		if body["moderator"] == true then
			room:set_affiliation("token_plugin", jid_bare(stanza.attr.from), "owner");
		else
			room:set_affiliation("token_plugin", jid_bare(stanza.attr.from), "member");
		end;
	end;
end;

function occupantJoin(event)
	local session = event.origin;
	-- local stanza = event.stanza;
	-- local session = prosody.full_sessions[stanza.attr.from];
	local room = event.room;
	local room_name = jid_split(event.nick);
	-- local room_name = session.jitsi_meet_room;
	local occupant = event.occupant;
	local nick = nil;
	local email = nil;
	local role = nil;
	local id = nil;
	if session then
		local body = extractBodyFromToken(session.auth_token);
		if body then
			id = body["sub"];
			nick = body["context"]["user"]["name"];
			email = body["context"]["user"]["email"];
		end;
	end;
	if occupant then
		role = occupant.role;
	end;
	if nick and email then
		module:log("info", "%s <%s> joined the room %s as %s.", nick, email, room_name, role);
		if (notification_url) then
			send_notification(notification_url, id, nick, email, room_name, "join", session.auth_token);
		end;
	end;
end;

function occupantLeft(event)
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
			id = body["sub"];
			nick = body["context"]["user"]["name"];
			email = body["context"]["user"]["email"];
		end;
	end;
	if nick and email then
		module:log("info", "%s <%s> left the room %s.", nick, email, room_name);
		if (notification_url) then
			send_notification(notification_url, id, nick, email, room_name, "leave", session.auth_token);
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
		if(is_admin(actor)) then
			return _set_affiliation(room, actor, jid, affiliation, reason);
		end;
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

module:log("info", "Initialization completed.");
