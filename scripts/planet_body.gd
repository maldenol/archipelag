extends AnimatableBody3D

const SpaceMath = preload("res://scripts/space_math.gd")
const MESH_SEGS = 360
const MESH_RINGS = 180

var system
var parent_body = null
var planet_name = ""
var color = Color.WHITE
var orbit = {}
var radius = 100.0
var surface_gravity = 9.8
var gm = 0.0
var prev_position = Vector3.ZERO
var prev_basis = Basis.IDENTITY
var noise: FastNoiseLite
var moisture_noise: FastNoiseLite
var lake_noise: FastNoiseLite
var terrain_profile: Dictionary = {}
var amplitude = 32.0
var atmo_shell = 0.0
var atmo_drag = 1.0
var atmo_mat: ShaderMaterial
var ground_shape: ConcavePolygonShape3D
var terrain_chunks: Array[MeshInstance3D] = []
var far_terrain: MeshInstance3D
var foliage: Node3D
var visual_layer = 2
var star_light: DirectionalLight3D

func setup(host, data: Dictionary) -> void:
	sync_to_physics = false
	system = host
	planet_name = data.name
	color = data.color
	orbit = data.orbit
	radius = data.radius
	surface_gravity = data.gravity
	gm = surface_gravity * radius * radius
	visual_layer = int(data.visual_layer) if data.has("visual_layer") else 2
	# Moved in the physics step. Godot publishes that motion to rigid bodies.
	sync_to_physics = false
	collision_layer = 1
	collision_mask = 0
	process_physics_priority = -20
	var seed = int(data.seed) if data.has("seed") else 0
	_build_noise(seed)
	# Terrain hues stay off the atmosphere palette. `color` is only the map tint.
	var material = ShaderMaterial.new()
	material.shader = load("res://shaders/terrain.gdshader")
	var tex = SpaceMath.biome_textures(seed, terrain_profile)
	material.set_shader_parameter("plains_tex", tex.plains)
	material.set_shader_parameter("desert_tex", tex.desert)
	material.set_shader_parameter("ice_tex", tex.ice)
	material.set_shader_parameter("ocean_tex", tex.ocean)
	material.set_shader_parameter("lake_tex", tex.lake)
	material.set_shader_parameter("mountain_tex", tex.mountain)
	material.set_shader_parameter("detail_normal", tex.normal)
	material.set_shader_parameter("uv_scale", terrain_profile.uv_scale)
	material.set_shader_parameter("normal_strength", terrain_profile.normal_strength)
	# One mesh, so the shadow map has no cut between chunks.
	var near = MeshInstance3D.new()
	near.mesh = _terrain_mesh(MESH_SEGS, MESH_RINGS, 0, MESH_SEGS, 0, MESH_RINGS)
	near.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	near.material_override = material
	near.layers = visual_layer
	add_child(near)
	terrain_chunks.append(near)
	var faces = near.mesh.get_faces()
	far_terrain = MeshInstance3D.new()
	far_terrain.mesh = _terrain_mesh(40, 20, 0, 40, 0, 20)
	far_terrain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	far_terrain.material_override = material
	far_terrain.layers = visual_layer
	far_terrain.visible = false
	add_child(far_terrain)
	_build_foliage(seed)
	_build_star_light()
	ground_shape = ConcavePolygonShape3D.new()
	ground_shape.backface_collision = true
	ground_shape.set_faces(faces)
	var solid = CollisionShape3D.new()
	solid.shape = ground_shape
	add_child(solid)
	var grip = PhysicsMaterial.new()
	grip.friction = 1.0
	grip.bounce = 0.0
	physics_material_override = grip
	_build_atmosphere(seed)
	place(0.0)
	prev_position = global_position
	prev_basis = global_basis

func place(time: float) -> void:
	global_transform = Transform3D(SpaceMath.orbit_rotation(orbit, time), location_at(time))
	_aim_star_light()

func update_motion(time: float) -> void:
	prev_position = global_position
	prev_basis = global_basis
	place(time)
	_aim_atmosphere()
	_update_lod()

func near_viewer(viewer: Vector3) -> bool:
	return global_position.distance_to(viewer) < radius * 4.0 + 6000.0

func set_star_shadows(enabled: bool, reach: float) -> void:
	if star_light == null:
		return
	star_light.shadow_enabled = enabled
	if enabled:
		star_light.shadow_caster_mask = visual_layer | 1
		star_light.directional_shadow_max_distance = reach
		star_light.directional_shadow_fade_start = 0.42
	else:
		star_light.shadow_caster_mask = visual_layer

func location_at(time: float) -> Vector3:
	var local = SpaceMath.orbit_position(orbit, time)
	if parent_body != null:
		return parent_body.location_at(time) + local
	var origin = system.global_position if system else Vector3.ZERO
	return origin + local

func rotation_at(time: float) -> Basis:
	return SpaceMath.orbit_rotation(orbit, time)

func height_offset(local_dir: Vector3) -> float:
	var dir = local_dir
	var len_sq = dir.length_squared()
	if len_sq < 0.0000001 or noise == null:
		return 0.0
	if absf(len_sq - 1.0) > 0.0001:
		dir = dir / sqrt(len_sq)
	return noise.get_noise_3d(dir.x, dir.y, dir.z) * amplitude

func ground_radius(world_dir: Vector3) -> float:
	return radius + height_offset(global_basis.inverse() * world_dir)

func mesh_radius_world(world_dir: Vector3) -> float:
	var local = global_basis.inverse() * world_dir
	if local.length_squared() < 0.0000001:
		return radius
	return _mesh_radius_local(local.normalized())

func ground_radius_around(world_dir: Vector3, reach: float) -> float:
	var dir = world_dir.normalized()
	if dir.length_squared() < 0.5:
		return radius
	var best = ground_radius(dir)
	if reach <= 0.05:
		return best
	var side = dir.cross(Vector3.UP)
	if side.length_squared() < 0.01:
		side = dir.cross(Vector3.RIGHT)
	side = side.normalized()
	var other = dir.cross(side).normalized()
	var ang = reach / maxf(radius, 1.0)
	for i in 6:
		var turn = float(i) * TAU / 6.0
		var sample = (dir + (side * cos(turn) + other * sin(turn)) * ang).normalized()
		best = maxf(best, ground_radius(sample))
	return best

func altitude_at(world_pos: Vector3) -> float:
	var offset = world_pos - global_position
	return offset.length() - ground_radius(offset)

func in_atmosphere(world_pos: Vector3) -> bool:
	return atmo_shell > 1.0 and world_pos.distance_squared_to(global_position) < atmo_shell * atmo_shell

func air_density(world_pos: Vector3) -> float:
	if not in_atmosphere(world_pos):
		return 0.0
	var offset = world_pos - global_position
	var dist = offset.length()
	var floor_r = ground_radius(offset)
	var span = maxf(atmo_shell - floor_r, 1.0)
	var height = clampf((dist - floor_r) / span, 0.0, 1.0)
	return exp(-1.6 * height)

func step_velocity() -> Vector3:
	var dt = 1.0 / float(Engine.physics_ticks_per_second)
	return (global_position - prev_position) / maxf(dt, 0.0001)

func center_velocity() -> Vector3:
	var time = system.sim_time if system else 0.0
	var eps = 0.02
	return (location_at(time + eps) - location_at(time - eps)) / (2.0 * eps)

func surface_normal(world_pos: Vector3, center: Vector3, orient: Basis) -> Vector3:
	var offset = world_pos - center
	if offset.length_squared() < 0.001:
		return Vector3.UP
	var local = (orient.inverse() * offset).normalized()
	var nrm = orient * _local_normal(local)
	if nrm.length_squared() < 0.001:
		return offset.normalized()
	return nrm.normalized()

func segment_visual(start: Vector3, end: Vector3) -> float:
	var center = global_position
	var delta = end - start
	var span = delta.length_squared()
	var offset = start - center
	var t_close = 0.0
	if span > 0.0001:
		t_close = clampf(-offset.dot(delta) / span, 0.0, 1.0)
	var outer = radius + amplitude + 8.0
	if start.lerp(end, t_close).distance_squared_to(center) > outer * outer:
		return -1.0
	var steps = 10
	var prev_t = 0.0
	var prev_inside = _visual_gap(start) <= 0.05
	for i in steps:
		var t = float(i + 1) / float(steps)
		var inside = _visual_gap(start.lerp(end, t)) <= 0.0
		if inside and not prev_inside:
			var lo = prev_t
			var hi = t
			for _n in 8:
				var mid = (lo + hi) * 0.5
				if _visual_gap(start.lerp(end, mid)) <= 0.0:
					hi = mid
				else:
					lo = mid
			return hi
		prev_inside = inside
		prev_t = t
	return -1.0

func _visual_gap(world_pos: Vector3) -> float:
	var offset = world_pos - global_position
	var dist = offset.length()
	if dist < 0.001:
		return -radius
	return dist - mesh_radius_world(offset)

func segment_surface(start: Vector3, end: Vector3, center: Vector3, orient: Basis) -> float:
	var outer = radius + amplitude + 2.0
	var delta = end - start
	var offset = start - center
	var span = delta.length_squared()
	var t_close = 0.0
	if span > 0.0001:
		t_close = clampf(-offset.dot(delta) / span, 0.0, 1.0)
	if start.lerp(end, t_close).distance_squared_to(center) > outer * outer:
		return -1.0
	var steps = 8
	if _gap(start, center, orient) <= 0.0:
		return 0.0
	for i in steps:
		var t = float(i + 1) / float(steps)
		if _gap(start.lerp(end, t), center, orient) <= 0.0:
			var lo = float(i) / float(steps)
			var hi = t
			for _n in 7:
				var mid = (lo + hi) * 0.5
				if _gap(start.lerp(end, mid), center, orient) <= 0.0:
					hi = mid
				else:
					lo = mid
			return hi
	return -1.0

func _gap(world_pos: Vector3, center: Vector3, orient: Basis) -> float:
	var offset = world_pos - center
	var dist = offset.length()
	if dist < 0.001:
		return -radius
	return dist - (radius + height_offset(orient.inverse() * offset))

func _local_normal(dir: Vector3) -> Vector3:
	var eps = 0.004
	var tangent = dir.cross(Vector3.UP)
	if tangent.length_squared() < 0.0001:
		tangent = dir.cross(Vector3.RIGHT)
	tangent = tangent.normalized()
	var bitangent = dir.cross(tangent).normalized()
	var base = dir * (radius + height_offset(dir))
	var side = (dir + tangent * eps).normalized()
	var forward = (dir + bitangent * eps).normalized()
	var nrm = (side * (radius + height_offset(side)) - base).cross(forward * (radius + height_offset(forward)) - base)
	if nrm.dot(dir) < 0.0:
		nrm = -nrm
	return nrm.normalized() if nrm.length_squared() > 0.000001 else dir

func _build_noise(seed: int) -> void:
	terrain_profile = _terrain_profile(seed)
	noise = _fractal_noise(4000 + seed * 97, terrain_profile.frequency, terrain_profile.octaves, terrain_profile.gain, terrain_profile.lacunarity)
	moisture_noise = _fractal_noise(5100 + seed * 53, terrain_profile.moisture_frequency, 4, 0.5, 2.0)
	lake_noise = _fractal_noise(6200 + seed * 29, terrain_profile.lake_frequency, 3, 0.55, 2.0)
	amplitude = radius * terrain_profile.relief

func _fractal_noise(seed: int, frequency: float, octaves: int, gain: float, lacunarity: float) -> FastNoiseLite:
	var field = FastNoiseLite.new()
	field.noise_type = FastNoiseLite.TYPE_SIMPLEX
	field.fractal_type = FastNoiseLite.FRACTAL_FBM
	field.fractal_octaves = octaves
	field.fractal_lacunarity = lacunarity
	field.fractal_gain = gain
	field.seed = seed
	field.frequency = frequency
	return field

func _terrain_profile(seed: int) -> Dictionary:
	# Each triple is shadow, lit, and speck. These stay clear of the atmosphere
	# day colors: gold, cyan, violet, and orange.
	match seed:
		0:
			return {
				"sea": -0.34, "lake_level": -0.02, "lake_cut": 0.58,
				"mountain_level": 0.26, "ice_lat": 0.84, "ice_alt": 0.4,
				"desert_cut": 0.5, "frequency": 1.55, "octaves": 5, "gain": 0.52, "lacunarity": 2.15,
				"moisture_frequency": 1.7, "lake_frequency": 8.0, "relief": 0.052,
				"uv_scale": 0.05, "normal_strength": 0.9, "plant_count": 280,
				"plains": [Color(0.16, 0.28, 0.10), Color(0.30, 0.42, 0.16), Color(0.08, 0.16, 0.05)],
				"desert": [Color(0.42, 0.46, 0.48), Color(0.62, 0.66, 0.68), Color(0.28, 0.32, 0.34)],
				"ice": [Color(0.62, 0.72, 0.78), Color(0.90, 0.94, 0.96), Color(0.40, 0.52, 0.60)],
				"ocean": [Color(0.03, 0.05, 0.06), Color(0.08, 0.14, 0.13), Color(0.02, 0.04, 0.05)],
				"lake": [Color(0.06, 0.18, 0.16), Color(0.16, 0.36, 0.30), Color(0.03, 0.09, 0.08)],
				"mountain": [Color(0.08, 0.10, 0.12), Color(0.24, 0.28, 0.32), Color(0.04, 0.05, 0.06)],
			}
		1:
			return {
				"sea": -0.02, "lake_level": 0.22, "lake_cut": 0.56,
				"mountain_level": 0.3, "ice_lat": 0.74, "ice_alt": 0.58,
				"desert_cut": 0.4, "frequency": 2.5, "octaves": 4, "gain": 0.45, "lacunarity": 2.0,
				"moisture_frequency": 1.15, "lake_frequency": 5.4, "relief": 0.03,
				"uv_scale": 0.1, "normal_strength": 0.55, "plant_count": 1400,
				"plains": [Color(0.06, 0.28, 0.04), Color(0.18, 0.55, 0.08), Color(0.03, 0.14, 0.02)],
				"desert": [Color(0.46, 0.36, 0.16), Color(0.78, 0.64, 0.30), Color(0.32, 0.22, 0.08)],
				"ice": [Color(0.78, 0.82, 0.84), Color(0.96, 0.97, 0.98), Color(0.55, 0.62, 0.66)],
				"ocean": [Color(0.02, 0.05, 0.18), Color(0.05, 0.12, 0.36), Color(0.01, 0.03, 0.10)],
				"lake": [Color(0.12, 0.18, 0.05), Color(0.26, 0.34, 0.10), Color(0.06, 0.10, 0.03)],
				"mountain": [Color(0.32, 0.16, 0.08), Color(0.58, 0.32, 0.16), Color(0.16, 0.08, 0.04)],
			}
		2:
			return {
				"sea": -0.16, "lake_level": 0.2, "lake_cut": 0.5,
				"mountain_level": 0.18, "ice_lat": 0.62, "ice_alt": 0.5,
				"desert_cut": 0.38, "frequency": 1.85, "octaves": 4, "gain": 0.42, "lacunarity": 2.05,
				"moisture_frequency": 2.1, "lake_frequency": 6.4, "relief": 0.026,
				"uv_scale": 0.07, "normal_strength": 0.4, "plant_count": 180,
				"plains": [Color(0.22, 0.34, 0.20), Color(0.40, 0.56, 0.32), Color(0.12, 0.22, 0.12)],
				"desert": [Color(0.70, 0.72, 0.68), Color(0.90, 0.91, 0.86), Color(0.52, 0.54, 0.50)],
				"ice": [Color(0.68, 0.80, 0.88), Color(0.94, 0.97, 0.99), Color(0.40, 0.58, 0.72)],
				"ocean": [Color(0.04, 0.07, 0.11), Color(0.10, 0.16, 0.22), Color(0.02, 0.04, 0.06)],
				"lake": [Color(0.28, 0.46, 0.52), Color(0.55, 0.74, 0.78), Color(0.16, 0.32, 0.40)],
				"mountain": [Color(0.36, 0.16, 0.08), Color(0.64, 0.32, 0.16), Color(0.18, 0.08, 0.04)],
			}
		3:
			return {
				"sea": -0.04, "lake_level": 0.2, "lake_cut": 0.54,
				"mountain_level": 0.28, "ice_lat": 0.82, "ice_alt": 0.62,
				"desert_cut": 0.48, "frequency": 1.2, "octaves": 6, "gain": 0.5, "lacunarity": 2.05,
				"moisture_frequency": 1.05, "lake_frequency": 4.4, "relief": 0.068,
				"uv_scale": 0.045, "normal_strength": 0.95, "plant_count": 700,
				"plains": [Color(0.34, 0.36, 0.08), Color(0.62, 0.64, 0.18), Color(0.22, 0.24, 0.05)],
				"desert": [Color(0.30, 0.28, 0.22), Color(0.50, 0.46, 0.36), Color(0.18, 0.16, 0.12)],
				"ice": [Color(0.74, 0.80, 0.84), Color(0.94, 0.96, 0.97), Color(0.50, 0.60, 0.68)],
				"ocean": [Color(0.02, 0.16, 0.18), Color(0.08, 0.36, 0.34), Color(0.01, 0.08, 0.09)],
				"lake": [Color(0.10, 0.22, 0.12), Color(0.22, 0.40, 0.18), Color(0.05, 0.12, 0.06)],
				"mountain": [Color(0.16, 0.18, 0.22), Color(0.34, 0.38, 0.46), Color(0.08, 0.10, 0.14)],
			}
		_:
			return {
				"sea": -0.38, "lake_level": 0.16, "lake_cut": 0.5,
				"mountain_level": 0.16, "ice_lat": 0.8, "ice_alt": 0.36,
				"desert_cut": 0.58, "frequency": 4.1, "octaves": 5, "gain": 0.52, "lacunarity": 2.2,
				"moisture_frequency": 3.3, "lake_frequency": 11.0, "relief": 0.08,
				"uv_scale": 0.12, "normal_strength": 1.0, "plant_count": 60,
				"plains": [Color(0.24, 0.26, 0.30), Color(0.40, 0.44, 0.50), Color(0.14, 0.16, 0.20)],
				"desert": [Color(0.58, 0.60, 0.64), Color(0.78, 0.80, 0.84), Color(0.40, 0.42, 0.48)],
				"ice": [Color(0.70, 0.78, 0.74), Color(0.90, 0.96, 0.92), Color(0.46, 0.58, 0.52)],
				"ocean": [Color(0.03, 0.03, 0.04), Color(0.10, 0.10, 0.12), Color(0.02, 0.02, 0.03)],
				"lake": [Color(0.16, 0.22, 0.20), Color(0.34, 0.46, 0.40), Color(0.08, 0.14, 0.12)],
				"mountain": [Color(0.10, 0.11, 0.13), Color(0.28, 0.30, 0.34), Color(0.05, 0.05, 0.07)],
			}

func _surface_sample(dir: Vector3) -> Dictionary:
	var raw = noise.get_noise_3d(dir.x, dir.y, dir.z)
	var moist = moisture_noise.get_noise_3d(dir.x, dir.y, dir.z) * 0.5 + 0.5
	var lake_n = lake_noise.get_noise_3d(dir.x, dir.y, dir.z) * 0.5 + 0.5
	var lat = absf(dir.y)
	var sea = float(terrain_profile.sea)
	var below = 1.0 - smoothstep(sea - 0.07, sea + 0.025, raw)
	var polar = smoothstep(float(terrain_profile.ice_lat) - 0.1, float(terrain_profile.ice_lat) + 0.04, lat)
	var high_ice = smoothstep(float(terrain_profile.ice_alt) - 0.08, float(terrain_profile.ice_alt) + 0.04, raw)
	var ocean_w = below * (1.0 - polar)
	var shelf_w = below * polar
	var ice_w = clampf(maxf(shelf_w, maxf(high_ice, polar) * (1.0 - below)), 0.0, 1.0)
	var mountain_w = smoothstep(float(terrain_profile.mountain_level) - 0.05, float(terrain_profile.mountain_level) + 0.1, raw) * (1.0 - ice_w) * (1.0 - ocean_w)
	var lake_top = float(terrain_profile.lake_level)
	var lake_band = smoothstep(sea + 0.02, sea + 0.07, raw) * (1.0 - smoothstep(lake_top - 0.03, lake_top + 0.045, raw))
	var lake_w = lake_band * smoothstep(float(terrain_profile.lake_cut) - 0.05, float(terrain_profile.lake_cut) + 0.12, lake_n) * (1.0 - ice_w) * (1.0 - mountain_w)
	var covered = clampf(ocean_w + ice_w + mountain_w + lake_w, 0.0, 1.0)
	var open = 1.0 - covered
	var dry = 1.0 - smoothstep(float(terrain_profile.desert_cut) - 0.08, float(terrain_profile.desert_cut) + 0.1, moist)
	var desert_w = open * dry
	var plains_w = open * (1.0 - dry)
	var sum = ocean_w + ice_w + mountain_w + lake_w + desert_w + plains_w
	if sum < 0.0001:
		plains_w = 1.0
		sum = 1.0
	var inv = 1.0 / sum
	var height_unit = lerpf(raw, sea, clampf(ocean_w + shelf_w, 0.0, 1.0))
	return {
		"height": height_unit * amplitude,
		"plains": plains_w * inv,
		"desert": desert_w * inv,
		"ice": ice_w * inv,
		"ocean": ocean_w * inv,
		"lake": lake_w * inv,
		"mountain": mountain_w * inv,
	}

func _grid_vertex(x: int, y: int) -> Vector3:
	return _sphere_vertex(x, y, MESH_SEGS, MESH_RINGS)

func _unit_dir(x: int, y: int, segs: int, rings: int) -> Vector3:
	var phi = float(y) / float(rings) * PI
	var theta = float(x) / float(segs) * TAU
	return Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))

func _sphere_vertex(x: int, y: int, segs: int, rings: int) -> Vector3:
	var dir = _unit_dir(x, y, segs, rings)
	return dir * (radius + height_offset(dir))

func _update_lod() -> void:
	var viewer = global_position
	if system != null and system.controlled != null:
		viewer = system.controlled.global_position
	var near = near_viewer(viewer)
	for chunk in terrain_chunks:
		chunk.visible = near
	if far_terrain:
		far_terrain.visible = not near
	if foliage:
		foliage.visible = near

func _build_foliage(seed: int) -> void:
	foliage = Node3D.new()
	add_child(foliage)
	var count = int(terrain_profile.plant_count)
	if count <= 0:
		return
	var rng = RandomNumberGenerator.new()
	rng.seed = 2500 + seed * 13
	for kind in 3:
		var spots = _plant_spots(kind, count)
		if spots.is_empty():
			continue
		var multi = MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = _plant_mesh(seed, kind)
		multi.instance_count = spots.size()
		for i in spots.size():
			var dir: Vector3 = spots[i]
			var pos = dir * (radius + height_offset(dir))
			var basis = SpaceMath.basis_from_up_forward(dir, Vector3(rng.randf_range(-1.0, 1.0), 0.2, rng.randf_range(-1.0, 1.0)))
			var scale = rng.randf_range(0.55, 1.8)
			basis = basis.scaled(Vector3(scale, scale, scale))
			multi.set_instance_transform(i, Transform3D(basis, pos))
		var node = MultiMeshInstance3D.new()
		node.multimesh = multi
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.layers = visual_layer
		foliage.add_child(node)

func _plant_spots(kind: int, count: int) -> Array[Vector3]:
	var spots: Array[Vector3] = []
	var limit = count * 24
	var offset = kind * limit
	var guard = 0
	while spots.size() < count and guard < limit:
		var dir = _foliage_dir(offset + guard, limit * 3)
		if _surface_sample(dir).plains > 0.58:
			spots.append(dir)
		guard += 1
	return spots

func _foliage_dir(index: int, total: int) -> Vector3:
	var y = 1.0 - (float(index) + 0.5) / float(total) * 2.0
	var phi = 2.399963229728653 * float(index)
	var radial = sqrt(maxf(0.0, 1.0 - y * y))
	return Vector3(cos(phi) * radial, y, sin(phi) * radial)

func _plant_mesh(seed: int, kind: int) -> ArrayMesh:
	var plains: Array = terrain_profile.plains
	var tint: Color = plains[0].lerp(plains[1], 0.62).lerp(plains[2], float(kind) * 0.18)
	tint = tint.lightened(0.04 + float(seed % 3) * 0.02)
	var tool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	if kind == 0:
		_plant_spike(tool, 1.1 + float(seed % 3) * 0.35)
	elif kind == 1:
		_plant_fan(tool, seed)
	else:
		_plant_bulb(tool)
	tool.generate_normals()
	var mesh = tool.commit()
	var material = SpaceMath.make_material(tint)
	material.roughness = 0.84
	mesh.surface_set_material(0, material)
	return mesh

func _plant_spike(tool: SurfaceTool, height: float) -> void:
	var tip = Vector3(0.0, height * 4.2, 0.0)
	for i in 5:
		var a0 = TAU * float(i) / 5.0
		var a1 = TAU * float(i + 1) / 5.0
		var p0 = Vector3(cos(a0) * 0.35, 0.0, sin(a0) * 0.35)
		var p1 = Vector3(cos(a1) * 0.35, 0.0, sin(a1) * 0.35)
		tool.add_vertex(p0)
		tool.add_vertex(p1)
		tool.add_vertex(tip)
		tool.add_vertex(Vector3.ZERO)
		tool.add_vertex(p0)
		tool.add_vertex(p1)

func _plant_fan(tool: SurfaceTool, seed: int) -> void:
	var stem = 2.4 + float(seed % 2)
	tool.add_vertex(Vector3(-0.08, 0.0, 0.0))
	tool.add_vertex(Vector3(0.08, 0.0, 0.0))
	tool.add_vertex(Vector3(0.0, stem, 0.0))
	for i in 4:
		var yaw = float(i) * TAU / 4.0 + float(seed)
		var arm = Vector3(cos(yaw), 0.15, sin(yaw)) * (1.6 + float(i % 2) * 0.5)
		var tip = Vector3(0.0, stem, 0.0) + arm + Vector3(0.0, 0.8, 0.0)
		var side = arm.cross(Vector3.UP).normalized() * 0.55
		var base = Vector3(0.0, stem * 0.72, 0.0)
		tool.add_vertex(base)
		tool.add_vertex(base + side)
		tool.add_vertex(tip)

func _plant_bulb(tool: SurfaceTool) -> void:
	var top = Vector3(0.0, 2.2, 0.0)
	for i in 6:
		var a0 = TAU * float(i) / 6.0
		var a1 = TAU * float(i + 1) / 6.0
		var p0 = Vector3(cos(a0) * 0.7, 0.9, sin(a0) * 0.7)
		var p1 = Vector3(cos(a1) * 0.7, 0.9, sin(a1) * 0.7)
		tool.add_vertex(Vector3(0.0, 0.15, 0.0))
		tool.add_vertex(p1)
		tool.add_vertex(p0)
		tool.add_vertex(p0)
		tool.add_vertex(p1)
		tool.add_vertex(top)

func _mesh_radius_local(dir: Vector3) -> float:
	var phi = acos(clampf(dir.y, -1.0, 1.0))
	var theta = atan2(dir.z, dir.x)
	if theta < 0.0:
		theta += TAU
	var fy = phi / PI * float(MESH_RINGS)
	var fx = theta / TAU * float(MESH_SEGS)
	var y0 = clampi(int(floor(fy)), 0, MESH_RINGS - 1)
	var x0 = posmod(int(floor(fx)), MESH_SEGS)
	var a = _grid_vertex(x0, y0)
	var b = _grid_vertex(x0 + 1, y0)
	var c = _grid_vertex(x0, y0 + 1)
	var d = _grid_vertex(x0 + 1, y0 + 1)
	var frac_x = fx - floor(fx)
	var frac_y = fy - floor(fy)
	var hit = -1.0
	if frac_x + frac_y <= 1.0:
		hit = _ray_triangle(dir, a, c, b)
	else:
		hit = _ray_triangle(dir, b, c, d)
	if hit < 0.0:
		hit = _ray_triangle(dir, a, c, b)
	if hit < 0.0:
		hit = _ray_triangle(dir, b, c, d)
	if hit < 0.0:
		return radius + height_offset(dir)
	return hit

func _ray_triangle(dir: Vector3, a: Vector3, b: Vector3, c: Vector3) -> float:
	var edge1 = b - a
	var edge2 = c - a
	var pvec = dir.cross(edge2)
	var det = edge1.dot(pvec)
	if absf(det) < 0.0000001:
		return -1.0
	var inv = 1.0 / det
	var tvec = -a
	var u = tvec.dot(pvec) * inv
	if u < -0.002 or u > 1.002:
		return -1.0
	var qvec = tvec.cross(edge1)
	var v = dir.dot(qvec) * inv
	if v < -0.002 or u + v > 1.002:
		return -1.0
	var t = edge2.dot(qvec) * inv
	if t <= 0.0:
		return -1.0
	return t

func _build_atmosphere(seed: int) -> void:
	var height_frac = 0.55
	var min_height = 400.0
	atmo_drag = 1.0
	match seed:
		0:
			height_frac = 0.4
			min_height = 260.0
			atmo_drag = 0.55
		1:
			height_frac = 0.72
			min_height = 520.0
			atmo_drag = 1.2
		2:
			height_frac = 0.34
			min_height = 200.0
			atmo_drag = 0.7
		3:
			height_frac = 0.64
			min_height = 480.0
			atmo_drag = 1.3
		4:
			height_frac = 0.28
			min_height = 140.0
			atmo_drag = 0.6
	var shell_r = radius + amplitude + maxf(min_height, radius * height_frac)
	atmo_shell = shell_r
	var shell = MeshInstance3D.new()
	var ball = SphereMesh.new()
	ball.radius = shell_r
	ball.height = shell_r * 2.0
	ball.radial_segments = 48
	ball.rings = 24
	shell.mesh = ball
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	atmo_mat = ShaderMaterial.new()
	atmo_mat.shader = load("res://shaders/atmosphere.gdshader")
	var day = Color(0.95, 0.72, 0.45)
	var night = Color(0.16, 0.12, 0.32)
	match seed:
		0:
			day = Color(0.98, 0.78, 0.46)
			night = Color(0.2, 0.16, 0.42)
		1:
			day = Color(0.42, 0.86, 0.9)
			night = Color(0.08, 0.18, 0.38)
		2:
			day = Color(0.72, 0.58, 0.98)
			night = Color(0.14, 0.1, 0.34)
		_:
			day = Color(0.96, 0.58, 0.34)
			night = Color(0.28, 0.1, 0.24)
	atmo_mat.set_shader_parameter("day_color", day)
	atmo_mat.set_shader_parameter("night_color", night)
	atmo_mat.set_shader_parameter("planet_radius", radius)
	atmo_mat.set_shader_parameter("shell_radius", shell_r)
	atmo_mat.set_shader_parameter("sun_dir", Vector3.RIGHT)
	shell.material_override = atmo_mat
	add_child(shell)

func _aim_atmosphere() -> void:
	if atmo_mat == null or system == null:
		return
	var to_sun = system.global_position - global_position
	if to_sun.length_squared() < 1.0:
		return
	atmo_mat.set_shader_parameter("sun_dir", to_sun.normalized())

func _build_star_light() -> void:
	star_light = DirectionalLight3D.new()
	star_light.top_level = true
	star_light.light_color = Color(1.0, 0.95, 0.86)
	star_light.light_energy = 0.72
	star_light.shadow_enabled = false
	star_light.light_cull_mask = visual_layer
	star_light.shadow_caster_mask = visual_layer
	star_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	star_light.directional_shadow_max_distance = 900.0
	star_light.directional_shadow_split_1 = 0.18
	star_light.directional_shadow_blend_splits = true
	star_light.shadow_bias = 0.06
	star_light.shadow_normal_bias = 0.8
	star_light.shadow_blur = 0.35
	star_light.light_angular_distance = 2.0
	add_child(star_light)

func _aim_star_light() -> void:
	if star_light == null or system == null:
		return
	var dir = global_position - system.global_position
	var dist = dir.length()
	if dist < 1.0:
		return
	var aim = dir / dist
	var up = Vector3.UP
	if absf(aim.dot(up)) > 0.98:
		up = Vector3.RIGHT
	star_light.global_basis = Basis.looking_at(aim, up)
	var apparent = rad_to_deg(2.0 * asin(clampf(system.star_radius / dist, 0.0, 0.999)))
	star_light.light_angular_distance = clampf(apparent * 0.15, 0.6, 2.0)

func _terrain_mesh(segs: int, rings: int, x_from: int, x_to: int, y_from: int, y_to: int) -> ArrayMesh:
	var x_count = x_to - x_from + 1
	var y_count = y_to - y_from + 1
	var verts = PackedVector3Array()
	var normals = PackedVector3Array()
	var custom0 = PackedFloat32Array()
	var custom1 = PackedFloat32Array()
	verts.resize(x_count * y_count)
	normals.resize(verts.size())
	custom0.resize(verts.size() * 4)
	custom1.resize(verts.size() * 2)
	for iy in y_count:
		for ix in x_count:
			var index = iy * x_count + ix
			var dir = _unit_dir(x_from + ix, y_from + iy, segs, rings)
			var sample = _surface_sample(dir)
			verts[index] = dir * (radius + sample.height)
			var i4 = index * 4
			custom0[i4] = sample.plains
			custom0[i4 + 1] = sample.desert
			custom0[i4 + 2] = sample.ice
			custom0[i4 + 3] = sample.ocean
			var i2 = index * 2
			custom1[i2] = sample.lake
			custom1[i2 + 1] = sample.mountain
	for iy in y_count:
		for ix in x_count:
			var index = iy * x_count + ix
			normals[index] = _seam_normal(x_from + ix, y_from + iy, segs, rings)
	var quads_x = x_count - 1
	var quads_y = y_count - 1
	var indices = PackedInt32Array()
	indices.resize(quads_x * quads_y * 6)
	var cursor = 0
	for iy in quads_y:
		for ix in quads_x:
			var a = iy * x_count + ix
			var b = a + 1
			var c = a + x_count
			var d = c + 1
			indices[cursor] = a
			indices[cursor + 1] = c
			indices[cursor + 2] = b
			indices[cursor + 3] = b
			indices[cursor + 4] = c
			indices[cursor + 5] = d
			cursor += 6
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_CUSTOM0] = custom0
	arrays[Mesh.ARRAY_CUSTOM1] = custom1
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh = ArrayMesh.new()
	var flags = (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RG_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	return mesh

func _seam_normal(x: int, y: int, segs: int, rings: int) -> Vector3:
	var west = x - 1
	if west < 0:
		west = segs - 1
	var east = x + 1
	if east > segs:
		east = 1
	var north = maxi(y - 1, 0)
	var south = mini(y + 1, rings)
	var center = _sphere_vertex(x, y, segs, rings)
	var nrm = (_sphere_vertex(east, y, segs, rings) - _sphere_vertex(west, y, segs, rings)).cross(
		_sphere_vertex(x, south, segs, rings) - _sphere_vertex(x, north, segs, rings)
	)
	if nrm.length_squared() < 0.000001:
		return center.normalized()
	if nrm.dot(center) < 0.0:
		nrm = -nrm
	return nrm.normalized()

func carried_velocity(world_pos: Vector3) -> Vector3:
	# How this point actually moved with the planet this step. The analytic surface
	# velocity has a large radial part that does not match that step.
	var dt = 1.0 / float(Engine.physics_ticks_per_second)
	var local = global_transform.affine_inverse() * world_pos
	var previous = Transform3D(prev_basis, prev_position) * local
	var now = global_transform * local
	return (now - previous) / maxf(dt, 0.0001)

func transport_point(world_pos: Vector3) -> Vector3:
	# world_pos is where something was before this step's planet update.
	var previous := Transform3D(prev_basis, prev_position)
	return global_transform * (previous.affine_inverse() * world_pos)

func surface_velocity_at(world_pos: Vector3) -> Vector3:
	var local: Vector3 = global_basis.inverse() * (world_pos - global_position)
	var time = system.sim_time if system else 0.0
	var eps = 0.02
	var before = location_at(time - eps) + rotation_at(time - eps) * local
	var after = location_at(time + eps) + rotation_at(time + eps) * local
	return (after - before) / (2.0 * eps)
