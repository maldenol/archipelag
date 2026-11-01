extends Node3D

const SpaceMath = preload("res://scripts/space_math.gd")

var velocity = Vector3.ZERO
var shooter: Node
var age = 0.0
var damage = 14.0
var active = false

func _ready() -> void:
	var mesh = MeshInstance3D.new()
	var ball = SphereMesh.new()
	ball.radius = 0.08
	ball.height = 0.16
	mesh.mesh = ball
	mesh.material_override = SpaceMath.make_material(Color(1.0, 0.85, 0.3), 2.0)
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh)
	visible = false
	set_physics_process(false)

func launch(origin: Vector3, initial_velocity: Vector3, owner_node: Node) -> void:
	global_position = origin
	velocity = initial_velocity
	shooter = owner_node
	age = 0.0
	active = true
	visible = true
	show()
	set_physics_process(true)

func release() -> void:
	active = false
	set_physics_process(false)
	velocity = Vector3.ZERO
	shooter = null
	visible = false
	hide()

func _physics_process(delta: float) -> void:
	var system = _system()
	if system == null:
		release()
		return
	var step = delta
	velocity += system.acceleration_at(global_position) * step
	# The planet already moved this step. Carry the shot with that motion, then
	# add only the velocity that is not the planet's, or the extra ride shoves
	# the ray into the ground beside the muzzle.
	var start := global_position
	var ride := Vector3.ZERO
	var planet = _surface_planet(system)
	if planet != null:
		var carried: Vector3 = planet.transport_point(global_position)
		ride = (carried - global_position) / step
		start = carried
	var relative: Vector3 = velocity - ride
	var target: Vector3 = start + relative * step
	velocity = relative + ride
	var query = PhysicsRayQueryParameters3D.create(start, target)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	query.collision_mask = 1 | 2 | 4
	if shooter is CollisionObject3D:
		var skip: Array[RID] = [(shooter as CollisionObject3D).get_rid()]
		var extra = shooter.get("body_rid")
		if extra is RID and (extra as RID).is_valid():
			skip.append(extra)
		query.exclude = skip
	var hit = get_world_3d().direct_space_state.intersect_ray(query)
	var travel = start.distance_to(target)
	var hit_pos: Vector3 = target
	var hit_normal: Vector3 = Vector3.UP
	var victim: Object = null
	var hit_distance = travel + 1.0
	if not hit.is_empty() and hit.position is Vector3 and _on_segment(start, target, hit.position):
		var body = hit.collider
		if body == null:
			body = system.owner_of(hit.rid)
		if body != shooter:
			hit_pos = hit.position
			if hit.normal is Vector3:
				hit_normal = hit.normal
			victim = body
			hit_distance = start.distance_to(hit_pos)
	var terrain: Dictionary = system.terrain_contact(start, target)
	if not terrain.is_empty():
		var terrain_pos: Vector3 = terrain.position
		if _on_segment(start, target, terrain_pos):
			var terrain_distance = start.distance_to(terrain_pos)
			if terrain_distance < hit_distance:
				hit_pos = terrain_pos
				hit_normal = terrain.normal
				victim = terrain.collider
				hit_distance = terrain_distance
	if victim != null and hit_distance <= travel + 0.001:
		var owner_node = shooter
		release()
		if victim != owner_node and victim != null and victim.has_method("apply_damage"):
			victim.apply_damage(damage, owner_node)
		var pool = get_tree().get_first_node_in_group("bullet_pool")
		if pool:
			pool.spawn_impact(hit_pos, hit_normal, victim)
		return
	global_position = target
	age += delta
	if age > 4.0:
		release()

func _surface_planet(system):
	var best = null
	var best_alt = INF
	for planet in system.planets:
		var alt = global_position.distance_to(planet.global_position) - planet.radius
		if alt < best_alt:
			best_alt = alt
			best = planet
	if best == null or best_alt > 80.0:
		return null
	return best

func _on_segment(start: Vector3, end: Vector3, point: Vector3) -> bool:
	var delta = end - start
	var span = delta.length_squared()
	if span < 0.000001:
		return false
	var t = (point - start).dot(delta) / span
	if t <= 0.002 or t > 1.001:
		return false
	var closest = start + delta * clampf(t, 0.0, 1.0)
	return point.distance_squared_to(closest) <= 0.64

func _system():
	return get_tree().get_first_node_in_group("star_system")
