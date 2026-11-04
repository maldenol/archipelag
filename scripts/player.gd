extends RigidBody3D

const SpaceMath = preload("res://scripts/space_math.gd")

const MASS = 80.0
const DRAG_AREA = 0.4
const WALK_SPEED = 5.8
const SPRINT_SPEED = 9.6
const JUMP_SPEED = 5.6
const WALKABLE_ALTITUDE = 60.0
const MUZZLE_SPEED = 250.0
const FIRE_INTERVAL = 0.18
const RELOAD_TIME = 1.3
const MAG_SIZE = 24
const SUIT_THRUST = 2.2
const LOOK_SENS = 0.0022
const STAND_HEIGHT = 0.9
const BOARD_RANGE = 8.0

var system
var current_planet
var nearest_planet
var heading = Vector3.FORWARD
var heading_local = Vector3.FORWARD
var heading_bound = false
var look_pitch = 0.0
var health = 100.0
var max_health = 100.0
var magazine = MAG_SIZE
var reloading = 0.0
var fire_cooldown = 0.0
var boarded = false
var dead = false
var spaceflight = false
var space_position = Vector3.ZERO
var space_velocity = Vector3.ZERO
var space_accum = 0.0
var space_quat = Quaternion.IDENTITY
var space_orient = false
var prompt = ""
var hurt_time = -100.0
var shoot_held = false
var knock = Vector3.ZERO
var grounded = true
var f_held = false
var anim_time = 0.0
var carried = false
var ground_xform = Transform3D.IDENTITY
var hop_height = 0.0
var hop_speed = 0.0
var contact_impact = 0.0
var motion_velocity = Vector3.ZERO
var motion_sample = Vector3.ZERO
var motion_ready = false
var exit_grace = 0.0

var spring: Node3D
var camera: Camera3D
var cam_distance = 2.5
var visual: Node3D
var arm_l: Node3D
var arm_r: Node3D
var elbow_r: Node3D
var leg_l: Node3D
var leg_r: Node3D
var rest_spring = 2.5
var shin_l: Node3D
var shin_r: Node3D
var gun_muzzle: Node3D

func _ready() -> void:
	process_physics_priority = 2
	mass = MASS
	gravity_scale = 0.0
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp = 0.0
	can_sleep = false
	lock_rotation = true
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	collision_mask = 0
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 6
	collision_layer = 2
	collision_mask = 1 | 4
	add_to_group("player")
	var shape = CollisionShape3D.new()
	var capsule = CapsuleShape3D.new()
	capsule.radius = 0.32
	capsule.height = STAND_HEIGHT * 2.0
	shape.shape = capsule
	add_child(shape)
	var grip = PhysicsMaterial.new()
	grip.friction = 0.85
	grip.bounce = 0.0
	physics_material_override = grip
	_build_figure()
	spring = Node3D.new()
	spring.position = Vector3(0.28, 0.52, 0.05)
	add_child(spring)
	camera = Camera3D.new()
	camera.position = Vector3(0.48, 0.18, 0.0)
	camera.fov = 75.0
	camera.near = 0.05
	camera.far = 250000.0
	spring.add_child(camera)

func bind_system(host) -> void:
	system = host

func place(xform: Transform3D) -> void:
	global_transform = xform
	heading = -global_basis.z
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	grounded = true
	spaceflight = false
	carried = false
	heading_bound = false
	hop_height = 0.0
	hop_speed = 0.0
	dead = false
	health = max_health

func set_boarded(value: bool) -> void:
	boarded = value
	visible = not value
	set_physics_process(not value)
	collision_layer = 0 if value else 2
	collision_mask = 0 if value else (1 | 4)
	freeze = value
	if value:
		shoot_held = false
		camera.current = false
	else:
		camera.current = true

func apply_damage(amount: float, _source: Node) -> void:
	if dead or boarded or amount <= 0.0:
		return
	health = maxf(0.0, health - amount)
	hurt_time = Time.get_ticks_msec() / 1000.0
	if amount >= 1.0 and system != null and system.sound != null:
		system.sound.play("hurt")
	if health <= 0.0:
		dead = true
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		_play_death()
		if system:
			system.begin_death()

func reference_velocity() -> Vector3:
	var travel = world_velocity()
	var air = _air_planet()
	if air != null:
		return travel - air.surface_velocity_at(global_position)
	if system == null:
		return travel
	var body = system.dominant_at(global_position).planet
	if body != null:
		return travel - body.center_velocity()
	return travel

func _air_planet():
	if system == null:
		return null
	var best = null
	var best_dist = INF
	for planet in system.planets:
		if not planet.in_atmosphere(global_position):
			continue
		var dist = global_position.distance_squared_to(planet.global_position)
		if dist < best_dist:
			best_dist = dist
			best = planet
	return best

func _fall_damage(impact: float) -> void:
	if impact <= 5.0:
		return
	var span = (impact - 5.0) / 15.0
	apply_damage(max_health * span * span, null)

func world_velocity() -> Vector3:
	# How this body actually moved last step. The analytic surface velocity has a
	# sideways part the camera never has, and that is what threw the shots off.
	if motion_ready:
		return motion_velocity
	return linear_velocity

func _unhandled_input(event: InputEvent) -> void:
	if system == null or system.controlled != self:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion = event as InputEventMouseMotion
		if system.map_expanded:
			system.orbit_map(-motion.relative.x * LOOK_SENS, -motion.relative.y * LOOK_SENS)
		elif spaceflight:
			_ensure_space_orient()
			var yaw = -motion.relative.x * 0.003
			var pitch = -motion.relative.y * 0.0026
			space_quat = (space_quat * Quaternion(Vector3.UP, yaw) * Quaternion(Vector3.RIGHT, pitch)).normalized()
		else:
			_bind_heading()
			var up = _up()
			heading = heading.rotated(up, -motion.relative.x * LOOK_SENS)
			heading = heading.slide(up).normalized()
			_remember_heading()
			look_pitch = clampf(look_pitch - motion.relative.y * LOOK_SENS, deg_to_rad(-75.0), deg_to_rad(75.0))
	elif event is InputEventMouseButton and event.pressed and system.map_expanded:
		var button = event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			system.zoom_map(false)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			system.zoom_map(true)
	elif event is InputEventKey and event.pressed and not event.echo:
		var key = (event as InputEventKey).physical_keycode
		if key == KEY_M:
			system.map_expanded = not system.map_expanded
		elif key == KEY_R and not system.map_expanded:
			_start_reload()

func _process(delta: float) -> void:
	if boarded:
		return
	if spaceflight:
		_ensure_space_orient()
	_refresh_view()
	_animate(delta)

func _physics_process(delta: float) -> void:
	if system == null or boarded:
		return
	_poll_board()
	_update_planet()
	if dead:
		return
	system.apply_star_exposure(self, global_position, delta)
	_roll_space(delta)
	if contact_impact > 0.0:
		_fall_damage(contact_impact)
		contact_impact = 0.0
	angular_velocity = Vector3.ZERO
	if exit_grace > 0.0:
		exit_grace = maxf(exit_grace - delta, 0.0)
	if grounded and current_planet != null and not spaceflight:
		_walk(delta)
	else:
		_coast(delta)
	_use(delta)
	if motion_ready:
		motion_velocity = (global_position - motion_sample) / maxf(delta, 0.0001)
	motion_sample = global_position
	motion_ready = true
func _bind_heading() -> void:
	var planet = current_planet
	if planet == null or spaceflight:
		heading_bound = false
		return
	if not heading_bound:
		heading_local = planet.global_basis.inverse() * heading
		heading_bound = true
	var up = _up()
	var flat = (planet.global_basis * heading_local).slide(up)
	if flat.length_squared() < 0.0001:
		flat = up.cross(planet.global_basis.x)
	if flat.length_squared() < 0.0001:
		return
	heading = flat.normalized()

func _remember_heading() -> void:
	if current_planet == null or spaceflight:
		heading_bound = false
		return
	heading_local = current_planet.global_basis.inverse() * heading
	heading_bound = true

func _desired_basis() -> Basis:
	if spaceflight and space_orient:
		return Basis(space_quat)
	_bind_heading()
	var up = _up()
	var flat = heading.slide(up)
	if flat.length_squared() < 0.001:
		flat = up.cross(Vector3.RIGHT)
	return SpaceMath.basis_from_up_forward(up, flat.normalized())

func _roll_space(delta: float) -> void:
	if not spaceflight:
		return
	_ensure_space_orient()
	var roll = 0.0
	if Input.is_physical_key_pressed(KEY_Q):
		roll -= 1.0
	if Input.is_physical_key_pressed(KEY_E):
		roll += 1.0
	if absf(roll) > 0.0:
		space_quat = (space_quat * Quaternion(Vector3.FORWARD, roll * 1.7 * delta)).normalized()

func _walk(delta: float) -> void:
	var planet = current_planet
	if not carried:
		# Freezing a rigid body snaps it to the solver origin. Keep the placement.
		var keep = global_transform
		carried = true
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		collision_mask = 0
		global_transform = keep
		ground_xform = planet.global_transform.affine_inverse() * keep
		_remember_heading()
	else:
		global_transform = planet.global_transform * ground_xform
		collision_mask = 0
	var up = _up()
	var wish = _wish(up)
	var speed = SPRINT_SPEED if Input.is_physical_key_pressed(KEY_SHIFT) else WALK_SPEED
	var ride = planet.carried_velocity(global_position)
	if Input.is_physical_key_pressed(KEY_SPACE) and hop_height <= 0.05 and hop_speed <= 0.0:
		hop_speed = JUMP_SPEED
		if system.sound != null:
			system.sound.play("jump")
	elif Input.is_physical_key_pressed(KEY_SPACE) and hop_height > 0.4:
		# Held after the hop: suit thrust, so you can climb off the world.
		hop_speed += SUIT_THRUST * delta
	if hop_height > 0.0 or hop_speed > 0.0:
		hop_speed -= planet.surface_gravity * delta
		hop_height += hop_speed * delta
		if hop_height <= 0.0 and hop_speed < 0.0:
			# A normal jump returns at about JUMP_SPEED. Only harder landings hurt.
			if -hop_speed > JUMP_SPEED + 1.5:
				_fall_damage(-hop_speed)
			hop_height = 0.0
			hop_speed = 0.0
	if hop_height > 30.0:
		_leave_ground(ride + wish * speed + up * hop_speed)
		return
	# Direct tangent step. A sweep against the trimesh cancels the walk.
	# Standing still keeps the stored placement. Replanting every frame chatters,
	# and reading the body back into ground_xform undoes the planet carry.
	var moved = wish.length_squared() > 0.0001 or hop_height > 0.0 or hop_speed != 0.0
	if moved:
		global_position += wish * speed * delta
		_plant(planet, hop_height)
	var separated = _separate_from_rocket()
	if moved or separated:
		ground_xform = planet.global_transform.affine_inverse() * global_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO

func _separate_from_rocket() -> bool:
	if system == null or system.rocket == null or system.rocket.exploded:
		return false
	var away = global_position - system.rocket.global_position
	var gap = away.length()
	if gap > 1.6 or gap < 0.001:
		return false
	global_position += away / gap * (1.6 - gap)
	return true

func _plant(planet, extra: float = 0.0) -> void:
	var radial = global_position - planet.global_position
	if radial.length_squared() < 1.0:
		return
	var up = radial.normalized()
	var dist = planet.mesh_radius_world(radial) + STAND_HEIGHT + 0.14 + extra
	global_position = planet.global_position + up * dist

func _leave_ground(launch: Vector3) -> void:
	carried = false
	heading_bound = false
	freeze = false
	collision_mask = 1 | 4
	linear_velocity = launch
	angular_velocity = Vector3.ZERO
	grounded = false
	spaceflight = true
	_ensure_space_orient()

func _coast(delta: float) -> void:
	_ensure_space_orient()
	var body = Basis(space_quat)
	var wish = Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		wish += -body.z
	if Input.is_physical_key_pressed(KEY_S):
		wish -= -body.z
	if Input.is_physical_key_pressed(KEY_A):
		wish -= body.x
	if Input.is_physical_key_pressed(KEY_D):
		wish += body.x
	if Input.is_physical_key_pressed(KEY_SPACE):
		wish += body.y
	if Input.is_physical_key_pressed(KEY_SHIFT):
		wish -= body.y
	var accel = system.acceleration_at(global_position) + wish.limit_length(1.0) * SUIT_THRUST
	accel += system.drag_acceleration(global_position, linear_velocity, DRAG_AREA, MASS, delta)
	apply_central_force(accel * mass)
	heading = -body.z
	if exit_grace > 0.0 or current_planet == null or not _feet_near(current_planet):
		return
	var up = _up()
	var rel = linear_velocity - current_planet.carried_velocity(global_position)
	if rel.dot(up) > 0.6:
		return
	var impact = -rel.dot(up)
	grounded = true
	spaceflight = false
	space_orient = false
	carried = true
	heading_bound = false
	var keep = global_transform
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	collision_mask = 0
	global_transform = keep
	ground_xform = current_planet.global_transform.affine_inverse() * keep
	linear_velocity = Vector3.ZERO
	_remember_heading()
	_fall_damage(impact)
	if system.sound != null:
		system.sound.play("land")

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	# Read the solver contacts only. Writing state.transform stops the body.
	if freeze or system == null or not spaceflight:
		return
	for i in state.get_contact_count():
		var other = state.get_contact_collider_object(i)
		if other == null:
			continue
		var world = other.has_method("carried_velocity") or (other is Node and (other as Node).is_in_group("star"))
		if not world:
			continue
		var normal = (state.transform.basis * state.get_contact_local_normal(i)).normalized()
		var ride = Vector3.ZERO
		if other.has_method("carried_velocity"):
			ride = other.carried_velocity(state.transform.origin)
		var closing = -(state.linear_velocity - ride).dot(normal)
		var bump = state.get_contact_impulse(i).length() / maxf(mass, 1.0)
		contact_impact = maxf(contact_impact, maxf(closing, bump))

func _feet_near(planet) -> bool:
	var radial = global_position - planet.global_position
	if radial.length_squared() < 1.0:
		return false
	var feet = radial.length() - planet.mesh_radius_world(radial) - STAND_HEIGHT
	if feet > 1.2:
		return false
	var up = radial.normalized()
	var query = PhysicsRayQueryParameters3D.create(global_position, global_position - up * (STAND_HEIGHT + 1.4))
	query.collision_mask = 1
	query.exclude = [get_rid()]
	return not get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func _touching(body: Node) -> bool:
	if body == null:
		return false
	for other in get_colliding_bodies():
		if other == body:
			return true
	return false

func _poll_board() -> void:
	var down = Input.is_physical_key_pressed(KEY_F)
	if down and not f_held and system.controlled == self:
		system.try_board()
	f_held = down

func _wish(up: Vector3) -> Vector3:
	var forward = heading.slide(up).normalized()
	if forward.length_squared() < 0.001:
		return Vector3.ZERO
	var right = forward.cross(up).normalized()
	var input = Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_D):
		input.x += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_physical_key_pressed(KEY_W):
		input.y += 1.0
	if Input.is_physical_key_pressed(KEY_S):
		input.y -= 1.0
	input = input.limit_length(1.0)
	return (forward * input.y + right * input.x).limit_length(1.0)

func _ensure_space_orient() -> void:
	if space_orient:
		return
	space_quat = global_basis.get_rotation_quaternion()
	space_orient = true
	look_pitch = 0.0

func _update_planet() -> void:
	current_planet = null
	nearest_planet = null
	if system == null:
		return
	var dominant = system.dominant_at(global_position)
	nearest_planet = dominant.planet
	if nearest_planet == null:
		return
	var altitude = nearest_planet.altitude_at(global_position)
	if altitude < WALKABLE_ALTITUDE:
		current_planet = nearest_planet

func _use(delta: float) -> void:
	fire_cooldown = maxf(0.0, fire_cooldown - delta)
	if reloading > 0.0:
		reloading -= delta
		if reloading <= 0.0:
			magazine = MAG_SIZE
	prompt = ""
	var ship = system.rocket if system else null
	if ship and not ship.exploded and global_position.distance_squared_to(ship.global_position) <= BOARD_RANGE * BOARD_RANGE:
		prompt = "Press F to pilot the rocket" if ship.landed else "Press F to board the rocket"
		shoot_held = _aiming() and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		if shoot_held:
			if magazine <= 0 and reloading <= 0.0:
				_start_reload()
			else:
				_fire()
		return
	shoot_held = _aiming() and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if shoot_held:
		if magazine <= 0 and reloading <= 0.0:
			_start_reload()
		else:
			_fire()

func _aim() -> Dictionary:
	var result = {"resource": null, "mob": null, "point": camera.global_position + (-camera.global_basis.z) * 80.0}
	if camera == null:
		return result
	var start = camera.global_position
	var end = start + (-camera.global_basis.z) * 80.0
	var query = PhysicsRayQueryParameters3D.create(start, end)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	query.collision_mask = 1 | 2
	query.exclude = [get_rid()]
	var hit = get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return result
	result.point = hit.position
	return result

func _fire() -> void:
	if reloading > 0.0 or magazine <= 0 or fire_cooldown > 0.0 or camera == null:
		return
	# From the shoulder along the crosshair. The gun hangs beside the body and
	# sits in the ground, so a shot born there dies in the dirt off to one side.
	var direction = -camera.global_basis.z
	var origin = spring.global_position if spring != null else camera.global_position
	origin += direction * 0.55
	var pool = get_tree().get_first_node_in_group("bullet_pool")
	if pool:
		pool.spawn_bullet(origin, direction * MUZZLE_SPEED + launch_velocity(), self)
	if system != null and system.sound != null:
		system.sound.play("shot")
	magazine -= 1
	fire_cooldown = FIRE_INTERVAL
	if magazine <= 0:
		_start_reload()

func launch_velocity() -> Vector3:
	# The body's measured step. linear_velocity is doubled once the kinematic
	# motion is published, and that extra sideways part is what throws the shot.
	if carried and current_planet != null and not spaceflight:
		var up = _up()
		var speed = SPRINT_SPEED if Input.is_physical_key_pressed(KEY_SHIFT) else WALK_SPEED
		return current_planet.carried_velocity(global_position) + _wish(up) * speed + up * hop_speed
	return linear_velocity

func _start_reload() -> void:
	if reloading > 0.0 or magazine >= MAG_SIZE:
		return
	reloading = RELOAD_TIME

func _refresh_view() -> void:
	# The rigid body must not have its transform written every frame. Godot treats
	# that as a teleport and then does not integrate linear_velocity, so an exit
	# in flight left the person hanging while the rocket flew away.
	var facing = _desired_basis()
	heading = -facing.z
	if freeze and carried and current_planet != null:
		# Store the facing in the planet frame. Writing global_basis here reads a
		# stale origin and walks the person off the ground.
		var turned = ground_xform
		turned.basis = current_planet.global_basis.inverse() * facing
		ground_xform = turned
		if visual != null and not dead:
			visual.basis = Basis.IDENTITY
	elif visual != null and not dead:
		visual.global_basis = facing
	if spring:
		if spaceflight and space_orient:
			spring.global_basis = facing
		else:
			spring.basis = Basis(Vector3.RIGHT, look_pitch)
			spring.position = Vector3(0.28, 0.52, 0.05)
		_seat_camera()

func _up() -> Vector3:
	var planet = current_planet if current_planet else nearest_planet
	if planet:
		var radial = global_position - planet.global_position
		var altitude = planet.altitude_at(global_position)
		if radial.length_squared() > 1.0 and altitude < WALKABLE_ALTITUDE:
			return radial.normalized()
	if system == null:
		return Vector3.UP
	var accel = system.acceleration_at(global_position)
	if accel.length() < 0.1:
		return Vector3.UP
	return -accel.normalized()

func altitude_meters() -> float:
	if system == null:
		return 0.0
	var dominant = system.dominant_at(global_position)
	if dominant.planet:
		return dominant.planet.altitude_at(global_position)
	return global_position.distance_to(system.global_position) - system.star_radius

func _build_figure() -> void:
	var suit = Color(0.22, 0.3, 0.4)
	var cloth = Color(0.42, 0.52, 0.6)
	var skin = Color(0.76, 0.6, 0.48)
	var dark = Color(0.1, 0.11, 0.13)
	var visor = Color(0.25, 0.55, 0.7)
	visual = Node3D.new()
	add_child(visual)
	var torso = CapsuleMesh.new()
	torso.radius = 0.16
	torso.height = 0.52
	_solid(visual, torso, Vector3(0, 0.2, 0), suit)
	var pack = BoxMesh.new()
	pack.size = Vector3(0.22, 0.28, 0.12)
	_solid(visual, pack, Vector3(0, 0.22, 0.16), Color(0.16, 0.18, 0.2))
	var head = SphereMesh.new()
	head.radius = 0.13
	head.height = 0.26
	head.radial_segments = 24
	head.rings = 16
	_solid(visual, head, Vector3(0, 0.56, 0), skin)
	var glass = BoxMesh.new()
	glass.size = Vector3(0.16, 0.07, 0.04)
	_solid(visual, glass, Vector3(0, 0.57, -0.11), visor)
	arm_l = _pivot(visual, Vector3(-0.24, 0.38, 0))
	arm_r = _pivot(visual, Vector3(0.24, 0.38, 0))
	_arm(arm_l, cloth, dark, false)
	elbow_r = _arm(arm_r, cloth, dark, true)
	leg_l = _pivot(visual, Vector3(-0.1, -0.06, 0))
	leg_r = _pivot(visual, Vector3(0.1, -0.06, 0))
	shin_l = _leg(leg_l, suit, dark)
	shin_r = _leg(leg_r, suit, dark)

func _arm(pivot: Node3D, cloth: Color, dark: Color, gun_arm: bool) -> Node3D:
	var upper = CapsuleMesh.new()
	upper.radius = 0.055
	upper.height = 0.28
	_solid(pivot, upper, Vector3(0, -0.14, 0), cloth)
	var elbow = _pivot(pivot, Vector3(0, -0.28, 0))
	var forearm = CapsuleMesh.new()
	forearm.radius = 0.045
	forearm.height = 0.26
	_solid(elbow, forearm, Vector3(0, -0.13, 0), cloth)
	if gun_arm:
		var gun = BoxMesh.new()
		gun.size = Vector3(0.05, 0.4, 0.07)
		_solid(elbow, gun, Vector3(0.02, -0.38, 0.0), dark)
		gun_muzzle = Node3D.new()
		gun_muzzle.position = Vector3(0.02, -0.58, 0.0)
		elbow.add_child(gun_muzzle)
	elbow.rotation.x = 0.2
	return elbow

func _leg(hip: Node3D, suit: Color, dark: Color) -> Node3D:
	var thigh = CapsuleMesh.new()
	thigh.radius = 0.07
	thigh.height = 0.36
	_solid(hip, thigh, Vector3(0, -0.18, 0), suit)
	var knee = _pivot(hip, Vector3(0, -0.36, 0))
	var shin = CapsuleMesh.new()
	shin.radius = 0.055
	shin.height = 0.34
	_solid(knee, shin, Vector3(0, -0.17, 0), suit)
	var boot = BoxMesh.new()
	boot.size = Vector3(0.1, 0.08, 0.22)
	_solid(knee, boot, Vector3(0, -0.42, -0.05), dark)
	return knee

func _pivot(parent: Node3D, at: Vector3) -> Node3D:
	var node = Node3D.new()
	node.position = at
	parent.add_child(node)
	return node

func _solid(parent: Node3D, mesh: Mesh, at: Vector3, color: Color) -> MeshInstance3D:
	var node = MeshInstance3D.new()
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	node.mesh = mesh
	node.position = at
	node.material_override = SpaceMath.make_material(color)
	parent.add_child(node)
	return node

func _animate(delta: float) -> void:
	if visual == null or leg_l == null:
		return
	var aiming = _aiming()
	cam_distance = lerpf(cam_distance, 1.55 if aiming else rest_spring, 10.0 * delta)
	var step_speed = reference_velocity().length()
	var moving = grounded and not spaceflight and step_speed > 0.35 and not aiming
	if moving:
		anim_time += delta * (5.5 + step_speed * 0.8)
		var swing = sin(anim_time)
		leg_l.rotation.x = -swing * 0.65
		leg_r.rotation.x = swing * 0.65
		shin_l.rotation.x = maxf(0.0, swing) * -0.95
		shin_r.rotation.x = maxf(0.0, -swing) * -0.95
		arm_l.rotation.x = swing * 0.45
		if not aiming:
			arm_r.basis = Basis(Vector3.RIGHT, 0.2 - swing * 0.35)
		visual.position.y = absf(swing) * 0.03
	elif not grounded or spaceflight:
		leg_l.rotation.x = lerpf(leg_l.rotation.x, 0.45, 10.0 * delta)
		leg_r.rotation.x = lerpf(leg_r.rotation.x, 0.22, 10.0 * delta)
		shin_l.rotation.x = lerpf(shin_l.rotation.x, -0.55, 10.0 * delta)
		shin_r.rotation.x = lerpf(shin_r.rotation.x, -0.3, 10.0 * delta)
		arm_l.rotation.x = lerpf(arm_l.rotation.x, 0.65, 10.0 * delta)
		if not aiming:
			arm_r.basis = Basis(Vector3.RIGHT, lerpf(arm_r.rotation.x, 0.5, 10.0 * delta))
		visual.position.y = 0.0
	else:
		anim_time += delta * 1.8
		var breath = sin(anim_time) * 0.012
		visual.position.y = breath
		leg_l.rotation.x = lerpf(leg_l.rotation.x, 0.0, 8.0 * delta)
		leg_r.rotation.x = lerpf(leg_r.rotation.x, 0.0, 8.0 * delta)
		shin_l.rotation.x = lerpf(shin_l.rotation.x, 0.0, 8.0 * delta)
		shin_r.rotation.x = lerpf(shin_r.rotation.x, 0.0, 8.0 * delta)
		arm_l.rotation.x = lerpf(arm_l.rotation.x, 0.12, 8.0 * delta)
		if not aiming:
			arm_r.basis = Basis(Vector3.RIGHT, lerpf(arm_r.rotation.x, 0.18, 8.0 * delta))
	if aiming and not dead:
		_point_gun()

func _aiming() -> bool:
	return camera != null and system != null and system.controlled == self and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)

func _point_gun() -> void:
	if arm_r == null or visual == null or camera == null:
		return
	var aim = _aim()
	var dir = aim.point - arm_r.global_position
	if dir.length() < 2.0:
		dir = -camera.global_basis.z
	var local_dir = (visual.global_basis.inverse() * dir).normalized()
	if local_dir.length_squared() < 0.5:
		return
	# The gun is built along local -Y. basis.y is that axis, negated.
	var y_axis = -local_dir
	var x_axis = y_axis.cross(Vector3.FORWARD)
	if x_axis.length_squared() < 0.001:
		x_axis = y_axis.cross(Vector3.RIGHT)
	x_axis = x_axis.normalized()
	var z_axis = x_axis.cross(y_axis).normalized()
	arm_r.basis = Basis(x_axis, y_axis, z_axis)
	if elbow_r:
		elbow_r.rotation = Vector3.ZERO

func _seat_camera() -> void:
	if spring == null or camera == null:
		return
	var local_aim = Vector3(0.48, 0.18, cam_distance)
	var origin = spring.global_position
	var want = spring.global_transform * local_aim
	var query = PhysicsRayQueryParameters3D.create(origin, want)
	query.collision_mask = 1
	query.exclude = [get_rid()]
	var hit = get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var span = maxf(origin.distance_to(want), 0.001)
		var keep = origin.distance_to(hit.position) - 0.35
		local_aim *= clampf(keep / span, 0.15, 1.0)
	camera.position = local_aim

func _play_death() -> void:
	if visual == null:
		return
	var fall = _Collapse.new()
	fall.visual = visual
	fall.arm = arm_r
	fall.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(fall)

func location_label() -> String:
	if system == null:
		return "Deep space"
	var dominant = system.dominant_at(global_position)
	if dominant.planet == null:
		return "Hearth"
	return dominant.planet.planet_name

class _Collapse extends Node:
	var visual: Node3D
	var arm: Node3D
	var life = 0.85

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(delta: float) -> void:
		if visual == null:
			return
		life -= delta
		var t = clampf(1.0 - life / 0.85, 0.0, 1.0)
		visual.rotation.x = t * 1.35
		visual.position.y = lerpf(0.0, -0.55, t)
		if arm:
			arm.rotation.x = lerpf(arm.rotation.x, 1.15, 0.15)
		if life <= 0.0:
			set_process(false)
