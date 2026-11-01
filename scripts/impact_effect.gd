extends Node3D

const SpaceMath = preload("res://scripts/space_math.gd")

var active = false
var life = 0.0
var duration = 0.28
var sparks: Array[MeshInstance3D] = []
var spark_vel: Array[Vector3] = []
var glow: OmniLight3D
var home: Node

func _ready() -> void:
	for i in 8:
		var bit = MeshInstance3D.new()
		var box = BoxMesh.new()
		box.size = Vector3(0.035, 0.035, 0.2)
		bit.mesh = box
		var material = SpaceMath.make_material(Color(1.0, 0.72, 0.28), 5.0)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bit.material_override = material
		bit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(bit)
		sparks.append(bit)
		spark_vel.append(Vector3.ZERO)
		if i == 7:
			material.albedo_color = Color(1.0, 0.95, 0.7)
	glow = OmniLight3D.new()
	glow.light_color = Color(1.0, 0.7, 0.3)
	glow.light_energy = 0.0
	glow.omni_range = 2.4
	glow.shadow_enabled = false
	add_child(glow)
	visible = false
	set_process(false)
	home = get_parent()

func play(at: Vector3, normal: Vector3, host: Node = null) -> void:
	var anchor: Node = home
	if host is Node3D and is_instance_valid(host):
		anchor = host
	if anchor == null:
		anchor = get_parent()
	if anchor != null and get_parent() != anchor:
		reparent(anchor, false)
	var n = normal.normalized() if normal.length_squared() > 0.2 else Vector3.UP
	if anchor is Node3D and anchor != home:
		position = (anchor as Node3D).to_local(at)
		n = (anchor as Node3D).global_basis.inverse() * n
		if n.length_squared() < 0.2:
			n = Vector3.UP
		n = n.normalized()
	else:
		global_position = at
	var side = n.cross(Vector3.UP)
	if side.length_squared() < 0.01:
		side = n.cross(Vector3.RIGHT)
	side = side.normalized()
	var bitangent = n.cross(side)
	for i in sparks.size():
		var ang = float(i) * TAU / float(sparks.size())
		var dir = (n * 1.1 + side * cos(ang) + bitangent * sin(ang)).normalized()
		spark_vel[i] = dir * (2.4 + float(i % 4) * 0.7)
		sparks[i].position = dir * 0.05
		sparks[i].basis = Basis.looking_at(dir, side)
		sparks[i].scale = Vector3.ONE
		var material = sparks[i].material_override as StandardMaterial3D
		var color = material.albedo_color
		color.a = 1.0
		material.albedo_color = color
	life = duration
	active = true
	visible = true
	show()
	glow.light_energy = 3.0
	set_process(true)

func _process(delta: float) -> void:
	life -= delta
	var fade = clampf(life / duration, 0.0, 1.0)
	for i in sparks.size():
		sparks[i].position += spark_vel[i] * delta
		spark_vel[i] *= 0.86
		sparks[i].scale = Vector3(fade, fade, lerpf(0.3, 1.0, fade))
		var material = sparks[i].material_override as StandardMaterial3D
		var color = material.albedo_color
		color.a = fade
		material.albedo_color = color
	glow.light_energy = 3.0 * fade
	if life <= 0.0:
		active = false
		visible = false
		hide()
		glow.light_energy = 0.0
		set_process(false)
		if home != null and is_instance_valid(home) and get_parent() != home:
			reparent(home, false)
