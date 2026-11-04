extends SceneTree

const SpaceMath = preload("res://scripts/space_math.gd")

var system: Node = null
var phase := 0
var hold := 0
var shot_dir := ""
var pose_gun := false
var lock_rocket_cam := false
var started := false

func _init() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1600, 900))

func _initialize() -> void:
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1600, 900)
	shot_dir = ProjectSettings.globalize_path("res://screenshots")
	DirAccess.make_dir_recursive_absolute(shot_dir)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	system = main
	hold = 80
	print("capture: scene ready")

func _process(_delta: float) -> bool:
	if system == null:
		return false
	if not started:
		started = true
		paused = false
		system.begin_play()
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		_fit_window()
	_fit_window()
	if lock_rocket_cam:
		_aim_ship()
	if pose_gun and system.player != null:
		system.player._point_gun()
	if hold > 0:
		hold -= 1
		return false
	match phase:
		0:
			_caldera_view()
			hold = 25
			phase = 1
		1:
			_save("caldera-surface.png")
			_aim_gun()
			hold = 6
			phase = 2
		2:
			_burst()
			hold = 10
			phase = 3
		3:
			_save("shooting.png")
			pose_gun = false
			_release_aim()
			_launch_rocket()
			hold = 18
			phase = 4
		4:
			lock_rocket_cam = false
			_save("rocket-trajectory.png")
			_frame_system()
			hold = 12
			phase = 5
		5:
			_save("system-map.png")
			_eva()
			hold = 18
			phase = 6
		6:
			_save("eva-space.png")
			_stand("Lumen", deg_to_rad(-12.0))
			hold = 18
			phase = 7
		7:
			_save("lumen.png")
			_stand("Vellum", deg_to_rad(-12.0))
			hold = 18
			phase = 8
		8:
			_save("vellum.png")
			_stand_mote()
			hold = 18
			phase = 9
		9:
			_save("mote.png")
			print("capture: done")
			return true
		_:
			return true
	return false

func _caldera_view() -> void:
	var player = system.player
	system.map_expanded = false
	system.controlled = player
	player.set_boarded(false)
	player.look_pitch = deg_to_rad(-8.0)
	player.camera.current = true
	system.rocket.camera.current = false
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN

func _aim_gun() -> void:
	var player = system.player
	var planet = player.current_planet
	var up: Vector3 = player._up()
	var away: Vector3 = (player.global_position - system.rocket.global_position).slide(up)
	if away.length_squared() < 0.01:
		away = up.cross(Vector3.FORWARD)
	away = away.normalized()
	player.global_position += away * 8.0 + up * 1.6
	if planet != null:
		player.ground_xform = planet.global_transform.affine_inverse() * player.global_transform
	player.heading = away.rotated(up, 1.15)
	player._remember_heading()
	player.look_pitch = deg_to_rad(16.0)
	player.rest_spring = 3.4
	player.cam_distance = 3.4
	pose_gun = true

func _release_aim() -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.pressed = false
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _burst() -> void:
	var player = system.player
	player._refresh_view()
	player._point_gun()
	player.reloading = 0.0
	player.magazine = player.MAG_SIZE
	var direction: Vector3 = -player.camera.global_basis.z
	var origin: Vector3 = player.camera.global_position + direction * 2.0
	for _i in 4:
		player.fire_cooldown = 0.0
		player._fire()
	var pool = system.get_tree().get_first_node_in_group("bullet_pool")
	if pool == null:
		return
	var index := 0
	for bullet in pool.bullets:
		if not bullet.active:
			continue
		var distance := 7.0 + float(index) * 6.0
		bullet.global_position = origin + direction * distance
		bullet.velocity = direction * 35.0
		bullet.scale = Vector3(3.5, 3.5, 3.5)
		index += 1

func _launch_rocket() -> void:
	var planet = system.planet_named("Caldera")
	var rocket = system.rocket
	var player = system.player
	var up: Vector3 = planet.global_basis.x.normalized()
	var from_star: Vector3 = planet.global_position - system.global_position
	var forward: Vector3 = Vector3.UP.cross(from_star)
	if forward.length_squared() < 1.0:
		forward = Vector3.FORWARD.cross(from_star)
	forward = forward.slide(up).normalized()
	var pos: Vector3 = planet.global_position + up * (planet.mesh_radius_world(up) + 1400.0)
	var z_axis := -forward
	var x_axis: Vector3 = up.cross(forward).normalized()
	var y_axis: Vector3 = z_axis.cross(x_axis).normalized()
	rocket.exploded = false
	rocket.landed = false
	rocket.flying = true
	rocket.carried = false
	rocket.parked = planet
	rocket.thrust_held = false
	rocket.attitude = ""
	rocket.freeze = false
	rocket.collision_mask = 1 | 2
	rocket.global_transform = Transform3D(Basis(x_axis, y_axis, z_axis).orthonormalized(), pos)
	rocket.linear_velocity = forward * 380.0
	rocket.angular_velocity = Vector3.ZERO
	rocket.freeze = true
	lock_rocket_cam = true
	_aim_ship()
	player.set_boarded(true)
	rocket.camera.current = true
	system.controlled = rocket
	system.map_expanded = false
	system.warp_index = 0

func _fit_window() -> void:
	root.mode = Window.MODE_WINDOWED
	if root.size != Vector2i(1600, 900):
		root.size = Vector2i(1600, 900)
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if DisplayServer.window_get_size() != Vector2i(1600, 900):
		DisplayServer.window_set_size(Vector2i(1600, 900))

func _aim_ship() -> void:
	var rocket = system.rocket
	var planet = system.planet_named("Caldera")
	var up: Vector3 = (rocket.global_position - planet.global_position).normalized()
	var forward: Vector3 = -rocket.global_basis.z
	if forward.length_squared() < 0.01:
		forward = up.cross(Vector3.RIGHT).normalized()
	var look: Vector3 = (-up * 0.55 + forward * 0.55 + up.cross(forward) * 0.35).normalized()
	rocket.cam_on_hull = false
	rocket.flying = true
	rocket.landed = false
	rocket.cam_distance = 16.0
	rocket.cam_quat = Basis.looking_at(look, up).get_rotation_quaternion()

func _frame_system() -> void:
	var rocket = system.rocket
	var player = system.player
	var coast: Vector3 = rocket.linear_velocity
	if coast.length_squared() < 1.0:
		coast = -rocket.global_basis.z
	rocket.linear_velocity = coast.normalized() * 700.0
	rocket.freeze = true
	rocket.landed = false
	rocket.flying = true
	player.set_boarded(false)
	player.freeze = true
	player.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	player.global_position = Vector3(0.0, 14000.0, 0.0)
	player.spaceflight = true
	player.grounded = false
	player.camera.current = false
	system.controlled = player
	system.map_expanded = true
	system.map_distance = 560000.0
	system.map_quat = Quaternion(Vector3.RIGHT, -0.85) * Quaternion(Vector3.UP, 0.35)

func _eva() -> void:
	var planet = system.planet_named("Lumen")
	var rocket = system.rocket
	var player = system.player
	system.map_expanded = false
	var up: Vector3 = planet.global_basis.y.normalized()
	var forward: Vector3 = up.cross(planet.global_basis.x).normalized()
	var side: Vector3 = up.cross(forward).normalized()
	var surface: float = planet.mesh_radius_world(up)
	var rocket_pos: Vector3 = planet.global_position + up * (surface + 900.0) + side * 9.0
	var z_axis := -forward
	var x_axis := side
	var y_axis: Vector3 = z_axis.cross(x_axis).normalized()
	rocket.exploded = false
	rocket.landed = false
	rocket.flying = true
	rocket.carried = false
	rocket.thrust_held = false
	rocket.freeze = true
	rocket.collision_mask = 1 | 2
	if rocket.hull_root:
		rocket.hull_root.visible = true
	rocket.global_transform = Transform3D(Basis(x_axis, y_axis, z_axis).orthonormalized(), rocket_pos)
	rocket.linear_velocity = forward * 40.0
	rocket.camera.current = false
	var player_pos: Vector3 = planet.global_position + up * (surface + 918.0) - side * 3.0
	player.set_boarded(false)
	player.place(Transform3D.IDENTITY)
	player.freeze = true
	player.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	player.visible = true
	player.global_position = player_pos
	player.spaceflight = true
	player.grounded = false
	player.carried = false
	player.current_planet = null
	var look_at: Vector3 = (rocket_pos * 0.35 + planet.global_position * 0.65) - player_pos
	var facing := Basis.looking_at(look_at.normalized(), side)
	player.global_basis = facing
	player.space_quat = facing.get_rotation_quaternion()
	player.space_orient = true
	player.heading = -facing.z
	player.look_pitch = 0.0
	player.rest_spring = 5.5
	player.cam_distance = 5.5
	player.linear_velocity = rocket.linear_velocity
	player.camera.current = true
	system.controlled = player

func _stand(body_name: String, pitch: float) -> void:
	var planet = system.planet_named(body_name)
	var up: Vector3 = planet.global_basis.x.normalized()
	var forward: Vector3 = planet.global_basis.z.slide(up).normalized()
	_plant_player(planet, up, forward, pitch)

func _stand_mote() -> void:
	var mote = system.planet_named("Mote")
	var cinder = system.planet_named("Cinder")
	var to_moon: Vector3 = (cinder.global_position - mote.global_position).normalized()
	var axis: Vector3 = to_moon.cross(Vector3.UP)
	if axis.length_squared() < 0.01:
		axis = to_moon.cross(Vector3.RIGHT)
	axis = axis.normalized()
	var up: Vector3 = to_moon.rotated(axis, deg_to_rad(62.0)).normalized()
	var forward: Vector3 = to_moon.slide(up).normalized()
	_plant_player(mote, up, forward, deg_to_rad(18.0))

func _plant_player(planet, up: Vector3, forward: Vector3, pitch: float) -> void:
	var player = system.player
	system.map_expanded = false
	system.controlled = player
	system.rocket.camera.current = false
	var radial := up.normalized()
	var pos: Vector3 = planet.global_position + radial * (planet.mesh_radius_world(radial) + player.STAND_HEIGHT + 0.2)
	var xform := Transform3D(SpaceMath.basis_from_up_forward(radial, forward), pos)
	player.rest_spring = 2.5
	player.cam_distance = 2.5
	player.place(xform)
	player.set_boarded(false)
	player.freeze = true
	player.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	player.carried = true
	player.current_planet = planet
	player.nearest_planet = planet
	player.ground_xform = planet.global_transform.affine_inverse() * xform
	player.heading_bound = true
	player.heading_local = planet.global_basis.inverse() * (-xform.basis.z)
	player.look_pitch = pitch
	player.visible = true
	player.camera.current = true

func _save(file_name: String) -> void:
	var image := root.get_texture().get_image()
	var path := shot_dir.path_join(file_name)
	var err := image.save_png(path)
	print("capture: %s %dx%d err=%d" % [path, image.get_width(), image.get_height(), err])
