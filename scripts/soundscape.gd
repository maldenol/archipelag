extends Node

const RATE = 22050
const CHORDS = {
	"menu": [98.0, 146.83, 196.0, 246.94],
	"ground": [110.0, 164.81, 220.0, 329.63],
	"air": [87.31, 130.81, 174.61, 261.63],
	"space": [65.41, 98.0, 130.81, 196.0],
}

var music: AudioStreamPlayer
var thrust: AudioStreamPlayer
var voices: Array[AudioStreamPlayer] = []
var clips = {}
var phases: Array[float] = [0.0, 0.0, 0.0, 0.0]
var freqs: Array[float] = [98.0, 146.83, 196.0, 246.94]
var clock = 0.0
var hurt_at = 0
var thrust_phase = 0.0
var thrust_low = 0.0
var thrust_gain = 0.0
var thrust_rng = RandomNumberGenerator.new()

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	clips = {
		"ui": _tone(880.0, 0.07, 6.0, 0.35),
		"jump": _sweep(420.0, 220.0, 0.12, 0.4),
		"land": _thud(),
		"shot": _shot(),
		"hurt": _burst(0.09, 180.0, 0.55),
		"board": _sweep(520.0, 780.0, 0.14, 0.32),
		"boom": _burst(0.45, 55.0, 0.9),
	}
	music = AudioStreamPlayer.new()
	var gen = AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.3
	music.stream = gen
	music.volume_db = -8.0
	add_child(music)
	music.play()
	thrust_rng.seed = 19
	thrust = AudioStreamPlayer.new()
	var burn = AudioStreamGenerator.new()
	burn.mix_rate = RATE
	burn.buffer_length = 0.3
	thrust.stream = burn
	thrust.volume_db = -2.0
	add_child(thrust)
	thrust.play()
	for _i in 8:
		var voice = AudioStreamPlayer.new()
		voice.volume_db = -4.0
		add_child(voice)
		voices.append(voice)

func _process(_delta: float) -> void:
	_fill_music()
	var burning = false
	var system = get_parent()
	if system != null and system.playing and system.rocket != null and not get_tree().paused:
		burning = system.rocket.thrust_held and not system.rocket.exploded
	_fill_thrust(burning)

func play(name: String) -> void:
	if name == "hurt":
		var now = Time.get_ticks_msec()
		if now - hurt_at < 160:
			return
		hurt_at = now
	var clip = clips.get(name)
	if clip == null:
		return
	for voice in voices:
		if not voice.playing:
			voice.stream = clip
			voice.play()
			return
	voices[0].stream = clip
	voices[0].play()

func _fill_music() -> void:
	if music == null:
		return
	var playback = music.get_stream_playback()
	if playback == null:
		return
	var mode = _mode()
	var chord: Array = CHORDS[mode]
	var step = int(clock / 4.0) % 4
	var lead = float(chord[3]) * (2.0 if step == 2 else 1.0)
	var targets: Array[float] = [float(chord[0]), float(chord[1]), float(chord[2]), lead]
	var frames = mini(playback.get_frames_available(), 4096)
	var dt = 1.0 / float(RATE)
	var level = 0.045 if get_tree().paused else 0.09
	for _frame in frames:
		var sample = 0.0
		for i in 4:
			freqs[i] = lerpf(freqs[i], targets[i], 0.00035)
			phases[i] = fmod(phases[i] + TAU * freqs[i] * dt, TAU)
			var wave = sin(phases[i]) + 0.22 * sin(phases[i] * 2.0)
			var trem = 0.78 + 0.22 * sin(clock * (0.13 + 0.04 * float(i)))
			sample += wave * trem * (0.34 - float(i) * 0.06)
		clock += dt
		sample *= level
		playback.push_frame(Vector2(sample, sample))

func _mode() -> String:
	var system = get_parent()
	if system == null or not system.playing:
		return "menu"
	if system.controlled == system.rocket and system.rocket != null:
		if system.rocket._air_planet() != null:
			return "air"
		return "space"
	if system.player != null and system.player.spaceflight:
		return "space"
	return "ground"

func _tone(freq: float, seconds: float, decay: float, level: float) -> AudioStreamWAV:
	var count = int(float(RATE) * seconds)
	var data = PackedFloat32Array()
	data.resize(count)
	for i in count:
		var t = float(i) / float(RATE)
		data[i] = sin(TAU * freq * t) * exp(-decay * t) * level
	return _wav(data)

func _sweep(from_hz: float, to_hz: float, seconds: float, level: float) -> AudioStreamWAV:
	var count = int(float(RATE) * seconds)
	var data = PackedFloat32Array()
	data.resize(count)
	var phase = 0.0
	for i in count:
		var u = float(i) / float(maxi(count - 1, 1))
		var freq = lerpf(from_hz, to_hz, u)
		phase += TAU * freq / float(RATE)
		data[i] = sin(phase) * (1.0 - u) * level
	return _wav(data)

func _burst(seconds: float, tone: float, level: float) -> AudioStreamWAV:
	var count = int(float(RATE) * seconds)
	var data = PackedFloat32Array()
	data.resize(count)
	var rng = RandomNumberGenerator.new()
	rng.seed = int(tone * 10.0)
	var low = 0.0
	for i in count:
		var t = float(i) / float(RATE)
		var white = rng.randf_range(-1.0, 1.0)
		low += (white - low) * 0.18
		var body = sin(TAU * tone * t) * 0.65 + low
		data[i] = body * exp(-6.5 * t) * level
	return _wav(data)

func _shot() -> AudioStreamWAV:
	var count = int(float(RATE) * 0.08)
	var data = PackedFloat32Array()
	data.resize(count)
	var rng = RandomNumberGenerator.new()
	rng.seed = 3
	for i in count:
		var t = float(i) / float(RATE)
		data[i] = (rng.randf_range(-1.0, 1.0) * 0.65 + sin(TAU * 210.0 * t)) * exp(-28.0 * t) * 0.55
	return _wav(data)

func _thud() -> AudioStreamWAV:
	var count = int(float(RATE) * 0.16)
	var data = PackedFloat32Array()
	data.resize(count)
	var rng = RandomNumberGenerator.new()
	rng.seed = 11
	var low = 0.0
	for i in count:
		var t = float(i) / float(RATE)
		low += (rng.randf_range(-1.0, 1.0) - low) * 0.12
		data[i] = (sin(TAU * 90.0 * t) * 0.7 + low) * exp(-14.0 * t) * 0.6
	return _wav(data)

func _fill_thrust(burning: bool) -> void:
	if thrust == null:
		return
	var playback = thrust.get_stream_playback()
	if playback == null:
		return
	var target = 1.0 if burning else 0.0
	var frames = mini(playback.get_frames_available(), 4096)
	var dt = 1.0 / float(RATE)
	for _frame in frames:
		thrust_gain = lerpf(thrust_gain, target, 0.0015)
		thrust_low += (thrust_rng.randf_range(-1.0, 1.0) - thrust_low) * 0.05
		thrust_phase = fmod(thrust_phase + TAU * 74.0 * dt, TAU)
		var sample = (thrust_low * 0.72 + sin(thrust_phase) * 0.28) * 0.42 * thrust_gain
		playback.push_frame(Vector2(sample, sample))

func _wav(data: PackedFloat32Array) -> AudioStreamWAV:
	var bytes = PackedByteArray()
	bytes.resize(data.size() * 2)
	for i in data.size():
		var value = int(round(clampf(data[i], -1.0, 1.0) * 32767.0))
		bytes.encode_s16(i * 2, value)
	var stream = AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = bytes
	return stream
