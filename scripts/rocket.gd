extends RigidBody3D

const SpaceMath = preload("res://scripts/space_math.gd")

const MASS = 6500.0
const DRAG_AREA = 22.0
const THRUST = 26.0
const CAM_YAW_SENS = 0.003
const CAM_PITCH_SENS = 0.0026
const ANG_ACCEL = 2.0
const ANG_DAMP = 1.5
const PARK_CLEARANCE = 1.65
const SUPPORT_DOT = 0.76
const ZOOM_MIN = 2.5
const ZOOM_MAX = 300.0
const FOOT_OFFSETS: Array[Vector3] = [
	Vector3(1.42, 0.0, 1.65),
	Vector3(-1.42, 0.0, 1.65),
	Vector3(0.0, 1.42, 1.65),
	Vector3(0.0, -1.42, 1.65),
]

var system
var parked
var landed = true
var flying = false
var thrust_held = false
var exploded = false
var health = 200.0
var max_health = 200.0
var pilot_torque = Vector3.ZERO
var hull_impact = 0.0
var leg_impact = 0.0
var impact_lock = 0.0
var hull_touch = false
var motion_velocity = Vector3.ZERO
var motion_sample = Vector3.ZERO
var motion_ready = false
var hold_basis = Basis.IDENTITY
var hold_ready = false
var want_land = null
var carried = false
var ground_xform = Transform3D.IDENTITY
var liftoff = 0.0
var liftoff_speed = 0.0
# Offset from the rocket's own basis. Identity looks back along the tail.
var cam_quat = Quaternion(Vector3.UP, 0.35) * Quaternion(Vector3.RIGHT, -0.55)
var accum = 0.0
var hurt_time = -100.0
var f_held = false
var attitude = ""
var cam_on_hull = true

var spring: Node3D
var camera: Camera3D
var cam_distance = 9.0
var cam_pivot: Node3D
var flame: MeshInstance3D
var hull_root: Node3D
var engine: Node3D
var killed_by_star = false
var foot_shape_ids: Array[int] = []
var shape_serial = 0

func _ready() -> void:
	process_physics_priority = 1
	mass = MASS
	gravity_scale = 0.0
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp = 0.0
	can_sleep = false
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 8
	collision_layer = 4
	collision_mask = 1 | 2
	var grip = PhysicsMaterial.new()
	grip.friction = 0.9
	grip.bounce = 0.05
	physics_material_override = grip
	_build_hull()
	_build_collision()
	cam_pivot = Node3D.new()
	cam_pivot.top_level = true
	add_child(cam_pivot)
	spring = Node3D.new()
	cam_pivot.add_child(spring)
	camera = Camera3D.new()
	camera.fov = 70.0
	camera.near = 0.05
	camera.far = 250000.0
	spring.add_child(camera)

func bind_system(host) -> void:
	system = host

func _build_hull() -> void:
	hull_root = Node3D.new()
	# Shift the mesh so the center of mass sits on the body's origin.
	hull_root.position = Vector3(0.0, 0.0, 0.15)
	add_child(hull_root)
	var hull = Color(0.72, 0.78, 0.84)
	var dark = Color(0.18, 0.2, 0.24)
	var accent = Color(0.85, 0.35, 0.18)
	var body = CylinderMesh.new()
	body.top_radius = 0.38
	body.bottom_radius = 0.38
	body.height = 2.05
	body.radial_segments = 24
	var fuselage = _part(hull_root, body, Vector3(0, 0, -0.2), Vector3(PI * 0.5, 0, 0), hull)
	fuselage.rotation.x = PI * 0.5
	var nose = CylinderMesh.new()
	nose.top_radius = 0.0
	nose.bottom_radius = 0.38
	nose.height = 0.62
	nose.radial_segments = 24
	var nose_mesh = _part(hull_root, nose, Vector3(0, 0, -1.535), Vector3(-PI * 0.5, 0, 0), hull)
	nose_mesh.rotation.x = -PI * 0.5
	var band = CylinderMesh.new()
	band.top_radius = 0.42
	band.bottom_radius = 0.42
	band.height = 0.08
	band.radial_segments = 24
	var band_mesh = _part(hull_root, band, Vector3(0, 0, -0.55), Vector3(PI * 0.5, 0, 0), accent)
	band_mesh.rotation.x = PI * 0.5
	for i in 4:
		var leg = Node3D.new()
		leg.rotation.z = float(i) * TAU * 0.25
		hull_root.add_child(leg)
		var hip = Vector3(0.4, 0.0, 0.7)
		var foot = Vector3(1.42, 0.0, 1.46)
		var delta = foot - hip
		var strut = BoxMesh.new()
		strut.size = Vector3(0.09, 0.09, delta.length())
		var strut_mesh = _part(leg, strut, hip + delta * 0.5, Vector3.ZERO, dark)
		strut_mesh.basis = Basis.looking_at(delta.normalized(), Vector3.UP)
		var pad = BoxMesh.new()
		pad.size = Vector3(0.5, 0.32, 0.08)
		_part(leg, pad, foot, Vector3.ZERO, dark)
	engine = Node3D.new()
	engine.position = Vector3(0, 0, 0.82)
	hull_root.add_child(engine)
	var bell = CylinderMesh.new()
	bell.top_radius = 0.36
	bell.bottom_radius = 0.2
	bell.height = 0.32
	bell.radial_segments = 20
	var bell_mesh = _part(engine, bell, Vector3(0, 0, 0.16), Vector3(PI * 0.5, 0, 0), dark)
	bell_mesh.rotation.x = PI * 0.5
	var exhaust = CylinderMesh.new()
	exhaust.top_radius = 0.26
	exhaust.bottom_radius = 0.08
	exhaust.height = 0.9
	exhaust.radial_segments = 12
	flame = _part(hull_root, exhaust, Vector3(0, 0, 1.28), Vector3(PI * 0.5, 0, 0), Color(1.0, 0.55, 0.15), 4.0)
	flame.rotation.x = PI * 0.5
	flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flame.visible = false

func _part(parent: Node3D, mesh: Mesh, at: Vector3, _rot: Vector3, color: Color, emission: float = 0.0) -> MeshInstance3D:
	var node = MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var material = SpaceMath.make_material(color, emission)
	if emission <= 0.0:
		material.roughness = 0.96
		material.metallic = 0.0
		material.metallic_specular = 0.1
	node.material_override = material
	parent.add_child(node)
	return node

func _build_collision() -> void:
	# CapsuleShape3D runs along Y. Tip it onto the hull axis, nose toward -Z.
	var hull = CapsuleShape3D.new()
	hull.radius = 0.4
	hull.height = 2.8
	var hull_shape = CollisionShape3D.new()
	hull_shape.shape = hull
	hull_shape.position = Vector3(0.0, 0.0, -0.2)
	hull_shape.rotation.x = PI * 0.5
	add_child(hull_shape)
	_track_shape(false)
	for i in 4:
		var turn = Quaternion(Vector3(0.0, 0.0, 1.0), float(i) * TAU * 0.25)
		var hip = Vector3(0.42, 0.0, 0.85)
		var foot = Vector3(1.35, 0.0, 1.58)
		var delta = foot - hip
		var leg = CapsuleShape3D.new()
		leg.radius = 0.07
		leg.height = delta.length()
		var leg_shape = CollisionShape3D.new()
		leg_shape.shape = leg
		leg_shape.position = turn * ((hip + foot) * 0.5)
		var aim = (turn * delta).normalized()
		if aim.length_squared() > 0.5 and absf(aim.dot(Vector3.UP)) < 0.98:
			leg_shape.basis = Basis(Quaternion(Vector3.UP, aim))
		add_child(leg_shape)
		_track_shape(true)
		var pad = BoxShape3D.new()
		pad.size = Vector3(0.42, 0.26, 0.08)
		var pad_shape = CollisionShape3D.new()
		pad_shape.shape = pad
		pad_shape.position = turn * Vector3(1.35, 0.0, 1.62)
		pad_shape.basis = Basis(turn)
		add_child(pad_shape)
		_track_shape(true)

func _track_shape(is_foot: bool) -> void:
	if is_foot:
		foot_shape_ids.append(shape_serial)
	shape_serial += 1

func park_on(planet) -> void:
	if planet == null or exploded:
		return
	var normal = (global_position - planet.global_position).normalized()
	if normal.length_squared() < 0.5:
		normal = Vector3.RIGHT
	var ahead = (-global_basis.z).slide(normal).normalized()
	if ahead.length_squared() < 0.001:
		ahead = global_basis.x.slide(normal).normalized()
	if ahead.length_squared() < 0.001:
		ahead = normal.cross(Vector3.UP).normalized()
	# Nose is -Z and points straight out, so the engine and its legs sit on the ground.
	var z_axis = -normal
	var x_axis = ahead.slide(normal).normalized()
	if x_axis.length_squared() < 0.001:
		x_axis = normal.cross(Vector3.FORWARD).normalized()
	var roof = z_axis.cross(x_axis).normalized()
	var parked_pos = planet.global_position + normal * (planet.mesh_radius_world(normal) + PARK_CLEARANCE + 0.12)
	global_transform = Transform3D(Basis(x_axis, roof, z_axis).orthonormalized(), parked_pos)
	landed = true
	flying = false
	parked = planet
	angular_velocity = Vector3.ZERO
	linear_velocity = Vector3.ZERO
	collision_mask = 0
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	carried = true
	ground_xform = planet.global_transform.affine_inverse() * global_transform

func apply_damage(amount: float, source: Node) -> void:
	if exploded or amount <= 0.0:
		return
	health = maxf(0.0, health - amount)
	hurt_time = Time.get_ticks_msec() / 1000.0
	if amount >= 1.0 and system != null and system.sound != null:
		system.sound.play("hurt")
	if health <= 0.0:
		killed_by_star = source == system
		explode()

func explode() -> void:
	if exploded:
		return
	exploded = true
	flying = false
	landed = true
	thrust_held = false
	if hull_root:
		hull_root.visible = false
	_spawn_explosion()
	if system:
		if system.sound:
			system.sound.play("boom")
		system.begin_death()

func world_velocity() -> Vector3:
	return linear_velocity

func predict(horizon: float, step: float) -> Dictionary:
	var path = {"points": [], "samples": [], "hit": false, "impact": Vector3.ZERO, "impact_name": ""}
	if system == null or horizon <= 0.0 or step <= 0.0:
		return path
	if landed and parked:
		var local: Vector3 = parked.global_basis.inverse() * (global_position - parked.global_position)
		var count = clampi(int(horizon / step), 2, 900)
		for i in count + 1:
			var time = system.sim_time + step * float(i)
			var point = parked.location_at(time) + parked.rotation_at(time) * local
			path.points.append(point)
			path.samples.append({"pos": point, "vel": Vector3.ZERO, "time": time})
		return path
	var pos = global_position
	var vel = linear_velocity
	var count = clampi(int(horizon / step), 2, 900)
	var time = system.sim_time
	path.points.append(pos)
	path.samples.append({"pos": pos, "vel": vel, "time": time})
	for _i in count:
		# Coast on the current velocity. Gravity bends the path. Thrust and air do not.
		var result = SpaceMath.integrate(system.bodies_at(time), pos, vel, Vector3.ZERO, step)
		pos = result.position
		vel = result.velocity
		time += step
		path.points.append(pos)
		path.samples.append({"pos": pos, "vel": vel, "time": time})
		if result.hit:
			path.hit = true
			path.impact = result.position
			path.impact_name = result.name
			break
	return path

func _unhandled_input(event: InputEvent) -> void:
	if system == null or system.controlled != self or exploded:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion = event as InputEventMouseMotion
		var yaw = -motion.relative.x * CAM_YAW_SENS
		var pitch = -motion.relative.y * CAM_PITCH_SENS
		if system.map_expanded:
			system.orbit_map(yaw, pitch)
		else:
			cam_quat = (cam_quat * Quaternion(Vector3.UP, yaw) * Quaternion(Vector3.RIGHT, pitch)).normalized()
	elif event is InputEventMouseButton and event.pressed:
		var button = event as InputEventMouseButton
		if system.map_expanded:
			if button.button_index == MOUSE_BUTTON_WHEEL_UP:
				system.zoom_map(false)
			elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				system.zoom_map(true)
		elif button.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_distance = clampf(cam_distance / 1.12, ZOOM_MIN, ZOOM_MAX)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_distance = clampf(cam_distance * 1.12, ZOOM_MIN, ZOOM_MAX)
	elif event is InputEventKey and event.pressed and not event.echo:
		var key = (event as InputEventKey).physical_keycode
		if key == KEY_P:
			attitude = "" if attitude == "prograde" else "prograde"
		elif key == KEY_R:
			attitude = "" if attitude == "retrograde" else "retrograde"
		elif key == KEY_COMMA:
			system.warp_slower()
		elif key == KEY_PERIOD:
			system.warp_faster()
		elif key == KEY_M:
			system.map_expanded = not system.map_expanded

func _place_camera() -> void:
	if cam_pivot == null:
		return
	var on_hull = landed and not flying
	var rocket_q = global_basis.get_rotation_quaternion()
	if on_hull != cam_on_hull:
		if on_hull:
			cam_quat = (rocket_q.inverse() * cam_quat).normalized()
		else:
			cam_quat = (rocket_q * cam_quat).normalized()
		cam_on_hull = on_hull
	var world_q = rocket_q * cam_quat if on_hull else cam_quat
	cam_pivot.global_position = global_position
	cam_pivot.global_basis = Basis(world_q)
	_seat_camera()

func _seat_camera() -> void:
	if spring == null or camera == null:
		return
	var local_aim = Vector3(0.0, 0.0, cam_distance)
	var origin = cam_pivot.global_position
	var want = cam_pivot.global_transform * local_aim
	var query = PhysicsRayQueryParameters3D.create(origin, want)
	query.collision_mask = 1
	query.exclude = [get_rid()]
	var hit = get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var span = maxf(origin.distance_to(want), 0.001)
		var keep = origin.distance_to(hit.position) - 0.45
		local_aim *= clampf(keep / span, 0.2, 1.0)
	camera.position = local_aim

func _process(_delta: float) -> void:
	_place_camera()
	if flame == null:
		return
	flame.visible = thrust_held and not exploded
	if engine:
		engine.rotation.z = engine.rotation.z + (18.0 if thrust_held else 0.4) * _delta
	if not thrust_held:
		return
	var flicker = 0.82 + 0.28 * sin(Time.get_ticks_msec() * 0.05)
	flame.scale = Vector3(flicker, 0.7 + flicker, flicker)

func _physics_process(delta: float) -> void:
	if system == null or exploded:
		return
	var piloting = system.controlled == self
	var f_down = Input.is_physical_key_pressed(KEY_F)
	if piloting and f_down and not f_held:
		f_held = true
		system.try_board()
		return
	f_held = f_down
	thrust_held = piloting and Input.is_physical_key_pressed(KEY_SPACE)
	pilot_torque = Vector3.ZERO
	if piloting:
		if Input.is_physical_key_pressed(KEY_W):
			pilot_torque.x -= 1.0
		if Input.is_physical_key_pressed(KEY_S):
			pilot_torque.x += 1.0
		if Input.is_physical_key_pressed(KEY_A):
			pilot_torque.y += 1.0
		if Input.is_physical_key_pressed(KEY_D):
			pilot_torque.y -= 1.0
		if Input.is_physical_key_pressed(KEY_Q):
			pilot_torque.z += 1.0
		if Input.is_physical_key_pressed(KEY_E):
			pilot_torque.z -= 1.0
		if pilot_torque.length_squared() > 0.0001:
			attitude = ""
			hold_ready = false
		if (not hold_ready or thrust_held) and not system.warp_factor() == 1:
			system.warp_default()
	impact_lock = maxf(impact_lock - delta, 0.0)
	if flying and not freeze:
		_note_touchdown()
		if _hull_in_ground():
			hull_touch = true
	if hull_touch:
		hull_touch = false
		apply_damage(max_health + 1.0, null)
		return
	if impact_lock > 0.0:
		leg_impact = 0.0
	elif leg_impact > 10.0:
		var hit = leg_impact
		leg_impact = 0.0
		impact_lock = 0.45
		apply_damage(max_health * (hit - 10.0) / 40.0, null)
		if exploded:
			return
	if want_land != null and not thrust_held:
		if _hull_in_ground():
			explode()
			return
		parked = want_land
		landed = true
		flying = false
		want_land = null
	if not piloting:
		thrust_held = false
	if landed and not flying and parked != null and not thrust_held:
		angular_velocity = Vector3.ZERO
		liftoff = 0.0
		liftoff_speed = 0.0
		if not carried:
			var keep = global_transform
			carried = true
			freeze = true
			freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
			collision_mask = 0
			global_transform = keep
			ground_xform = parked.global_transform.affine_inverse() * keep
		else:
			global_transform = parked.global_transform * ground_xform
			collision_mask = 0
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		system.apply_star_exposure(self, global_position, delta)
		return
	if thrust_held and landed and parked != null:
		# Stay kinematic until the feet are clear. A contact with the trimesh pins the hull.
		if not carried:
			carried = true
			freeze = true
			freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
			ground_xform = parked.global_transform.affine_inverse() * global_transform
		else:
			global_transform = parked.global_transform * ground_xform
		var radial = global_position - parked.global_position
		var up = radial.normalized() if radial.length_squared() > 1.0 else Vector3.UP
		liftoff_speed += (THRUST - parked.surface_gravity) * delta
		liftoff += liftoff_speed * delta
		var base = parked.mesh_radius_world(radial) + PARK_CLEARANCE + 0.12
		global_position = parked.global_position + up * (base + liftoff)
		linear_velocity = parked.carried_velocity(global_position) + up * liftoff_speed
		ground_xform = parked.global_transform.affine_inverse() * global_transform
		angular_velocity = Vector3.ZERO
		if liftoff > 2.5:
			_launch()
		else:
			system.apply_star_exposure(self, global_position, delta)
			return
	var accel = system.acceleration_at(global_position)
	accel += system.drag_acceleration(global_position, linear_velocity, DRAG_AREA, MASS, delta)
	if thrust_held:
		accel += -global_basis.z * THRUST
	if piloting and not freeze:
		if pilot_torque.length_squared() > 0.0001:
			apply_torque(global_basis * pilot_torque * 28000.0)
		elif attitude == "":
			if not hold_ready:
				hold_basis = global_basis
				hold_ready = true
			_torque_toward(hold_basis, true)
		else:
			hold_ready = false
			_steer_attitude(delta)
	apply_central_force(accel * mass)
	system.apply_star_exposure(self, global_position, delta)
	if motion_ready:
		motion_velocity = (global_position - motion_sample) / maxf(delta, 0.0001)
	motion_sample = global_position
	motion_ready = true

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if exploded or system == null:
		return
	var worst_leg = 0.0
	var ground = null
	var foot_hits = 0
	for i in state.get_contact_count():
		var other = state.get_contact_collider_object(i)
		if other == null or other == system.player:
			continue
		var on_world = system.planets.has(other) or (other is Node and (other as Node).is_in_group("star"))
		if not on_world:
			continue
		ground = other
		var ride = Vector3.ZERO
		if other.has_method("carried_velocity"):
			ride = other.carried_velocity(state.transform.origin)
		var radial = state.transform.origin - ground.global_position
		var sink = 0.0
		if radial.length_squared() > 1.0:
			sink = maxf(-(state.linear_velocity - ride).dot(radial.normalized()), 0.0)
		# Only the leg struts and pads may touch. Hull, nose, and tail are fatal.
		var shape_id = state.get_contact_local_shape(i)
		if foot_shape_ids.has(shape_id):
			foot_hits += 1
			worst_leg = maxf(worst_leg, sink)
		else:
			hull_touch = true
	if flying and worst_leg > leg_impact:
		leg_impact = worst_leg
	if ground != null and ground.has_method("surface_velocity_at") and foot_hits > 0 and not thrust_held:
		var up = state.transform.origin - ground.global_position
		if up.length_squared() < 1.0:
			return
		up = up.normalized()
		var ride = ground.surface_velocity_at(state.transform.origin)
		var calm = state.angular_velocity.length() < 0.45
		calm = calm and (state.linear_velocity - ride).length() < 2.0
		calm = calm and (-state.transform.basis.z).dot(up) > SUPPORT_DOT
		if calm and _feet_planted(ground):
			want_land = ground

func _note_touchdown() -> void:
	var planet = null
	var nearest = INF
	for body in system.planets:
		var alt = global_position.distance_to(body.global_position) - body.radius
		if alt < nearest:
			nearest = alt
			planet = body
	if planet == null or nearest > 30.0:
		return
	var up = (global_position - planet.global_position).normalized()
	var sink = maxf(-(linear_velocity - planet.carried_velocity(global_position)).dot(up), 0.0)
	var space = get_world_3d().direct_space_state
	if space == null:
		return
	for dir in [Vector3(0.0, 0.0, -1.55), Vector3(0.62, 0.0, 0.0), Vector3(-0.62, 0.0, 0.0), Vector3(0.0, 0.62, 0.0), Vector3(0.0, -0.62, 0.0)]:
		var query = PhysicsRayQueryParameters3D.create(global_position, global_position + global_basis * dir)
		query.collision_mask = 1
		query.exclude = [get_rid()]
		if not space.intersect_ray(query).is_empty():
			hull_touch = true
			return
	var feet = 0
	for offset in FOOT_OFFSETS:
		var origin = global_position + global_basis * offset
		var query = PhysicsRayQueryParameters3D.create(origin, origin - up * 0.9)
		query.collision_mask = 1
		query.exclude = [get_rid()]
		if not space.intersect_ray(query).is_empty():
			feet += 1
	if feet > 0:
		leg_impact = maxf(leg_impact, sink)

func _hull_in_ground() -> bool:
	if system == null:
		return false
	var planet = null
	var nearest = INF
	for body in system.planets:
		var alt = global_position.distance_to(body.global_position) - body.radius
		if alt < nearest:
			nearest = alt
			planet = body
	if planet == null or nearest > 8.0:
		return false
	# Skin of the fuselage, nose, and tail. The feet are farther out along +Z.
	var skin: Array[Vector3] = [
		Vector3(0.0, 0.0, -1.7),
		Vector3(0.4, 0.0, -1.25), Vector3(-0.4, 0.0, -1.25),
		Vector3(0.0, 0.4, -1.25), Vector3(0.0, -0.4, -1.25),
		Vector3(0.4, 0.0, -0.55), Vector3(-0.4, 0.0, -0.55),
		Vector3(0.0, 0.4, -0.55), Vector3(0.0, -0.4, -0.55),
		Vector3(0.4, 0.0, 0.15), Vector3(-0.4, 0.0, 0.15),
		Vector3(0.0, 0.4, 0.15), Vector3(0.0, -0.4, 0.15),
		Vector3(0.0, 0.0, 0.65),
	]
	var space = get_world_3d().direct_space_state
	for point in skin:
		var world = global_transform * point
		var radial = world - planet.global_position
		if radial.length_squared() < 1.0:
			continue
		if radial.length() < planet.mesh_radius_world(radial) + 0.18:
			return true
		if space == null:
			continue
		var outward = world - global_position
		if outward.length_squared() < 0.01:
			continue
		outward = outward.normalized()
		var query = PhysicsRayQueryParameters3D.create(world - outward * 0.25, world + outward * 0.2)
		query.collision_mask = 1
		query.exclude = [get_rid()]
		if not space.intersect_ray(query).is_empty():
			return true
	return false

func _feet_planted(planet) -> bool:
	var space = get_world_3d().direct_space_state
	if space == null:
		return false
	var down = (planet.global_position - global_position).normalized()
	for offset in FOOT_OFFSETS:
		var origin = global_position + global_basis * offset - down * 0.15
		var query = PhysicsRayQueryParameters3D.create(origin, origin + down * 0.7)
		query.collision_mask = 1
		query.exclude = [get_rid()]
		if space.intersect_ray(query).is_empty():
			return false
	return true

func nav_frame() -> Dictionary:
	var travel = world_velocity()
	var air = _air_planet()
	if air != null:
		var radial = global_position - air.global_position
		var up = radial.normalized() if radial.length_squared() > 1.0 else Vector3.UP
		return {"up": up, "velocity": travel - air.surface_velocity_at(global_position)}
	var body = null
	if system != null:
		body = system.dominant_at(global_position).planet
	if body != null:
		var radial = global_position - body.global_position
		var up = radial.normalized() if radial.length_squared() > 1.0 else Vector3.UP
		return {"up": up, "velocity": travel - body.center_velocity()}
	var from_star = global_position - system.global_position if system != null else Vector3.UP
	var up = from_star.normalized() if from_star.length_squared() > 1.0 else Vector3.UP
	return {"up": up, "velocity": travel}

func guidance_velocity() -> Vector3:
	return nav_frame().velocity

func _air_planet():
	if system == null:
		return null
	var best = null
	var best_depth = -1.0
	for planet in system.planets:
		if not planet.in_atmosphere(global_position):
			continue
		var depth = planet.atmo_shell - global_position.distance_to(planet.global_position)
		if depth > best_depth:
			best_depth = depth
			best = planet
	return best

func _steer_attitude(_delta: float) -> void:
	var travel = guidance_velocity()
	if travel.length_squared() < 0.64:
		_torque_toward(global_basis, true)
		return
	var nose = travel.normalized()
	if attitude == "retrograde":
		nose = -nose
	_torque_toward(_basis_facing(nose), false)

func _basis_facing(nose: Vector3) -> Basis:
	var z_axis = -nose.normalized()
	var roof = global_basis.y.slide(z_axis)
	if roof.length_squared() < 0.0004:
		roof = Vector3.UP.slide(z_axis)
	if roof.length_squared() < 0.0004:
		roof = global_basis.x
	roof = roof.normalized()
	var x_axis = roof.cross(z_axis).normalized()
	roof = z_axis.cross(x_axis).normalized()
	return Basis(x_axis, roof, z_axis)

func _torque_toward(target: Basis, lock_roll: bool) -> void:
	var q = global_basis.get_rotation_quaternion().inverse() * target.get_rotation_quaternion()
	if q.w < 0.0:
		q = -q
	var err = Vector3.ZERO
	var ang = q.get_angle()
	if ang > 0.0004:
		err = q.get_axis() * ang
	if not lock_roll:
		err.z = 0.0
	var spin = global_basis.inverse() * angular_velocity
	# Critically damped so the nose settles instead of swinging past the marker.
	var kp = 36.0
	var kd = 2.0 * sqrt(kp)
	var inv = _inverse_inertia()
	var local = Vector3(
		_axis_torque(err.x, spin.x, kp, kd, inv.x),
		_axis_torque(err.y, spin.y, kp, kd, inv.y),
		_axis_torque(err.z, spin.z, kp, kd, inv.z)
	)
	apply_torque(global_basis * local)

func _axis_torque(err: float, spin: float, kp: float, kd: float, inv: float) -> float:
	var inertia = 3200.0 if inv < 0.0000001 else 1.0 / inv
	return inertia * (kp * err - kd * spin)

func _inverse_inertia() -> Vector3:
	var state = PhysicsServer3D.body_get_direct_state(get_rid())
	if state == null:
		return Vector3.ZERO
	return state.inverse_inertia

func _launch() -> void:
	var inherited = linear_velocity
	if parked != null:
		var radial = global_position - parked.global_position
		var up = radial.normalized() if radial.length_squared() > 1.0 else Vector3.UP
		var ride = parked.carried_velocity(global_position)
		var climb = linear_velocity.dot(up) - ride.dot(up)
		inherited = ride + up * climb
	carried = false
	freeze = false
	collision_mask = 1 | 2
	linear_velocity = inherited
	angular_velocity = Vector3.ZERO
	landed = false
	flying = true
	parked = null
	hold_ready = false

func _spawn_explosion() -> void:
	var burst = _Explosion.new()
	burst.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(burst)

class _Explosion extends Node3D:
	var life = 2.2
	var duration = 2.2
	var shell: MeshInstance3D
	var core: MeshInstance3D
	var glow: OmniLight3D
	var bits: Array[MeshInstance3D] = []
	var velocities: Array[Vector3] = []

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		shell = _ball(Color(1.0, 0.42, 0.1, 0.8), Color(1.0, 0.35, 0.05), 3.5)
		core = _ball(Color(1.0, 0.92, 0.7, 0.95), Color(1.0, 0.85, 0.5), 6.0)
		add_child(shell)
		add_child(core)
		var shard_mat = _fire_material(Color(1.0, 0.55, 0.16, 1.0), Color(1.0, 0.4, 0.08), 2.5)
		var rng = RandomNumberGenerator.new()
		rng.randomize()
		for i in 20:
			var bit = MeshInstance3D.new()
			var box = BoxMesh.new()
			box.size = Vector3(0.16, 0.16, 0.7)
			bit.mesh = box
			bit.material_override = shard_mat
			bit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var dir = Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
			if dir.length_squared() < 0.01:
				dir = Vector3.UP
			dir = dir.normalized()
			bit.position = dir * 0.3
			bit.basis = Basis.looking_at(dir, Vector3.UP)
			add_child(bit)
			bits.append(bit)
			velocities.append(dir * rng.randf_range(8.0, 22.0))
		glow = OmniLight3D.new()
		glow.light_color = Color(1.0, 0.55, 0.2)
		glow.light_energy = 16.0
		glow.omni_range = 48.0
		glow.shadow_enabled = false
		add_child(glow)

	func _process(delta: float) -> void:
		life -= delta
		var fade = clampf(life / duration, 0.0, 1.0)
		var grow = 1.0 - fade
		shell.scale = Vector3.ONE * lerpf(0.8, 11.0, grow)
		core.scale = Vector3.ONE * lerpf(0.3, 4.2, grow * 0.7)
		_fade(shell, fade * 0.75)
		_fade(core, fade)
		for i in bits.size():
			bits[i].position += velocities[i] * delta
			velocities[i] *= exp(-0.8 * delta)
			bits[i].scale = Vector3(fade, fade, lerpf(0.4, 1.4, fade))
		glow.light_energy = 16.0 * fade
		if life <= 0.0:
			visible = false
			set_process(false)

	func _ball(color: Color, emission: Color, energy: float) -> MeshInstance3D:
		var mesh = SphereMesh.new()
		mesh.radius = 1.0
		mesh.height = 2.0
		mesh.radial_segments = 24
		mesh.rings = 12
		var node = MeshInstance3D.new()
		node.mesh = mesh
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.material_override = _fire_material(color, emission, energy)
		return node

	func _fire_material(color: Color, emission: Color, energy: float) -> StandardMaterial3D:
		var material = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = color
		material.emission_enabled = true
		material.emission = emission
		material.emission_energy_multiplier = energy
		return material

	func _fade(node: MeshInstance3D, alpha: float) -> void:
		var material = node.material_override as StandardMaterial3D
		var color = material.albedo_color
		color.a = alpha
		material.albedo_color = color
