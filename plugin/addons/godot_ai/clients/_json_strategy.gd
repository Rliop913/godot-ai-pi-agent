@tool
class_name McpJsonStrategy
extends RefCounted

## Read–merge–write strategy for JSON-backed MCP clients.
## All knobs come from the McpClient descriptor as plain data — no Callables.
## See `_base.gd` for why descriptors are data-only.


static func configure(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary = {},
	project_roots: PackedStringArray = PackedStringArray(),
) -> Dictionary:
	if _uses_merge_tiers(client):
		return _configure_merged(client, server_name, server_url, launch, project_roots)
	var resolution := client.resolved_config_path_details()
	var path := str(resolution.get("path", ""))
	var path_error := str(resolution.get("error", ""))
	if not path_error.is_empty():
		return {"status": "error", "message": path_error}
	if path.is_empty():
		return {"status": "error", "message": "Could not resolve config path for %s on this OS" % client.display_name}

	var seed_path := str(resolution.get("seed_path", ""))
	var read_path := seed_path if not FileAccess.file_exists(path) and not seed_path.is_empty() else path
	var read := _read_or_init(read_path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to overwrite %s: %s. Fix or move the file, then re-run Configure." % [read_path, read["error"]]}
	var launch_error := command_launch_error(client, launch)
	if not launch_error.is_empty():
		return {"status": "error", "message": launch_error}
	var config: Dictionary = read["data"]
	var holder := _ensure_path(config, select_server_key_path(config, client))
	## Pass the existing entry through so `build_entry` can preserve user-mutable
	## state (auto-approval lists, `disabled` toggles) instead of resetting it
	## to descriptor defaults on every Configure click. See `entry_initial_fields`
	## docs in `_base.gd`.
	var existing: Variant = holder.get(server_name, null)
	holder[server_name] = build_entry(client, server_url, existing, launch)

	if not McpAtomicWrite.write(path, JSON.stringify(_narrow_integral_numbers(config), "\t", false)):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": McpClient.configured_message(client, server_url)}

## Pi-style clients merge several global config files. Update the effective
## highest-precedence definition; fail closed when a project override exists
## because Pi's external working directory cannot be inferred safely here.
static func _configure_merged(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary,
	project_roots: PackedStringArray,
) -> Dictionary:
	var launch_error := command_launch_error(client, launch)
	if not launch_error.is_empty():
		return {"status": "error", "message": launch_error}
	var project := _load_project_definitions(client, server_name, project_roots)
	if not project.get("ok", false):
		return {"status": "error", "message": str(project.get("error", "Cannot inspect project config tiers"))}
	var project_tiers: Array = project.get("tiers", [])
	if not project_tiers.is_empty():
		return {"status": "error", "message": _project_override_message(project_tiers, "update or remove", client.display_name, server_name)}
	var loaded := _load_merge_tiers(client)
	if not loaded.get("ok", false):
		return {"status": "error", "message": str(loaded.get("error", "Cannot read merged config tiers"))}
	var tiers: Array = loaded.get("tiers", [])
	if tiers.is_empty():
		return {"status": "error", "message": "Could not resolve config path for %s on this OS" % client.display_name}
	var target_index := 0
	for index in range(tiers.size()):
		var config: Dictionary = tiers[index]["data"]
		var holder := _walk_path(config, select_server_key_path(config, client))
		if holder is Dictionary and holder.has(server_name):
			target_index = index
	var tier: Dictionary = tiers[target_index]
	var config: Dictionary = tier["data"]
	var holder := _ensure_path(config, select_server_key_path(config, client))
	var existing: Variant = holder.get(server_name, null)
	holder[server_name] = build_entry(client, server_url, existing, launch)
	var path := str(tier["path"])
	if not McpAtomicWrite.write(path, JSON.stringify(_narrow_integral_numbers(config), "\t", false)):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": McpClient.configured_message(client, server_url)}


static func check_status(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary = {},
	project_roots: PackedStringArray = PackedStringArray(),
) -> McpClient.Status:
	return check_status_details(client, server_name, server_url, launch, project_roots).get("status", McpClient.Status.NOT_CONFIGURED)


## Detailed variant feeding the dock's error_msg plumbing (#711): a config
## file that EXISTS but can't be read or parsed is Status.ERROR carrying the
## read/parse error, not NOT_CONFIGURED — the write path refuses to touch
## such a file (see `_read_or_init`), so the status dot must say "broken
## file", not "click Configure".
static func check_status_details(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary = {},
	project_roots: PackedStringArray = PackedStringArray(),
) -> Dictionary:
	if _uses_merge_tiers(client):
		return _check_status_merged(client, server_name, server_url, launch, project_roots)
	var resolution := client.resolved_config_path_details()
	var path := str(resolution.get("path", ""))
	var path_error := str(resolution.get("error", ""))
	if not path_error.is_empty():
		return {"status": McpClient.Status.ERROR, "error_msg": path_error}
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	var read := _read_or_init(path)
	if not read["ok"]:
		return {"status": McpClient.Status.ERROR, "error_msg": String(read["error"])}
	var config: Dictionary = read["data"]
	var holder := _walk_path(config, select_server_key_path(config, client))
	if not (holder is Dictionary) or not holder.has(server_name):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	return _entry_status_details(client, holder[server_name], server_url, launch)


## Verify the effective last definition after applying the client's merge order.
static func _check_status_merged(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary,
	project_roots: PackedStringArray,
) -> Dictionary:
	var loaded := _load_merge_tiers(client)
	if not loaded.get("ok", false):
		return {"status": McpClient.Status.ERROR, "error_msg": str(loaded.get("error", "Cannot read merged config tiers"))}
	var effective: Variant = null
	for tier in loaded.get("tiers", []):
		var config: Dictionary = tier["data"]
		var holder := _walk_path(config, select_server_key_path(config, client))
		if holder is Dictionary and holder.has(server_name):
			effective = holder[server_name]
	var project := _load_project_definitions(client, server_name, project_roots)
	if not project.get("ok", false):
		return {"status": McpClient.Status.ERROR, "error_msg": str(project.get("error", "Cannot inspect project config tiers"))}
	var project_tiers: Array = project.get("tiers", [])
	if not project_tiers.is_empty():
		for project_tier in project_tiers:
			var details := _entry_status_details(client, project_tier["entry"], server_url, launch)
			if details.get("status") != McpClient.Status.CONFIGURED:
				return {"status": McpClient.Status.CONFIGURED_MISMATCH, "error_msg": _project_override_message(project_tiers, "update or remove", client.display_name, server_name)}
		return {"status": McpClient.Status.CONFIGURED, "error_msg": ""}
	if effective == null:
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	return _entry_status_details(client, effective, server_url, launch)


static func _entry_status_details(
	client: McpClient,
	entry: Variant,
	server_url: String,
	launch: Dictionary,
) -> Dictionary:
	if not (entry is Dictionary):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	var launch_error := command_launch_error(client, launch)
	if not launch_error.is_empty():
		return {"status": McpClient.Status.ERROR, "error_msg": launch_error}
	if verify_entry(client, entry, server_url, launch):
		return {"status": McpClient.Status.CONFIGURED, "error_msg": ""}
	return {"status": McpClient.Status.CONFIGURED_MISMATCH, "error_msg": ""}


static func remove(
	client: McpClient,
	server_name: String,
	project_roots: PackedStringArray = PackedStringArray(),
) -> Dictionary:
	if _uses_merge_tiers(client):
		return _remove_merged(client, server_name, project_roots)
	var resolution := client.resolved_config_path_details()
	var path := str(resolution.get("path", ""))
	var path_error := str(resolution.get("error", ""))
	if not path_error.is_empty():
		return {"status": "error", "message": path_error}
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"status": "ok", "message": "Not configured"}
	var read := _read_or_init(path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to rewrite %s: %s." % [path, read["error"]]}
	var config: Dictionary = read["data"]
	var holder := _walk_path(config, select_server_key_path(config, client))
	if holder is Dictionary and holder.has(server_name):
		holder.erase(server_name)
		if not McpAtomicWrite.write(path, JSON.stringify(_narrow_integral_numbers(config), "\t", false)):
			return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configuration removed" % client.display_name}


static func _remove_merged(
	client: McpClient, server_name: String, project_roots: PackedStringArray
) -> Dictionary:
	var project := _load_project_definitions(client, server_name, project_roots)
	if not project.get("ok", false):
		return {"status": "error", "message": str(project.get("error", "Cannot inspect project config tiers"))}
	var project_tiers: Array = project.get("tiers", [])
	if not project_tiers.is_empty():
		return {"status": "error", "message": _project_override_message(project_tiers, "remove", client.display_name, server_name)}
	var loaded := _load_merge_tiers(client)
	if not loaded.get("ok", false):
		return {"status": "error", "message": str(loaded.get("error", "Cannot read merged config tiers"))}
	var writes: Array[Dictionary] = []
	for tier in loaded.get("tiers", []):
		if not tier.get("exists", false):
			continue
		var config: Dictionary = tier["data"]
		var holder := _walk_path(config, select_server_key_path(config, client))
		if holder is Dictionary and holder.has(server_name):
			holder.erase(server_name)
			writes.append({
				"path": tier["path"],
				"text": JSON.stringify(_narrow_integral_numbers(config), "\t", false),
				"original_text": tier["original_text"],
			})
	if writes.is_empty():
		return {"status": "ok", "message": "Not configured"}
	var written := _write_transaction(writes)
	if not written.get("ok", false):
		return {"status": "error", "message": written.get("error", "Cannot remove merged configuration")}
	return {"status": "ok", "message": "%s configuration removed" % client.display_name}


## Synthesize the entry dict the strategy writes under
## `server_key_path[server_name]`. Both URL and command entries deep-copy the
## existing dict before overwriting strategy-owned fields, preserving unknown
## client additions as well as descriptor-documented user fields.
static func build_entry(
	client: McpClient,
	server_url: String,
	existing: Variant = null,
	launch: Dictionary = {},
) -> Dictionary:
	if _is_supported_command_shape(client.command_shape):
		var command_entry: Dictionary = (existing as Dictionary).duplicate(true) if existing is Dictionary else {}
		if client.command_shape == McpClient.CommandShape.COMMAND_ARRAY:
			## OpenCode-style: the entry's `command` field IS the argv array.
			## A stale sibling `args` from a FLAT-style hand edit would be
			## ambiguous next to it, so it is strategy-owned and removed.
			command_entry["command"] = _launch_argv(launch)
			command_entry.erase("args")
		else:
			command_entry["command"] = str(launch.get("command", ""))
			command_entry["args"] = _array_copy(launch.get("args", []))
		if not client.command_transport_key.is_empty():
			command_entry[client.command_transport_key] = client.command_transport_value
		for key in client.command_initial_fields:
			if not command_entry.has(key):
				command_entry[key] = client.command_initial_fields[key]
		for key in client.command_legacy_keys:
			command_entry.erase(String(key))
		_remove_legacy_env_keys(command_entry, client.command_env_legacy_keys)
		return command_entry
	if client.command_shape != McpClient.CommandShape.NONE:
		return {}
	return build_url_entry(client, server_url, existing)


static func build_url_entry(client: McpClient, server_url: String, existing: Variant = null) -> Dictionary:
	var entry: Dictionary = (existing as Dictionary).duplicate(true) if existing is Dictionary else {}
	entry[client.entry_url_field] = server_url
	for k in client.entry_extra_fields:
		entry[k] = client.entry_extra_fields[k]
	for k in client.entry_initial_fields:
		if not entry.has(k):
			entry[k] = client.entry_initial_fields[k]
	return entry


## Default verifier for a stored entry. Command entries must match every
## launch-affecting value exactly; legacy URL or env keys are migration drift.
## For URL clients, assert `entry[entry_url_field] == url` AND every
## key in `entry_extra_fields` matches verbatim. Type-pinning for Cline /
## Roo / Kilo (`type: "streamable-http"` etc.) falls out of this — pre-fix
## entries that lack the type field fail verification and surface as drift.
static func verify_entry(
	client: McpClient,
	entry: Dictionary,
	server_url: String,
	launch: Dictionary = {},
) -> bool:
	if client.command_shape != McpClient.CommandShape.NONE:
		if not _is_supported_command_shape(client.command_shape) or not bool(launch.get("ok", false)):
			return false
		for key in client.command_legacy_keys:
			if entry.has(String(key)):
				return false
		var env = entry.get("env", null)
		if env is Dictionary:
			for key in client.command_env_legacy_keys:
				if env.has(String(key)):
					return false
		if client.command_shape == McpClient.CommandShape.COMMAND_ARRAY:
			if not _arrays_equal(entry.get("command", null), _launch_argv(launch)):
				return false
			if entry.has("args"):
				return false
		else:
			if entry.get("command") != launch.get("command"):
				return false
			if not _arrays_equal(entry.get("args", null), launch.get("args", null)):
				return false
		if not client.command_transport_key.is_empty():
			if not entry.has(client.command_transport_key):
				return false
			if entry.get(client.command_transport_key) != client.command_transport_value:
				return false
		return true
	if entry.get(client.entry_url_field, "") != server_url:
		return false
	for k in client.entry_extra_fields:
		if entry.get(k) != client.entry_extra_fields[k]:
			return false
	return true


static func command_launch_error(client: McpClient, launch: Dictionary) -> String:
	if client.command_shape == McpClient.CommandShape.NONE:
		return ""
	if not _is_supported_command_shape(client.command_shape):
		return "%s uses a command shape not supported by JSON yet" % client.display_name
	if not bool(launch.get("ok", false)):
		return str(launch.get("error", "No compatible attach launcher was found."))
	return ""


static func _is_supported_command_shape(shape: McpClient.CommandShape) -> bool:
	return shape == McpClient.CommandShape.FLAT or shape == McpClient.CommandShape.COMMAND_ARRAY


## The full launch argv as one array: launcher path followed by every arg.
static func _launch_argv(launch: Dictionary) -> Array:
	var argv: Array = [str(launch.get("command", ""))]
	argv.append_array(_array_copy(launch.get("args", [])))
	return argv


static func _remove_legacy_env_keys(entry: Dictionary, legacy_keys: PackedStringArray) -> void:
	if legacy_keys.is_empty():
		return
	var existing_env = entry.get("env", null)
	if not (existing_env is Dictionary):
		return
	var env: Dictionary = (existing_env as Dictionary).duplicate(true)
	for key in legacy_keys:
		env.erase(String(key))
	if env.is_empty():
		entry.erase("env")
	else:
		entry["env"] = env


static func _array_copy(value: Variant) -> Array:
	if value is Array:
		return (value as Array).duplicate(true)
	if value is PackedStringArray:
		return McpClient._array_from_packed(value)
	return []


static func _arrays_equal(left: Variant, right: Variant) -> bool:
	if not (left is Array or left is PackedStringArray):
		return false
	if not (right is Array or right is PackedStringArray):
		return false
	var left_array := _array_copy(left)
	var right_array := _array_copy(right)
	if left_array.size() != right_array.size():
		return false
	for i in range(left_array.size()):
		if left_array[i] != right_array[i]:
			return false
	return true


## Read a config file once and parse the captured text. Returns
## {"exists": bool, "ok": bool, "data": Dictionary, "original_text": String}
## when the file is absent or parses cleanly, and
## {"exists": true, "ok": false, "error": String, "original_text": String}
## when the file exists with non-empty content we cannot safely round-trip.
## Callers must NOT treat the error path as an empty config — doing so blows
## away the user's other MCP entries on the next write. The `original_text`
## is the exact captured source so transactional rollback can restore
## byte-for-byte; the UTF-8 BOM is stripped only from the parsing copy.
static func _read_file_text(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"exists": false, "ok": true, "data": {}, "original_text": ""}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		var open_err := FileAccess.get_open_error()
		return {"exists": true, "ok": false, "error": "could not open for reading (error %d)" % open_err, "original_text": ""}
	var content := file.get_as_text()
	file.close()
	if content.strip_edges().is_empty():
		return {"exists": true, "ok": true, "data": {}, "original_text": content}
	var parse_copy := content
	# Strip a UTF-8 BOM if present — some editors (notably on Windows) save
	# JSON with a leading ﻿, which Godot's JSON.parse rejects outright.
	# Previously this landed on the "unparseable → wipe" path.
	if parse_copy.begins_with("﻿"):
		parse_copy = parse_copy.substr(1)
	var json := JSON.new()
	if json.parse(parse_copy) != OK:
		var msg := "JSON parse error on line %d: %s" % [json.get_error_line(), json.get_error_message()]
		push_warning("MCP | %s in %s" % [msg, path])
		return {"exists": true, "ok": false, "error": msg, "original_text": content}
	if not (json.data is Dictionary):
		return {"exists": true, "ok": false, "error": "top-level value is %s, expected object" % type_string(typeof(json.data)), "original_text": content}
	return {"exists": true, "ok": true, "data": json.data, "original_text": content}


## Returns {"ok": true, "data": Dictionary} when the file is absent or parses
## cleanly, and {"ok": false, "error": String} when the file exists with
## non-empty content we cannot safely round-trip. Callers must NOT fall back
## to an empty dict on the error path — doing so blows away the user's other
## MCP entries on the next write.
static func _read_or_init(path: String) -> Dictionary:
	var read := _read_file_text(path)
	var result: Dictionary = {"ok": read.get("ok", false), "data": read.get("data", {})}
	if not result.get("ok", false):
		result["error"] = read.get("error", "")
	return result


## Walk a key path, creating intermediate Dicts as needed. Returns the leaf Dict.
static func _ensure_path(root: Dictionary, key_path: PackedStringArray) -> Dictionary:
	var cur := root
	for key in key_path:
		var next = cur.get(key)
		if not (next is Dictionary):
			next = {}
			cur[key] = next
		cur = next
	return cur


## Walk a key path, returning the leaf Dict if all hops exist; else null.
static func _walk_path(root: Dictionary, key_path: PackedStringArray) -> Variant:
	var cur: Variant = root
	for key in key_path:
		if not (cur is Dictionary) or not cur.has(key):
			return null
		cur = cur[key]
	return cur


## Match clients that accept multiple server-map keys without creating a
## higher-precedence canonical map that shadows an existing legacy map. A
## non-null scalar still wins, matching nullish-coalescing parsers; Configure's
## `_ensure_path` then repairs it using the strategy's existing behavior.
static func select_server_key_path(root: Dictionary, client: McpClient) -> PackedStringArray:
	var candidates: Array[PackedStringArray] = [client.server_key_path]
	# Dynamic access keeps mixed-snapshot self-updates parse-safe when a new
	# strategy is briefly loaded with an older McpClient base (#398/#736).
	var aliases = client.get("server_key_path_aliases")
	if aliases is Array:
		for alias in aliases:
			if alias is PackedStringArray:
				candidates.append(alias)
	for key_path in candidates:
		if _walk_path(root, key_path) != null:
			return key_path
	return client.server_key_path


static func _uses_merge_tiers(client: McpClient) -> bool:
	var templates = client.get("config_merge_path_templates")
	return templates is Dictionary and not templates.is_empty()


## Resolve the global config tiers in the client's documented merge order.
static func _merge_paths(client: McpClient) -> PackedStringArray:
	var result := PackedStringArray()
	var templates = client.get("config_merge_path_templates")
	if templates is Dictionary:
		var platform_key := McpPathTemplate.platform_key(templates)
		if not platform_key.is_empty():
			var raw_paths: Variant = templates.get(platform_key, [])
			if raw_paths is Array or raw_paths is PackedStringArray:
				for template in raw_paths:
					var path := McpPathTemplate.expand(str(template)).simplify_path()
					if not path.is_empty() and not result.has(path):
						result.append(path)
	return result


## Pi's project tiers are relative to Pi's process cwd, not Godot's. Inspect
## plausible roots only to detect overrides; callers fail closed rather than
## mutating both guesses.
static func _project_candidate_paths(
	client: McpClient, roots: PackedStringArray
) -> PackedStringArray:
	var result := PackedStringArray()
	var project_paths = client.get("config_merge_project_paths")
	if not (project_paths is PackedStringArray):
		return result
	for project_path in project_paths:
		var absolute_path := String(project_path).simplify_path()
		if absolute_path.is_absolute_path() and FileAccess.file_exists(absolute_path) and not result.has(absolute_path):
			result.append(absolute_path)
	for root in roots:
		if String(root).is_empty():
			continue
		for relative_path in project_paths:
			if String(relative_path).is_absolute_path():
				continue
			var path := String(root).path_join(String(relative_path)).simplify_path()
			if FileAccess.file_exists(path) and not result.has(path):
				result.append(path)
	return result


static func _load_project_definitions(
	client: McpClient, server_name: String, project_roots: PackedStringArray
) -> Dictionary:
	var tiers: Array[Dictionary] = []
	for path in _project_candidate_paths(client, project_roots):
		var read := _read_or_init(path)
		if not read.get("ok", false):
			return {"ok": false, "error": "Cannot inspect project config %s: %s" % [path, read.get("error", "invalid JSON")]}
		var config: Dictionary = read["data"]
		var key_path := select_server_key_path(config, client)
		var holder := _walk_path(config, key_path)
		if holder is Dictionary and holder.has(server_name):
			tiers.append({
				"path": path,
				"data": config,
				"key_path": key_path,
				"entry": holder[server_name],
			})
	return {"ok": true, "tiers": tiers}


static func _project_override_message(
	tiers: Array, action: String, client_name: String, server_name: String
) -> String:
	var paths := PackedStringArray()
	for tier in tiers:
		paths.append(str(tier["path"]))
	return "%s project config overrides %s at %s. %s resolves project files from its own working directory, so the dock cannot safely choose one; %s the entry manually." % [client_name, server_name, ", ".join(paths), client_name, action]


static func _load_merge_tiers(client: McpClient) -> Dictionary:
	var tiers: Array[Dictionary] = []
	for path in _merge_paths(client):
		var read := _read_file_text(path)
		if not read.get("ok", false):
			return {
				"ok": false,
				"error": "Refusing to rewrite %s: %s. Fix or move the file, then re-run Configure." % [path, read.get("error", "invalid JSON")],
			}
		tiers.append({
			"path": path,
			"exists": read.get("exists", false),
			"original_text": read.get("original_text", ""),
			"data": read.get("data", {}),
		})
	return {"ok": true, "tiers": tiers}


## Commit a multi-file removal with best-effort rollback. Each individual write
## is atomic; this layer restores earlier tiers if a later commit fails.
static func _write_transaction(writes: Array[Dictionary]) -> Dictionary:
	var completed: Array[Dictionary] = []
	for write in writes:
		var path := str(write["path"])
		if McpAtomicWrite.write(path, str(write["text"])):
			completed.append(write)
			continue
		var rollback_failed := PackedStringArray()
		completed.reverse()
		for previous in completed:
			if not McpAtomicWrite.write(str(previous["path"]), str(previous["original_text"])):
				rollback_failed.append(str(previous["path"]))
		var suffix := ""
		if not rollback_failed.is_empty():
			suffix = " Rollback also failed for: %s" % ", ".join(rollback_failed)
		return {"ok": false, "error": "Cannot write to %s; earlier tier changes were rolled back.%s" % [path, suffix]}
	return {"ok": true}


## Pick the file and top-level map shown by the manual JSON instructions using
## the same merge and alias precedence as automatic Configure.
static func manual_target_details(
	client: McpClient,
	server_name: String,
	fallback_path: String,
	project_roots: PackedStringArray = PackedStringArray(),
) -> Dictionary:
	if _uses_merge_tiers(client):
		var project := _load_project_definitions(client, server_name, project_roots)
		if not project.get("ok", false):
			return {"ok": false, "error": project.get("error", "Cannot inspect project config tiers")}
		var project_tiers: Array = project.get("tiers", [])
		if project_tiers.size() > 1:
			return {"ok": false, "error": _project_override_message(project_tiers, "update or remove", client.display_name, server_name)}
		if project_tiers.size() == 1:
			var selected_project: Dictionary = project_tiers[0]
			return {
				"ok": true,
				"path": selected_project["path"],
				"key_path": selected_project["key_path"],
			}
		var loaded := _load_merge_tiers(client)
		if not loaded.get("ok", false):
			return {"ok": false, "error": loaded.get("error", "Cannot read merged config tiers")}
		var tiers: Array = loaded.get("tiers", [])
		var selected: Variant = tiers[0] if not tiers.is_empty() else null
		for tier in tiers:
			var config: Dictionary = tier["data"]
			var holder := _walk_path(config, select_server_key_path(config, client))
			if holder is Dictionary and holder.has(server_name):
				selected = tier
		if selected != null:
			var config: Dictionary = selected["data"]
			return {
				"ok": true,
				"path": selected["path"],
				"key_path": select_server_key_path(config, client),
			}
	var read := _read_or_init(fallback_path)
	if not read.get("ok", false):
		return {"ok": false, "error": "Cannot inspect %s: %s" % [fallback_path, read.get("error", "invalid JSON")]}
	return {
		"ok": true,
		"path": fallback_path,
		"key_path": select_server_key_path(read["data"], client),
	}


## Godot's JSON.parse turns every JSON number into a float, so a later
## JSON.stringify re-emits the user's integer fields as "8080.0" — which strict
## consumers (Go's encoding/json into an int field, etc.) reject, and which
## needlessly rewrites every number across the user's *other* entries. Re-narrow
## exactly-representable integral floats back to int so they serialize without
## the ".0". Walks dicts/arrays in place and returns the (same) value.
##
## Integers above 2^53 already lost precision when Godot parsed them to double,
## so they're left as the float Godot produced rather than faking exactness —
## byte-perfect preservation would require not parsing the file at all, and such
## magnitudes don't occur in MCP client configs.
static func _narrow_integral_numbers(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			if is_finite(value) and value == floor(value) and absf(value) <= 9007199254740992.0:
				return int(value)
		TYPE_DICTIONARY:
			for k in value:
				value[k] = _narrow_integral_numbers(value[k])
		TYPE_ARRAY:
			for i in value.size():
				value[i] = _narrow_integral_numbers(value[i])
	return value
