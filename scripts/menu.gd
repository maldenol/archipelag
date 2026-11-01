extends CanvasLayer

const FOOT = "Mouse    look\nW A S D    move\nShift    sprint\nSpace    jump\nRight mouse    aim\nLeft mouse    fire\nR    reload\nF    board the rocket\nM    system map\nEsc    pause\nF1    controls"
const SHIP = "Mouse    camera\nWheel    zoom\nW    nose down\nS    nose up\nA    yaw left\nD    yaw right\nQ E    roll\nSpace    thrust\nP    hold prograde\nR    hold retrograde\n,    slower time\n.    faster time\nF    leave the rocket\nM    map\nEsc    pause\nF1    controls"

var system
var main_panel: Control
var pause_panel: Control
var help_panel: Control
var death_panel: Control
var help_back = "main"
var death_left = 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 30
	system = get_parent()
	var dim = ColorRect.new()
	dim.color = Color(0.0, 0.012, 0.02, 0.78)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	main_panel = _screen("Archipelag", "A star system on rails", ["Play", "Controls", "Quit"])
	pause_panel = _screen("Paused", "", ["Resume", "Controls", "Main menu", "Quit"])
	help_panel = _help_screen()
	death_panel = _screen("You died", "", [])
	add_child(main_panel)
	add_child(pause_panel)
	add_child(help_panel)
	add_child(death_panel)
	visible = false

func _process(delta: float) -> void:
	if death_left <= 0.0:
		return
	death_left -= delta
	if death_left <= 0.0 and system != null:
		system.return_to_menu()

func _input(event: InputEvent) -> void:
	if system == null or system.dying or not (event is InputEventKey):
		return
	var key_event = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	var key = key_event.physical_keycode
	if key == KEY_F1:
		get_viewport().set_input_as_handled()
		if help_panel.visible:
			_close_help()
		elif system.playing and not get_tree().paused:
			system.pause_game()
			show_help("play")
		elif pause_panel.visible:
			show_help("pause")
		else:
			show_help("main")
	elif key == KEY_ESCAPE:
		if not system.playing and not visible:
			return
		get_viewport().set_input_as_handled()
		if help_panel.visible:
			_close_help()
		elif system.playing and get_tree().paused:
			system.resume_game()
		elif system.playing:
			system.pause_game()

func show_main() -> void:
	visible = true
	main_panel.visible = true
	pause_panel.visible = false
	help_panel.visible = false
	death_panel.visible = false
	death_left = 0.0

func show_pause() -> void:
	visible = true
	main_panel.visible = false
	pause_panel.visible = true
	help_panel.visible = false
	death_panel.visible = false

func show_help(back: String) -> void:
	help_back = back
	visible = true
	main_panel.visible = false
	pause_panel.visible = false
	help_panel.visible = true
	death_panel.visible = false

func show_death() -> void:
	visible = true
	main_panel.visible = false
	pause_panel.visible = false
	help_panel.visible = false
	death_panel.visible = true
	death_left = 2.4

func hide_menu() -> void:
	visible = false
	main_panel.visible = false
	pause_panel.visible = false
	help_panel.visible = false
	death_panel.visible = false
	death_left = 0.0

func _close_help() -> void:
	if help_back == "play":
		system.resume_game()
	elif help_back == "pause":
		show_pause()
	else:
		show_main()

func _choose(label: String) -> void:
	if system != null and system.sound != null:
		system.sound.play("ui")
	if label == "Play" or label == "Resume":
		system.resume_game() if label == "Resume" else system.begin_play()
	elif label == "Controls":
		show_help("pause" if pause_panel.visible else "main")
	elif label == "Main menu":
		system.return_to_menu()
	elif label == "Quit":
		get_tree().quit()
	elif label == "Back":
		_close_help()

func _screen(title: String, subtitle: String, labels: Array) -> Control:
	var page = _centered()
	var card = _card(420.0)
	page.add_child(card)
	var box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	card.add_child(box)
	box.add_child(_label(title, 36, Color(0.9, 0.95, 1.0)))
	if subtitle != "":
		box.add_child(_label(subtitle, 16, Color(0.62, 0.78, 0.86)))
	for label in labels:
		var button = _button(str(label))
		button.pressed.connect(_choose.bind(str(label)))
		box.add_child(button)
	return page

func _help_screen() -> Control:
	var page = _centered()
	var card = _card(760.0)
	page.add_child(card)
	var box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	card.add_child(box)
	box.add_child(_label("Controls", 32, Color(0.9, 0.95, 1.0)))
	var columns = HBoxContainer.new()
	columns.add_theme_constant_override("separation", 36)
	columns.add_child(_column("On foot", FOOT))
	columns.add_child(_column("Rocket", SHIP))
	box.add_child(columns)
	var back = _button("Back")
	back.pressed.connect(_choose.bind("Back"))
	box.add_child(back)
	return page

func _column(title: String, body: String) -> VBoxContainer:
	var box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.add_child(_label(title, 20, Color(0.55, 0.86, 0.95)))
	box.add_child(_label(body, 16, Color(0.9, 0.93, 0.96)))
	return box

func _centered() -> CenterContainer:
	var page = CenterContainer.new()
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return page

func _card(width: float) -> PanelContainer:
	var card = PanelContainer.new()
	card.custom_minimum_size = Vector2(width, 0.0)
	card.add_theme_stylebox_override("panel", _style(Color(0.015, 0.025, 0.04, 0.94), Color(0.4, 0.68, 0.8)))
	return card

func _button(text: String) -> Button:
	var button = Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0.0, 44.0)
	button.add_theme_font_size_override("font_size", 18)
	button.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	button.add_theme_color_override("font_hover_color", Color(0.55, 0.9, 1.0))
	button.add_theme_stylebox_override("normal", _style(Color(0.03, 0.06, 0.08, 0.95), Color(0.32, 0.55, 0.66)))
	button.add_theme_stylebox_override("hover", _style(Color(0.06, 0.12, 0.16, 0.98), Color(0.5, 0.82, 0.92)))
	button.add_theme_stylebox_override("pressed", _style(Color(0.08, 0.16, 0.2, 1.0), Color(0.7, 0.9, 1.0)))
	return button

func _label(text: String, font_size: int, color: Color) -> Label:
	var label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label

func _style(fill: Color, border: Color) -> StyleBoxFlat:
	var box = StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(1)
	box.set_content_margin_all(16)
	return box
