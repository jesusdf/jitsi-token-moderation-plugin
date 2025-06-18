
# jitsi-token-moderation-plugin
Lua plugin for jitsi which determines whether users are moderator or not based on token contents.
It also supports sending a push notification when a user joins or leaves a room.

## TODO
- Usage of legacy is_admin() API, which will be disabled in a future build. See https://prosody.im/doc/developers/permissions about the new permissions API.

## Installation
- Put the lua file somewhere on your jitsi server`
- Open `/etc/prosody/conf.d/[YOUR DOMAIN].cfg.lua`
- at the very top of the file in **plugin_paths** after **"/usr/share/jitsi-meet/prosody-plugins/"** add `, "[DIRECTORY INTO WHICH YOU PUT THE MOD LUA]"`
- edit the conferance.[YOUR DOMAIN] component to add **token_moderation**
  - Change this line `modules_enabled = { [EXISTING MODULES] }` TO `modules_enabled = { [EXISTING MODULES]; "token_moderation" }`
  - Add a new setting called muc_room_notification_url if you want to receive push notifications of users entering or leaving the room.
- run `prosodyctl restart && /etc/init.d/jicofo restart && /etc/init.d/jitsi-videobridge restart` in bash to restart prosody/jitsi/jicofo


## Installation for Docker-Jitsi-Meet
- Install [Docker-Jitsi-Meet](https://github.com/jitsi/docker-jitsi-meet) per its readme.
- Open the `.env` file, found in the project root. Edit the `XMPP_MUC_MODULES` variable:
```
// Old
XMPP_MUC_MODULES=

// New
XMPP_MUC_MODULES=token_moderation
```
- Open the Prosody Dockerfile: `\prosody\Dockerfile`. Add the following lines under the existing `ADD` command:
```
# Download the file to the Modules folder
ADD https://raw.githubusercontent.com/jesusdf/jitsi-token-moderation-plugin/master/mod_token_moderation.lua /usr/lib/prosody/modules/mod_token_moderation.lua

# Ensure permissions are set correctly.
RUN chmod 644 /usr/lib/prosody/modules/mod_token_moderation.lua
```
- In the command prompt, run `make`
- In Docker Desktop, inspect the prosody container. Ensure there are no errors thrown and that the following console log is present:
`Loaded token moderation plugin`

## Usage
Include a boolean "moderator" field in the body of the JWT you create for Jitsi. If true, the user will be a moderator; if not, they won't. This works regardless of the order in which people join.

Token body should look something like this:
```javascript
{
  "context": {
    "user": {
      "avatar": "https:/gravatar.com/avatar/abc123",
      "name": "User Name",
      "email": "user@domain.com"
    }
  },
  "aud": "MyApp",
  "iss": "MyApp",
  "sub": "meet.jitsi",
  "room": "test-room",
  "moderator": true
}
```

Add a new setting called muc_room_notification_url in your prosody's domain configuration file if you want to receive push notifications of users entering or leaving the room:

```javascript
Component "muc.meet.jitsi" "muc"
    storage = "memory"
    modules_enabled = {
        "token_verification";
        "token-moderation";
    }
    muc_room_locking = false
    muc_room_default_public_jids = true
    muc_room_notification_url = "https://mydomain/api/push"
	muc_room_notification_user = "myuser"
	muc_room_notification_pass = "mypass"
```

You can also specify a user and password to use with HTTP Basic Auth, or leave it blank to make a post without authentication at all.

It will post a JSON with this format:

```javascript
{
	"_id": "",
	"_nick": "",
	"_email": "",
	"_room": "",
	"_action": "",
	"_token": ""
}
```

The field "_id" contains the "sub" token value.
The field "_action" contains either "enter" or "leave".

## License
MIT License

Copyright (c) 2019, Spark Sixty Four Ltd

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
