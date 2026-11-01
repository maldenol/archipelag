extends Node

const BulletScript = preload("res://scripts/projectile.gd")
const ImpactScript = preload("res://scripts/impact_effect.gd")

const BULLET_COUNT = 48
const EFFECT_COUNT = 24

var bullets = []
var effects = []

func _ready() -> void:
	add_to_group("bullet_pool")
	for _i in BULLET_COUNT:
		var bullet = BulletScript.new()
		add_child(bullet)
		bullets.append(bullet)
	for _i in EFFECT_COUNT:
		var effect = ImpactScript.new()
		add_child(effect)
		effects.append(effect)

func spawn_bullet(origin: Vector3, initial_velocity: Vector3, owner_node: Node) -> void:
	var bullet = _take_bullet()
	bullet.launch(origin, initial_velocity, owner_node)

func spawn_impact(at: Vector3, normal: Vector3, host: Node = null) -> void:
	var effect = _take_effect()
	effect.play(at, normal, host)

func _take_bullet():
	var oldest = null
	for bullet in bullets:
		if not bullet.active:
			return bullet
		if oldest == null or bullet.age > oldest.age:
			oldest = bullet
	oldest.release()
	return oldest

func _take_effect():
	var oldest = null
	var oldest_life = 1000.0
	for effect in effects:
		if not effect.active:
			return effect
		if effect.life < oldest_life:
			oldest_life = effect.life
			oldest = effect
	return oldest
