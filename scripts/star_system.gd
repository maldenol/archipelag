extends Node3D

const PlanetScript = preload("res://scripts/planet_body.gd")
const PlayerScript = preload("res://scripts/player.gd")
const RocketScript = preload("res://scripts/rocket.gd")
const HudScript = preload("res://scripts/hud.gd")
const SpaceMath = preload("res://scripts/space_math.gd")
const PoolScript = preload("res://scripts/bullet_pool.gd")
const SoundScript = preload("res://scripts/soundscape.gd")
const MenuScript = preload("res://scripts/menu.gd")

var sim_time = 0.0
var clock_accum = 0.0
const WARP_STEPS = [1, 2, 4, 8]
var warp_index = 0
var star_gm = 0.0
var star_radius = 3200.0
var planets = []
var player
var rocket
var controlled
var map_expanded = false
var sun: DirectionalLight3D
var map_camera: Camera3D
var map_distance = 90000.0
var map_quat = Quaternion(Vector3.RIGHT, -1.05)
var map_visible = false
var orbit_root: Node3D
var trajectory: MeshInstance3D
var trajectory_mesh: ImmediateMesh
var trajectory_material: StandardMaterial3D
var satellite_lines = []
var gate_mesh: ImmediateMesh
var impact_mesh: ImmediateMesh
var look_armed = false
var restarting = false
var playing = false
var boot_to_menu = true
var dying = false
var sound
var menu
const CRITICAL_SPEED = 50.0
const ZOOM_FRACTION = 1.1

func _ready() -> void:
	add_to_group("star_system")
	process_physics_priority = -20
	_build_environment()
	var reference_axis = 6000.0
	star_gm = 4.0 * reference_axis * reference_axis
	_build_star()
	_build_planets()
	for planet in planets:
		planet.place(0.0)
		planet.prev_position = planet.global_position
		planet.prev_basis = planet.global_basis
	_build_rocket()
	_build_player()
	var hud = HudScript.new()
	add_child(hud)
	add_child(PoolScript.new())
	controlled = player
	player.camera.current = true
	_build_map()
	if sound == null:
		sound = SoundScript.new()
		add_child(sound)
	if menu == null:
		menu = MenuScript.new()
		add_child(menu)
	if boot_to_menu:
		playing = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_tree().paused = true
		menu.show_main()
	else:
		begin_play()

func _center_pointer() -> void:
	look_armed = false
	var size = get_viewport().get_visible_rect().size
	if size.x > 1.0:
		Input.warp_mouse(size * 0.5)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _input(event: InputEvent) -> void:
	if look_armed or not (event is InputEventMouseMotion):
		return
	look_armed = true
	get_viewport().set_input_as_handled()

func _physics_process(delta: float) -> void:
	var scale = 1.0
	if playing and controlled == rocket and rocket != null and not rocket.exploded:
		scale = warp_factor()
	if Engine.time_scale != scale:
		Engine.time_scale = scale
	if Engine.physics_ticks_per_second != 60:
		Engine.physics_ticks_per_second = 60
	drive_clock(delta)
	_aim_sun()

func restart_run() -> void:
	if restarting:
		return
	restarting = true
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	warp_index = 0
	map_expanded = false
	map_visible = false
	map_distance = 90000.0
	map_quat = Quaternion(Vector3.RIGHT, -1.05)
	look_armed = false
	if rocket != null:
		rocket.attitude = ""
		rocket.thrust_held = false
	if map_camera != null:
		map_camera.current = false
	if orbit_root != null:
		orbit_root.visible = false
	_restore_view()
	if not boot_to_menu:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	call_deferred("_rebuild_world")

func _rebuild_world() -> void:
	for child in get_children():
		if child == sound or child == menu:
			continue
		child.free()
	sim_time = 0.0
	clock_accum = 0.0
	warp_index = 0
	map_expanded = false
	map_visible = false
	map_distance = 90000.0
	map_quat = Quaternion(Vector3.RIGHT, -1.05)
	look_armed = false
	planets = []
	satellite_lines = []
	player = null
	rocket = null
	controlled = null
	sun = null
	map_camera = null
	orbit_root = null
	trajectory = null
	trajectory_mesh = null
	trajectory_material = null
	gate_mesh = null
	impact_mesh = null
	restarting = false
	dying = false
	_ready()

func begin_death() -> void:
	if dying or not playing:
		return
	dying = true
	Engine.time_scale = 1.0
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if menu:
		menu.show_death()

func begin_play() -> void:
	boot_to_menu = false
	playing = true
	get_tree().paused = false
	if menu:
		menu.hide_menu()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	call_deferred("_center_pointer")

func pause_game() -> void:
	if not playing or dying:
		return
	Engine.time_scale = 1.0
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if menu:
		menu.show_pause()

func resume_game() -> void:
	if not playing:
		return
	get_tree().paused = false
	if menu:
		menu.hide_menu()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	call_deferred("_center_pointer")

func return_to_menu() -> void:
	boot_to_menu = true
	playing = false
	dying = false
	get_tree().paused = false
	restart_run()

func warp_factor() -> float:
	if controlled != rocket:
		return 1.0
	return float(WARP_STEPS[warp_index])

func warp_faster() -> void:
	warp_index = mini(warp_index + 1, WARP_STEPS.size() - 1)

func warp_slower() -> void:
	warp_index = maxi(warp_index - 1, 0)

func warp_default() -> void:
	warp_index = 0

func drive_clock(amount: float) -> void:
	if dying:
		return
	sim_time += amount
	for planet in planets:
		planet.update_motion(sim_time)

func _process(_delta: float) -> void:
	_aim_sun()
	_update_map()

func _aim_sun() -> void:
	if sun == null:
		return
	var target = controlled.global_position if controlled != null else global_position
	var dir = target - global_position
	var dist = dir.length()
	if dist < 1.0:
		return
	sun.global_basis = Basis.looking_at(dir / dist, Vector3.UP)
	var apparent = rad_to_deg(2.0 * asin(clampf(star_radius / dist, 0.0, 0.999)))
	sun.light_angular_distance = clampf(apparent * 0.15, 0.6, 2.0)
	var reach = 140.0
	if controlled == rocket and rocket != null:
		reach = rocket.cam_distance * 5.0 + 36.0
	elif controlled == player and player != null:
		reach = player.cam_distance * 8.0 + 20.0
	var ground = nearest_planet(target)
	if ground != null and ground.altitude_at(target) < 8000.0:
		reach = maxf(reach, 900.0)
	sun.directional_shadow_max_distance = clampf(reach, 80.0, 900.0)
	sun.directional_shadow_fade_start = 0.42
	sun.light_cull_mask = 1
	var near_body = ground if ground != null and ground.is_near_viewer(target, 10000.0) else null
	var casters = 1
	if near_body != null:
		casters |= near_body.visual_layer
	sun.shadow_caster_mask = casters
	for planet in planets:
		planet.set_star_shadows(planet == near_body, sun.directional_shadow_max_distance)

func orbit_map(yaw: float, pitch: float) -> void:
	map_quat = (map_quat * Quaternion(Vector3.UP, yaw) * Quaternion(Vector3.RIGHT, pitch)).normalized()

func zoom_map(out: bool) -> void:
	map_distance = clampf(map_distance * (ZOOM_FRACTION if out else 1.0 / ZOOM_FRACTION), 200.0, 400000.0)

func _build_map() -> void:
	orbit_root = Node3D.new()
	orbit_root.visible = false
	add_child(orbit_root)
	for planet in planets:
		var line = MeshInstance3D.new()
		line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if planet.parent_body != null:
			var ring = ImmediateMesh.new()
			line.mesh = ring
			var ring_material = _line_material(planet.color)
			satellite_lines.append({"mesh": ring, "planet": planet, "material": ring_material})
		else:
			line.mesh = _orbit_mesh(planet)
		orbit_root.add_child(line)
	trajectory_material = _line_material(Color(0.45, 0.95, 1.0))
	trajectory_mesh = ImmediateMesh.new()
	trajectory = MeshInstance3D.new()
	trajectory.mesh = trajectory_mesh
	trajectory.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	orbit_root.add_child(trajectory)
	gate_mesh = ImmediateMesh.new()
	var gates = MeshInstance3D.new()
	gates.mesh = gate_mesh
	gates.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	orbit_root.add_child(gates)
	impact_mesh = ImmediateMesh.new()
	var impact = MeshInstance3D.new()
	impact.mesh = impact_mesh
	impact.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	orbit_root.add_child(impact)
	map_camera = Camera3D.new()
	map_camera.fov = 55.0
	map_camera.near = 1.0
	map_camera.far = 2000000.0
	map_camera.current = false
	var map_exposure = CameraAttributesPractical.new()
	map_exposure.auto_exposure_enabled = false
	map_exposure.exposure_sensitivity = 25.0
	map_exposure.exposure_multiplier = 0.4
	map_camera.attributes = map_exposure
	add_child(map_camera)

func _orbit_mesh(planet) -> ArrayMesh:
	var period = SpaceMath.TAU / maxf(planet.orbit.mean_motion, 0.0000001)
	var tool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_LINE_STRIP)
	tool.set_material(_line_material(planet.color))
	for step in 160:
		tool.add_vertex(planet.location_at(period * float(step) / 159.0))
	return tool.commit()

func _line_material(color: Color) -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = false
	return material

func _update_map() -> void:
	if map_camera == null:
		return
	if not map_expanded:
		if map_visible:
			map_camera.current = false
			orbit_root.visible = false
			_restore_view()
			map_visible = false
		return
	map_visible = true
	orbit_root.visible = true
	map_camera.current = true
	var view = Basis(map_quat)
	var focus = global_position
	if controlled == rocket and rocket != null:
		focus = rocket.global_position
	elif controlled == player and player != null:
		focus = player.global_position
	map_camera.global_position = focus + view.z * map_distance
	map_camera.global_basis = view
	_draw_satellite_orbits()
	_update_trajectory()

func _update_trajectory() -> void:
	trajectory_mesh.clear_surfaces()
	if rocket == null:
		return
	var path = rocket.predict(300.0, 0.5)
	var framed: Dictionary = frame_path(path.samples)
	for strip in framed.strips:
		if strip.size() < 2:
			continue
		trajectory_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, trajectory_material)
		for point in strip:
			trajectory_mesh.surface_add_vertex(point)
		trajectory_mesh.surface_end()
	_draw_gates(framed.gates)
	_draw_impact(path)

func _draw_satellite_orbits() -> void:
	for entry in satellite_lines:
		var mesh: ImmediateMesh = entry.mesh
		var planet = entry.planet
		var parent = planet.parent_body
		mesh.clear_surfaces()
		if parent == null:
			continue
		var period = SpaceMath.TAU / maxf(planet.orbit.mean_motion, 0.0000001)
		mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, entry.material)
		for step in 96:
			var rel = SpaceMath.orbit_position(planet.orbit, period * float(step) / 95.0)
			mesh.surface_add_vertex(parent.global_position + rel)
		mesh.surface_end()

func _draw_gates(gates: Array) -> void:
	if gate_mesh == null:
		return
	gate_mesh.clear_surfaces()
	if map_camera == null or gates.is_empty():
		return
	var right = map_camera.global_basis.x
	var up = map_camera.global_basis.y
	var span = maxf(map_distance * 0.0045, 80.0)
	var exit_material = _line_material(Color(1.0, 0.42, 0.28))
	var entry_material = _line_material(Color(0.35, 0.95, 0.72))
	for gate in gates:
		var at: Vector3 = gate.at
		var leaving = gate.kind == "exit"
		gate_mesh.surface_begin(Mesh.PRIMITIVE_LINES, exit_material if leaving else entry_material)
		if leaving:
			gate_mesh.surface_add_vertex(at + (right + up) * span)
			gate_mesh.surface_add_vertex(at - (right + up) * span)
			gate_mesh.surface_add_vertex(at + (right - up) * span)
			gate_mesh.surface_add_vertex(at - (right - up) * span)
		else:
			var previous = at + right * span
			for i in 12:
				var angle = SpaceMath.TAU * float(i + 1) / 12.0
				var point = at + right * cos(angle) * span + up * sin(angle) * span
				gate_mesh.surface_add_vertex(previous)
				gate_mesh.surface_add_vertex(point)
				previous = point
		gate_mesh.surface_end()

func _draw_impact(path: Dictionary) -> void:
	if impact_mesh == null:
		return
	impact_mesh.clear_surfaces()
	if not path.hit or path.samples.is_empty() or map_camera == null:
		return
	var last: Dictionary = path.samples[path.samples.size() - 1]
	var at: Vector3 = frame_point(last.pos, last.time)
	var right = map_camera.global_basis.x
	var up = map_camera.global_basis.y
	var span = maxf(map_distance * 0.0065, 120.0)
	var material = _line_material(Color(1.0, 0.8, 0.18))
	impact_mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	_diamond(impact_mesh, at, right, up, span)
	_diamond(impact_mesh, at, right, up, span * 0.45)
	impact_mesh.surface_end()

func _diamond(mesh: ImmediateMesh, at: Vector3, right: Vector3, up: Vector3, span: float) -> void:
	var corners = [
		at + up * span,
		at + right * span,
		at - up * span,
		at - right * span,
	]
	for i in 4:
		mesh.surface_add_vertex(corners[i])
		mesh.surface_add_vertex(corners[(i + 1) % 4])

func _restore_view() -> void:
	if controlled == rocket and rocket != null and rocket.camera != null:
		rocket.camera.current = true
	elif controlled == player and player != null and player.camera != null:
		player.camera.current = true

func acceleration_at(position: Vector3) -> Vector3:
	return SpaceMath.acceleration(bodies_at(sim_time), position)

func drag_acceleration(position: Vector3, velocity: Vector3, area: float, mass: float, dt: float) -> Vector3:
	if mass <= 0.0 or area <= 0.0:
		return Vector3.ZERO
	var density = 0.0
	var wind = Vector3.ZERO
	var drag_scale = 1.0
	for planet in planets:
		var thick = planet.air_density(position)
		if thick > density:
			density = thick
			wind = planet.carried_velocity(position)
			drag_scale = planet.atmo_drag
	if density <= 0.001:
		return Vector3.ZERO
	var rel = velocity - wind
	var speed = rel.length()
	if speed < 0.05:
		return Vector3.ZERO
	# Thick at the ground, then thinner with altitude. Linear until the critical speed, then v².
	var rho = 5.0 * density
	var coeff = 0.5 * rho * drag_scale * area / mass
	var magnitude = coeff * speed if speed < CRITICAL_SPEED else coeff * speed * speed
	if dt > 0.0:
		magnitude = minf(magnitude, speed / dt)
	return -rel / speed * magnitude

func bodies_at(time: float) -> Array:
	var bodies: Array = [{
		"name": "Hearth",
		"position": global_position,
		"gm": star_gm,
		"radius": star_radius,
	}]
	for planet in planets:
		bodies.append({
			"name": planet.planet_name,
			"position": planet.location_at(time),
			"basis": planet.rotation_at(time),
			"gm": planet.gm,
			"radius": planet.radius,
			"planet": planet,
		})
	return bodies

func apply_star_exposure(body, position: Vector3, delta: float) -> void:
	if body == null or delta <= 0.0 or not body.has_method("apply_damage"):
		return
	var altitude = position.distance_to(global_position) - star_radius
	if altitude <= 0.0:
		body.apply_damage(10000.0, self)
		return
	var band = 7000.0
	if altitude >= band:
		return
	# 0.2 hp/s at the outer edge, 4 hp/s one star-radius out, and much faster at the surface.
	var depth = 1.0 - altitude / band
	body.apply_damage(0.2 * exp(5.52 * depth) * delta, self)

func owner_of(rid: RID):
	if not rid.is_valid():
		return null
	for planet in planets:
		if planet.get_rid() == rid:
			return planet
	if rocket != null and rocket.get_rid() == rid:
		return rocket
	if player != null and player.get_rid() == rid:
		return player
	return null

func terrain_contact(start: Vector3, end: Vector3) -> Dictionary:
	var best_t = 2.0
	var best = null
	var best_pos = Vector3.ZERO
	for planet in planets:
		var t = planet.segment_visual(start, end)
		if t >= 0.0 and t < best_t:
			best_t = t
			best = planet
			best_pos = start.lerp(end, t)
	if best == null:
		return {}
	return {
		"position": best_pos,
		"normal": best.surface_normal(best_pos, best.global_position, best.global_basis),
		"collider": best,
	}

func attractor_at(position: Vector3, time: float):
	var star_dist2 = maxf(position.distance_squared_to(global_position), 1.0)
	var best_accel = star_gm / star_dist2
	var best = null
	for planet in planets:
		var center = planet.location_at(time)
		var dist2 = maxf(position.distance_squared_to(center), 1.0)
		var accel = planet.gm / dist2
		if accel > best_accel:
			best_accel = accel
			best = planet
	return best

func frame_point(position: Vector3, time: float) -> Vector3:
	var body = attractor_at(position, time)
	if body == null:
		return position
	return body.global_position + (position - body.location_at(time))

func frame_path(samples: Array) -> Dictionary:
	var strips: Array = []
	var gates: Array = []
	var current: Array = []
	var previous = null
	var has_previous = false
	for sample in samples:
		var pos: Vector3 = sample.pos
		var time: float = sample.time
		var body = attractor_at(pos, time)
		var point = body.global_position + (pos - body.location_at(time)) if body != null else pos
		if has_previous and body != previous:
			if current.size() >= 2:
				strips.append(current)
				gates.append({"at": current[current.size() - 1], "kind": "exit"})
			current = [point]
			gates.append({"at": point, "kind": "entry"})
		else:
			current.append(point)
		previous = body
		has_previous = true
	if current.size() >= 2:
		strips.append(current)
	return {"strips": strips, "gates": gates}

func framed_strips(samples: Array) -> Array:
	return frame_path(samples).strips

func dominant_at(position: Vector3) -> Dictionary:
	var star_dist2 = maxf(position.distance_squared_to(global_position), 1.0)
	var best_accel = star_gm / star_dist2
	var best_planet = null
	for planet in planets:
		var dist2 = maxf(position.distance_squared_to(planet.global_position), 1.0)
		var accel = planet.gm / dist2
		if accel > best_accel:
			best_accel = accel
			best_planet = planet
	return {"planet": best_planet, "accel": best_accel}

func nearest_planet(position: Vector3):
	var best = null
	var best_alt = INF
	for planet in planets:
		var alt = position.distance_to(planet.global_position) - planet.radius
		if alt < best_alt:
			best_alt = alt
			best = planet
	return best

func planet_named(body_name: String):
	for planet in planets:
		if planet.planet_name == body_name:
			return planet
	return null

func home():
	return planets[0] if planets.size() else null

func try_board() -> void:
	if controlled == player:
		if rocket == null or rocket.exploded:
			return
		if player.global_position.distance_squared_to(rocket.global_position) > PlayerScript.BOARD_RANGE * PlayerScript.BOARD_RANGE:
			return
		rocket.f_held = true
		player.f_held = true
		if sound:
			sound.play("board")
		player.set_boarded(true)
		rocket.camera.current = true
		controlled = rocket
		return
	if controlled == rocket and player:
		var exit_pos: Vector3 = rocket.global_position + rocket.global_basis.x * 3.2 + rocket.global_basis.y * 0.6
		player.f_held = true
		rocket.f_held = true
		if sound:
			sound.play("board")
		player.current_planet = null
		if rocket.landed and rocket.parked:
			var radial = exit_pos - rocket.parked.global_position
			if radial.length_squared() < 1.0:
				radial = rocket.global_basis.y
			var up = radial.normalized()
			player.global_position = rocket.parked.global_position + up * (rocket.parked.mesh_radius_world(up) + PlayerScript.STAND_HEIGHT + 0.14)
			player.spaceflight = false
			player.grounded = true
			player.linear_velocity = Vector3.ZERO
			player.space_velocity = Vector3.ZERO
			player._update_planet()
		else:
			player.global_position = exit_pos
			player.spaceflight = true
			player.grounded = false
			player.current_planet = null
			player.space_position = exit_pos
		var exit_up = player._up()
		var exit_forward = rocket.global_basis.x.slide(exit_up)
		if exit_forward.length_squared() < 0.01:
			exit_forward = (-rocket.global_basis.z).slide(exit_up)
		if exit_forward.length_squared() < 0.01:
			exit_forward = Vector3.FORWARD
		player.heading = exit_forward.normalized()
		var stand = SpaceMath.basis_from_up_forward(exit_up, player.heading)
		player.global_basis = stand
		player.space_quat = stand.get_rotation_quaternion()
		player.space_orient = player.spaceflight
		player.carried = false
		player.hop_height = 0.0
		player.hop_speed = 0.0
		rocket.camera.current = false
		player.set_boarded(false)
		if player.grounded:
			player.freeze = true
			player.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
			player.linear_velocity = Vector3.ZERO
		else:
			# Unfreeze first. A velocity written while frozen is discarded, so the
			# person was left at rest while the rocket flew on.
			player.freeze = false
			player.exit_grace = 0.4
			var inherited = rocket.linear_velocity
			if inherited.length_squared() < 1.0 and rocket.motion_ready:
				inherited = rocket.motion_velocity
			player.linear_velocity = inherited
			player.motion_velocity = inherited
			player.motion_sample = player.global_position
			player.motion_ready = true
			player.space_velocity = inherited
		controlled = player
		warp_default()

func respawn_player(at_home: bool) -> void:
	var xform: Transform3D = _home_spawn() if at_home else _spawn_near(player.global_position)
	player.dead = false
	player.health = player.max_health
	player.magazine = player.MAG_SIZE
	player.reloading = 0.0
	player.spaceflight = false
	player.grounded = true
	player.linear_velocity = Vector3.ZERO
	player.global_transform = xform
	player.heading = -xform.basis.z
	player._update_planet()

func on_rocket_destroyed() -> void:
	var piloting: bool = controlled == rocket
	rocket.exploded = false
	rocket.health = rocket.max_health
	rocket.thrust_held = false
	var pad = home()
	if pad:
		var outward = pad.global_basis.x
		rocket.global_position = pad.global_position + outward * (pad.mesh_radius_world(outward) + 3.0)
		rocket.park_on(pad)
	if piloting:
		rocket.camera.current = false
		player.set_boarded(false)
		respawn_player(true)
		controlled = player

func _build_environment() -> void:
	var world = WorldEnvironment.new()
	var env = Environment.new()
	var sky = Sky.new()
	var sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/stars.gdshader")
	sky_mat.set_shader_parameter("skybox", _star_cubemap())
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.5, 0.58)
	env.ambient_light_energy = 0.18
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = true
	env.glow_intensity = 0.28
	env.glow_strength = 0.45
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.7
	env.glow_hdr_scale = 0.8
	var exposure = CameraAttributesPractical.new()
	exposure.auto_exposure_enabled = true
	exposure.auto_exposure_scale = 0.4
	exposure.auto_exposure_min_sensitivity = 25.0
	exposure.auto_exposure_max_sensitivity = 110.0
	exposure.auto_exposure_speed = 0.45
	world.camera_attributes = exposure
	world.environment = env
	add_child(world)
	sun = DirectionalLight3D.new()
	sun.top_level = true
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.light_energy = 0.72
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 1800.0
	sun.directional_shadow_split_1 = 0.18
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.06
	sun.shadow_normal_bias = 0.8
	sun.shadow_blur = 0.35
	sun.light_angular_distance = 2.0
	sun.light_cull_mask = 1
	sun.shadow_caster_mask = 1
	add_child(sun)

func _star_cubemap() -> Cubemap:
	var size = 256
	var cells = 72
	var images: Array[Image] = []
	for face in 6:
		var bytes = PackedByteArray()
		bytes.resize(size * size * 4)
		for y in size:
			var fy = (float(y) + 0.5) / float(size) * float(cells)
			var cy = int(floor(fy))
			var py = fy - float(cy) - 0.5
			for x in size:
				var fx = (float(x) + 0.5) / float(size) * float(cells)
				var cx = int(floor(fx))
				var px = fx - float(cx) - 0.5
				var h = _sky_hash(face * 157 + cx * 19 + cy * 47)
				var value = 0.0
				if h > 0.955:
					var dist2 = px * px + py * py
					if dist2 < 0.018:
						var falloff = 1.0 - dist2 / 0.018
						value = (0.07 + (h - 0.955) * 2.4) * falloff * falloff
				var warm = _sky_hash(face * 23 + cx * 5 + cy * 11)
				var r = value
				var g = value
				var b = value
				if warm > 0.72:
					r *= 1.15
					b *= 0.7
				elif warm < 0.22:
					b *= 1.2
					r *= 0.75
				var i = (y * size + x) * 4
				bytes[i] = int(clampf(r, 0.0, 1.0) * 255.0)
				bytes[i + 1] = int(clampf(g, 0.0, 1.0) * 255.0)
				bytes[i + 2] = int(clampf(b, 0.0, 1.0) * 255.0)
				bytes[i + 3] = 255
		images.append(Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, bytes))
	var cube = Cubemap.new()
	cube.create_from_images(images)
	return cube

func _sky_hash(n: int) -> float:
	var x = n * 374761393
	x = (x ^ (x >> 13)) * 1274126177
	return float((x ^ (x >> 16)) & 0x7fffffff) / 2147483647.0

func _build_star() -> void:
	var star = StaticBody3D.new()
	star.collision_layer = 1
	star.collision_mask = 0
	star.add_to_group("star")
	var shape = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = star_radius
	shape.shape = sphere
	star.add_child(shape)
	var mesh = MeshInstance3D.new()
	var ball = SphereMesh.new()
	ball.radius = star_radius
	ball.height = star_radius * 2.0
	ball.radial_segments = 128
	ball.rings = 64
	mesh.mesh = ball
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.layers = 1 << 19
	mesh.material_override = SpaceMath.make_material(Color(1.0, 0.9, 0.7), 6.0)
	star.add_child(mesh)
	add_child(star)

func _build_planets() -> void:
	var specs = [
		{"name": "Caldera", "color": Color(0.72, 0.28, 0.12), "axis": 42000.0, "ecc": 0.04, "inc": 0.03, "node": 0.2, "arg": 0.4, "mean": 0.5, "spin": 5600.0, "radius": 900.0, "gravity": 14.0, "seed": 0},
		{"name": "Lumen", "color": Color(0.2, 0.55, 0.28), "axis": 70000.0, "ecc": 0.10, "inc": 0.18, "node": 0.5, "arg": 1.2, "mean": 2.1, "spin": 9000.0, "radius": 1200.0, "gravity": 15.0, "seed": 1},
		{"name": "Vellum", "color": Color(0.55, 0.75, 0.9), "axis": 110000.0, "ecc": 0.16, "inc": 0.42, "node": 1.7, "arg": 0.7, "mean": 3.8, "spin": 4400.0, "radius": 800.0, "gravity": 12.0, "seed": 2},
		{"name": "Mote", "color": Color(0.45, 0.18, 0.16), "axis": 190000.0, "ecc": 0.18, "inc": 0.7, "node": 2.5, "arg": 2.0, "mean": 1.1, "spin": 6600.0, "radius": 1500.0, "gravity": 16.0, "seed": 3},
	]
	for spec in specs:
		var orbit = {
			"semi_major": spec.axis,
			"eccentricity": spec.ecc,
			"inclination": spec.inc,
			"node": spec.node,
			"argument": spec.arg,
			"mean_anomaly": spec.mean,
			"mean_motion": 0.0,
			"spin_rate": SpaceMath.TAU / spec.spin,
		}
		SpaceMath.finalize_orbit(orbit, star_gm)
		var planet = PlanetScript.new()
		add_child(planet)
		planet.setup(self, {
			"name": spec.name,
			"color": spec.color,
			"orbit": orbit,
			"radius": spec.radius,
			"gravity": spec.gravity,
			"seed": spec.seed,
			"visual_layer": 1 << (planets.size() + 1),
		})
		planets.append(planet)
	_build_satellite()

func _build_satellite() -> void:
	var mote = planet_named("Mote")
	if mote == null:
		return
	var orbit = {
		"semi_major": 22000.0,
		"eccentricity": 0.04,
		"inclination": 0.55,
		"node": 1.1,
		"argument": 0.4,
		"mean_anomaly": 0.8,
		"mean_motion": 0.0,
		"spin_rate": SpaceMath.TAU / 2800.0,
	}
	SpaceMath.finalize_orbit(orbit, mote.gm)
	var moon = PlanetScript.new()
	moon.parent_body = mote
	add_child(moon)
	moon.setup(self, {
		"name": "Cinder",
		"color": Color(0.62, 0.48, 0.38),
		"orbit": orbit,
		"radius": 380.0,
		"gravity": 8.0,
		"seed": 4,
		"visual_layer": 1 << (planets.size() + 1),
	})
	planets.append(moon)

func _build_rocket() -> void:
	var pad = home()
	rocket = RocketScript.new()
	add_child(rocket)
	rocket.bind_system(self)
	if pad:
		var outward = pad.global_basis.x
		rocket.global_position = pad.global_position + outward * (pad.mesh_radius_world(outward) + 3.0)
		rocket.park_on(pad)

func _build_player() -> void:
	player = PlayerScript.new()
	add_child(player)
	player.bind_system(self)
	player.place(_home_spawn())
	player._update_planet()

func _home_spawn() -> Transform3D:
	var pad = home()
	if pad == null:
		return Transform3D.IDENTITY
	var angle: float = 4.2 / pad.radius
	var dir = Vector3(cos(angle), 0.0, sin(angle)).normalized()
	var normal: Vector3 = (pad.global_basis * dir).normalized()
	var pos: Vector3 = pad.global_position + normal * (pad.mesh_radius_world(normal) + PlayerScript.STAND_HEIGHT + 0.14)
	var forward = Vector3.FORWARD
	if rocket:
		forward = (rocket.global_position - pos).slide(normal).normalized()
	if forward.length_squared() < 0.001:
		forward = normal.cross(Vector3.UP).normalized()
	return Transform3D(SpaceMath.basis_from_up_forward(normal, forward), pos)

func _spawn_near(position: Vector3) -> Transform3D:
	var planet = nearest_planet(position)
	if planet == null:
		return _home_spawn()
	var normal: Vector3 = (position - planet.global_position).normalized()
	if normal.length_squared() < 0.5:
		normal = Vector3.UP
	var pos: Vector3 = planet.global_position + normal * (planet.mesh_radius_world(normal) + PlayerScript.STAND_HEIGHT + 0.14)
	var forward = Vector3.FORWARD.slide(normal).normalized()
	if forward.length_squared() < 0.001:
		forward = Vector3.RIGHT.slide(normal).normalized()
	return Transform3D(SpaceMath.basis_from_up_forward(normal, forward), pos)
