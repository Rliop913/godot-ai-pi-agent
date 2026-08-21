@tool
extends McpClient


func _init() -> void:
	id = "pi"
	display_name = "Pi Agent"
	config_type = "json"
	# pi-codemode-mcp reads MCP server definitions from ~/.pi/agent/mcp.json
	# (first merge tier; ~/.pi/agent/.mcp.json, .pi/mcp.json, and
	# .mcp.json merge after, project-scope last). Documented at
	# github.com/mitsuhiko/pi-codemode-mcp README "Configuration files"
	# section. Windows path mirrors antigravity's $USERPROFILE choice so
	# the descriptor round-trips on every supported platform.
	path_template = {
		"unix": "~/.pi/agent/mcp.json",
		"windows": "$USERPROFILE/.pi/agent/mcp.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_url_field = "url"
	# No transport pin: pi-codemode-mcp infers stdio vs http from key
	# presence (command vs url). Pinning a `type` discriminator would
	# mismatch the loader and is the exact mistake OpenCode makes on its
	# own `type: "local"` field; antigravity is the closer analog.
	entry_extra_fields = {}
	entry_initial_fields = {}
	# Attach migration (#838). Pi stdio entries are flat command/args/env
	# with no type discriminator (mirrors antigravity's typeless shape).
	# Legacy URL entries carry `url` and optionally `headers`; a `type`
	# key from a previous http-era migration must not survive next to a
	# command — Configure would otherwise hand pi an entry that infers
	# the wrong transport.
	command_shape = McpClient.CommandShape.FLAT
	command_legacy_keys = PackedStringArray(["url", "headers", "type"])
	# `env` is the only user-mutable field pi's docs surface. Future
	# fields still survive — the strategy deep-copies unknown keys.
	command_user_fields = PackedStringArray(["env"])
	# Pi's loader also accepts pure-URL entries (the example mcp.json in
	# the pi-codemode-mcp repo ships stdio + URL entries side-by-side).
	# Keep the manual-instruction URL fallback alive.
	command_supports_url_fallback = true
	# ~/.pi/agent/mcp.json is created by the first pi launch, so its
	# presence is the strongest install signal. Mirror antigravity's
	# `detect_paths = path_template.values()` pattern so the dock shows
	# the installed badge before Configure has run.
	detect_paths = PackedStringArray(path_template.values())