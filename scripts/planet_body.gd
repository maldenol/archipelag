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
	var material = SpaceMath.make_material(Color.WHITE)
	var tex = SpaceMath.surface_textures(seed, color)
	material.albedo_texture = tex.albedo
	material.albedo_color = Color.WHITE
	material.vertex_color_use_as_albedo = true
	material.normal_enabled = true
	material.normal_texture = tex.normal
	material.roughness_texture = tex.rough
	material.uv1_triplanar = true
	material.uv1_world_triplanar = false
	material.uv1_scale = Vector3(0.08, 0.08, 0.08)
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
	noise = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5
	noise.seed = 4000 + seed * 97
	noise.frequency = 2.2 + float(seed % 4) * 0.7
	amplitude = radius * (0.028 + float(seed % 4) * 0.012)

func _grid_vertex(x: int, y: int) -> Vector3:
	return _sphere_vertex(x, y, MESH_SEGS, MESH_RINGS)

func _sphere_vertex(x: int, y: int, segs: int, rings: int) -> Vector3:
	var phi = float(y) / float(rings) * PI
	var theta = float(x) / float(segs) * TAU
	var dir = Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
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
	var rng = RandomNumberGenerator.new()
	rng.seed = 2500 + seed * 13
	for kind in 3:
		var multi = MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = _plant_mesh(seed, kind)
		multi.instance_count = 1600
		for i in multi.instance_count:
			var dir = _foliage_dir(kind * 1600 + i, 4800)
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

func _foliage_dir(index: int, total: int) -> Vector3:
	var y = 1.0 - (float(index) + 0.5) / float(total) * 2.0
	var phi = 2.399963229728653 * float(index)
	var radial = sqrt(maxf(0.0, 1.0 - y * y))
	return Vector3(cos(phi) * radial, y, sin(phi) * radial)

func _plant_mesh(seed: int, kind: int) -> ArrayMesh:
	var tint = color.lightened(0.15 + float(kind) * 0.08).lerp(Color(0.15, 0.35, 0.12), 0.25 if seed == 1 else 0.05)
	if seed == 0:
		tint = color.lightened(0.2).lerp(Color(0.35, 0.12, 0.05), float(kind) * 0.25)
	elif seed == 2:
		tint = Color(0.75, 0.88, 0.95).lerp(color, 0.35 + float(kind) * 0.1)
	elif seed == 3:
		tint = color.darkened(0.1).lerp(Color(0.45, 0.32, 0.18), float(kind) * 0.2)
	elif seed == 4:
		tint = color.lightened(0.05).lerp(Color(0.4, 0.16, 0.08), float(kind) * 0.3)
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
	var colors = PackedColorArray()
	verts.resize(x_count * y_count)
	normals.resize(verts.size())
	colors.resize(verts.size())
	var low = color.darkened(0.42)
	var high = color.lightened(0.28)
	for iy in y_count:
		for ix in x_count:
			var index = iy * x_count + ix
			var point = _sphere_vertex(x_from + ix, y_from + iy, segs, rings)
			verts[index] = point
			var sample = 0.0
			if point.length() > 1.0 and amplitude > 0.001:
				sample = (point.length() - radius) / amplitude
			colors[index] = low.lerp(high, clampf(sample * 0.5 + 0.5, 0.0, 1.0))
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
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _terrain_paint(seed: int) -> Array[Color]:
	match seed:
		0:
			return [Color(0.95, 0.38, 0.06), Color(0.42, 0.08, 0.02), Color(0.82, 0.78, 0.7), Color(0.1, 0.09, 0.08)]
		1:
			return [Color(0.55, 0.9, 0.28), Color(0.05, 0.28, 0.08), Color(0.9, 0.78, 0.35), Color(0.18, 0.1, 0.04)]
		2:
			return [Color(0.92, 0.97, 1.0), Color(0.25, 0.45, 0.72), Color(0.55, 0.62, 0.78), Color(0.08, 0.1, 0.18)]
		3:
			return [Color(0.86, 0.28, 0.16), Color(0.28, 0.05, 0.06), Color(0.78, 0.62, 0.4), Color(0.12, 0.07, 0.05)]
		_:
			return [Color(0.92, 0.62, 0.22), Color(0.32, 0.14, 0.05), Color(0.7, 0.68, 0.64), Color(0.08, 0.07, 0.07)]

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
