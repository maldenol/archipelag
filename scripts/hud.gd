extends CanvasLayer

const SpaceMath = preload("res://scripts/space_math.gd")

var panel: Control

func _ready() -> void:
	panel = Control.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.draw.connect(_draw_panel)
	add_child(panel)

func _process(_delta: float) -> void:
	if panel:
		panel.queue_redraw()

func _draw_panel() -> void:
	var system = get_parent()
	if system == null or panel == null:
		return
	var font = ThemeDB.fallback_font
	var size = panel.size
	if system.controlled == system.player:
		_draw_player(system.controlled, font, size)
	elif system.controlled == system.rocket:
		_draw_rocket(system, system.controlled, font, size)

func _draw_player(player, font: Font, size: Vector2) -> void:
	var health_frac = player.health / maxf(player.max_health, 1.0)
	_bar(Vector2(28, 28), Vector2(280, 22), health_frac, Color(0.75, 0.18, 0.16))
	_text(font, Vector2(34, 44), "Health  %.0f / %.0f" % [player.health, player.max_health], 16, Color.WHITE)
	var ammo = "Reloading" if player.reloading > 0.0 else "Ammo  %d / %d" % [player.magazine, player.MAG_SIZE]
	_text(font, Vector2(28, 78), ammo, 22, Color(0.95, 0.9, 0.7))
	_flight_card(font, Vector2(24, 108), player.location_label(), player.altitude_meters(), player.reference_velocity().length(), "", "", "")
	var center = size * 0.5
	var system = get_parent()
	if system == null or not system.map_expanded:
		var cross = Color(1, 1, 1, 0.85)
		panel.draw_line(center + Vector2(-10, 0), center + Vector2(-3, 0), cross, 1.5)
		panel.draw_line(center + Vector2(3, 0), center + Vector2(10, 0), cross, 1.5)
		panel.draw_line(center + Vector2(0, -10), center + Vector2(0, -3), cross, 1.5)
		panel.draw_line(center + Vector2(0, 3), center + Vector2(0, 10), cross, 1.5)
	if player.prompt != "":
		_text(font, Vector2(center.x - 160, size.y - 90), player.prompt, 22, Color.WHITE)
	var now = Time.get_ticks_msec() / 1000.0
	var since = now - player.hurt_time
	if since >= 0.0 and since < 0.22:
		panel.draw_rect(Rect2(Vector2.ZERO, size), Color(0.7, 0.05, 0.05, (1.0 - since / 0.22) * 0.35))

func _draw_rocket(system, rocket, font: Font, size: Vector2) -> void:
	var frac = rocket.health / maxf(rocket.max_health, 1.0)
	_bar(Vector2(28, 28), Vector2(280, 22), frac, Color(0.2, 0.55, 0.85))
	_text(font, Vector2(34, 44), "Hull  %.0f / %.0f" % [rocket.health, rocket.max_health], 16, Color.WHITE)
	var dominant = system.dominant_at(rocket.global_position)
	var nearest = dominant.planet
	var altitude = 0.0
	var planet_name = "Hearth"
	if nearest:
		planet_name = nearest.planet_name
		altitude = nearest.altitude_at(rocket.global_position)
	else:
		altitude = rocket.global_position.distance_to(system.global_position) - system.star_radius
	var attitude_name = "Manual"
	if rocket.attitude == "prograde":
		attitude_name = "Prograde"
	elif rocket.attitude == "retrograde":
		attitude_name = "Retrograde"
	var state_name = "Thrust" if rocket.thrust_held else ("Landed" if rocket.landed else "Coast")
	_flight_card(font, Vector2(24, 72), planet_name, altitude, rocket.guidance_velocity().length(), "", "%s  ·  %s" % [state_name, attitude_name], "%d×" % system.WARP_STEPS[system.warp_index])
	if not system.map_expanded:
		_draw_map(system, rocket, font, size)
	_draw_navball(system, rocket, size)
	var now = Time.get_ticks_msec() / 1000.0
	var since = now - rocket.hurt_time
	if since >= 0.0 and since < 0.22:
		panel.draw_rect(Rect2(Vector2.ZERO, size), Color(0.7, 0.05, 0.05, (1.0 - since / 0.22) * 0.35))

func _draw_map(system, rocket, font: Font, size: Vector2) -> void:
	var map_size = minf(size.x, size.y) * 0.72 if system.map_expanded else 400.0
	var origin = (size - Vector2(map_size, map_size)) * 0.5 if system.map_expanded else Vector2(size.x - map_size - 28.0, size.y - map_size - 64.0)
	panel.draw_rect(Rect2(origin, Vector2(map_size, map_size)), Color(0.01, 0.02, 0.04, 0.88 if system.map_expanded else 0.72))
	var frame = Color(0.3, 0.55, 0.7, 0.8)
	panel.draw_rect(Rect2(origin, Vector2(map_size, map_size)), frame, false, 1.0)
	var active: Dictionary = rocket.predict(300.0, 0.5)
	var focus: Vector3 = system.global_position
	var framed: Dictionary = system.frame_path(active.samples)
	var strips: Array = framed.strips
	var title = "Hearth  —  trajectory" if system.map_expanded else "System"
	_text(font, origin + Vector2(10, 22), title, 16, Color(0.7, 0.85, 1))
	var reach = 1000.0
	for planet in system.planets:
		var period = SpaceMath.TAU / maxf(planet.orbit.mean_motion, 0.0000001)
		for step in 97:
			reach = maxf(reach, _flat(planet.location_at(period * float(step) / 96.0) - focus))
	for strip in strips:
		for point in strip:
			reach = maxf(reach, _flat(point - focus))
	reach = maxf(reach, _flat(rocket.global_position - focus))
	reach *= 1.12
	for planet in system.planets:
		var orbit_points: Array[Vector3] = []
		var period = SpaceMath.TAU / maxf(planet.orbit.mean_motion, 0.0000001)
		if planet.parent_body != null:
			for step in 97:
				var rel = SpaceMath.orbit_position(planet.orbit, period * float(step) / 96.0)
				orbit_points.append(planet.parent_body.global_position + rel)
		else:
			for step in 97:
				orbit_points.append(planet.location_at(period * float(step) / 96.0))
		_stroke(orbit_points, focus, origin, map_size, reach, Color(planet.color.r, planet.color.g, planet.color.b, 0.35), 1.0)
		var dot = _project(planet.global_position, focus, origin, map_size, reach)
		panel.draw_rect(Rect2(dot - Vector2(3, 3), Vector2(6, 6)), planet.color)
		_text(font, dot + Vector2(6, -8), planet.planet_name, 14, planet.color)
	var star = _project(focus, focus, origin, map_size, reach)
	panel.draw_rect(Rect2(star - Vector2(4, 4), Vector2(8, 8)), Color(1, 0.82, 0.4))
	for strip in strips:
		_stroke(strip, focus, origin, map_size, reach, Color(0.35, 0.9, 1, 0.95), 2.0)
	for gate in framed.gates:
		var at: Vector2 = _project(gate.at, focus, origin, map_size, reach)
		if gate.kind == "exit":
			panel.draw_line(at + Vector2(-5, -5), at + Vector2(5, 5), Color(1.0, 0.42, 0.28), 1.6)
			panel.draw_line(at + Vector2(-5, 5), at + Vector2(5, -5), Color(1.0, 0.42, 0.28), 1.6)
		else:
			panel.draw_arc(at, 5.0, 0.0, TAU, 12, Color(0.35, 0.95, 0.72), 1.6)
	if active.hit and active.samples.size() > 0:
		var last: Dictionary = active.samples[active.samples.size() - 1]
		var hit: Vector2 = _project(system.frame_point(last.pos, last.time), focus, origin, map_size, reach)
		_mark_collision(hit)
	var ship = _project(rocket.global_position, focus, origin, map_size, reach)
	panel.draw_rect(Rect2(ship - Vector2(3, 3), Vector2(6, 6)), Color.WHITE)

func _flight_card(font: Font, origin: Vector2, planet_name: String, altitude: float, speed: float, surface: String, status: String, warp: String) -> void:
	var rows = 3
	if surface != "":
		rows += 1
	if status != "":
		rows += 1
	if warp != "":
		rows += 1
	var card = Vector2(248, 18.0 + float(rows) * 22.0)
	panel.draw_rect(Rect2(origin, card), Color(0.015, 0.02, 0.03, 0.78))
	panel.draw_rect(Rect2(origin, card), Color(0.4, 0.62, 0.74, 0.85), false, 1.0)
	panel.draw_rect(Rect2(origin, Vector2(3, card.y)), Color(0.45, 0.82, 0.95, 0.95))
	var y = origin.y + 22.0
	_text(font, Vector2(origin.x + 16, y), planet_name, 18, Color(0.9, 0.95, 1))
	y += 22.0
	_row(font, origin.x, y, "Altitude", "%.0f m" % altitude)
	y += 22.0
	_row(font, origin.x, y, "Speed", "%.0f m/s" % speed)
	y += 22.0
	if surface != "":
		_row(font, origin.x, y, "Surface", surface)
		y += 22.0
	if status != "":
		_text(font, Vector2(origin.x + 16, y), status, 15, Color(0.75, 0.84, 0.9))
		y += 22.0
	if warp != "":
		_row(font, origin.x, y, "Time", warp)

func _row(font: Font, x: float, y: float, label: String, value: String) -> void:
	_text(font, Vector2(x + 16, y), label, 15, Color(0.55, 0.68, 0.76))
	_text(font, Vector2(x + 118, y), value, 15, Color(0.94, 0.97, 1))

func _bar(origin: Vector2, bar_size: Vector2, fraction: float, fill: Color) -> void:
	panel.draw_rect(Rect2(origin, bar_size), Color(0, 0, 0, 0.55))
	panel.draw_rect(Rect2(origin + Vector2(2, 2), Vector2((bar_size.x - 4.0) * clampf(fraction, 0.0, 1.0), bar_size.y - 4.0)), fill)

func _text(font: Font, pos: Vector2, text: String, font_size: int, color: Color) -> void:
	if font == null:
		return
	panel.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _draw_navball(system, rocket, size: Vector2) -> void:
	var center = Vector2(size.x * 0.5, size.y - 128.0)
	var radius = 96.0
	panel.draw_circle(center, radius, Color(0.012, 0.02, 0.03, 0.9))
	panel.draw_arc(center, radius, 0.0, TAU, 64, Color(0.45, 0.72, 0.86, 0.95), 2.0)
	var frame: Dictionary = rocket.nav_frame()
	var up: Vector3 = frame.up
	_draw_horizon(rocket.global_basis, up, center, radius)
	var travel: Vector3 = frame.velocity
	if travel.length() > 0.8:
		var prograde = travel.normalized()
		_draw_nav_mark(rocket.global_basis, prograde, center, radius, Color(0.98, 0.86, 0.25), false)
		_draw_nav_mark(rocket.global_basis, -prograde, center, radius, Color(0.98, 0.72, 0.2), true)
	_draw_nav_mark(rocket.global_basis, up, center, radius, Color(0.4, 0.85, 1.0), false)
	_draw_nav_mark(rocket.global_basis, -up, center, radius, Color(0.95, 0.45, 0.55), true)
	var wing = Color(0.92, 0.96, 1.0, 0.95)
	panel.draw_line(center + Vector2(-22, 0), center + Vector2(-7, 0), wing, 2.0)
	panel.draw_line(center + Vector2(7, 0), center + Vector2(22, 0), wing, 2.0)
	panel.draw_line(center + Vector2(0, -12), center, Color(0.45, 0.95, 0.55), 2.0)

func _draw_horizon(basis: Basis, up: Vector3, center: Vector2, radius: float) -> void:
	var side = up.cross(basis.x)
	if side.length_squared() < 0.01:
		side = up.cross(Vector3.FORWARD)
	if side.length_squared() < 0.01:
		return
	side = side.normalized()
	var ahead = side.cross(up).normalized()
	var points: PackedVector2Array = PackedVector2Array()
	for i in 37:
		var angle = lerpf(-PI, PI, float(i) / 36.0)
		var dir = side * sin(angle) + ahead * cos(angle)
		var point = _nav_project(basis, dir, center, radius)
		if point.x < -10000.0:
			if points.size() > 1:
				panel.draw_polyline(points, Color(0.55, 0.82, 0.95, 0.9), 2.0)
			points = PackedVector2Array()
			continue
		points.append(point)
	if points.size() > 1:
		panel.draw_polyline(points, Color(0.55, 0.82, 0.95, 0.9), 2.0)

func _draw_nav_mark(basis: Basis, dir: Vector3, center: Vector2, radius: float, color: Color, crossed: bool) -> void:
	var point = _nav_project(basis, dir, center, radius)
	if point.x < -10000.0:
		return
	panel.draw_arc(point, 6.0, 0.0, TAU, 16, color, 1.6)
	if crossed:
		panel.draw_line(point + Vector2(-4, -4), point + Vector2(4, 4), color, 1.5)
		panel.draw_line(point + Vector2(-4, 4), point + Vector2(4, -4), color, 1.5)

func _nav_project(basis: Basis, dir: Vector3, center: Vector2, radius: float) -> Vector2:
	if dir.length_squared() < 0.0001:
		return Vector2(-20000, 0)
	var local = basis.inverse() * dir.normalized()
	var facing = -local.z
	var angle = acos(clampf(facing, -1.0, 1.0))
	if angle > PI * 0.5:
		return Vector2(-20000, 0)
	var flat = Vector2(local.x, -local.y)
	if flat.length_squared() < 0.000001:
		return center
	return center + flat.normalized() * (angle / (PI * 0.5)) * radius * 0.92

func _mark_collision(at: Vector2) -> void:
	var span = 8.0
	var color = Color(1.0, 0.8, 0.18)
	_diamond_icon(at, span, color, 2.0)
	_diamond_icon(at, span * 0.45, color, 1.4)

func _diamond_icon(at: Vector2, span: float, color: Color, width: float) -> void:
	var corners = PackedVector2Array([
		at + Vector2(0, -span),
		at + Vector2(span, 0),
		at + Vector2(0, span),
		at + Vector2(-span, 0),
	])
	for i in 4:
		panel.draw_line(corners[i], corners[(i + 1) % 4], color, width)

func _flat(relative: Vector3) -> float:
	return maxf(absf(relative.x), absf(relative.z))

func _project(world: Vector3, star: Vector3, origin: Vector2, map_size: float, reach: float) -> Vector2:
	var relative = world - star
	var x = relative.x / reach
	var z = relative.z / reach
	return Vector2(origin.x + (x * 0.5 + 0.5) * map_size, origin.y + (0.5 - z * 0.5) * map_size)

func _stroke(points: Array, star: Vector3, origin: Vector2, map_size: float, reach: float, color: Color, width: float) -> void:
	for i in range(1, points.size()):
		var a = _project(points[i - 1], star, origin, map_size, reach)
		var b = _project(points[i], star, origin, map_size, reach)
		panel.draw_line(a, b, color, width)
