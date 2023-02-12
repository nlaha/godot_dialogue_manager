extends RichTextLabel


signal spoke(letter: String, letter_index: int, speed: float)
signal paused_typing(duration: float)
signal finished_typing()


const DialogueLine = preload("res://addons/dialogue_manager/dialogue_line.gd")


## The action to press to skip typing
@export var skip_action: String = "ui_accept"

## The speed with which the text types out
@export var seconds_per_step: float = 0.02

## When off, the label will grow in height as the text types out
@export var start_with_full_height: bool = true

@export var log_mode: bool = false

@export var gpt_mode: bool = false

@export var type_sound: AudioStream
var sfx_player

var line_separator = "\n\n[color=white]>[/color] "

var log_buffer: Array[String] = [""]
var log_line_start = 0

var bbcode_regex = RegEx.new()

var dialogue_line: DialogueLine:
	set(next_dialogue_line):
		dialogue_line = next_dialogue_line
		custom_minimum_size = Vector2.ZERO
		if not log_mode:
			text = dialogue_line.text
		else:
			log_buffer.append(dialogue_line.text)
			text = line_separator.join(PackedStringArray(log_buffer))
			log_line_start = get_total_character_count() - bbcode_regex.sub(dialogue_line.text, "").length()
	get:
		return dialogue_line

var last_wait_index: int = -1
var last_mutation_index: int = -1
var waiting_seconds: float = 0
var is_typing: bool = false
var has_finished: bool = false

func push_response(response):
	if log_mode:
		log_buffer.append("[color=#30D5E0]" + response + "[/color]")
		text = line_separator.join(PackedStringArray(log_buffer))
		log_line_start = get_total_character_count()

func _ready():
	bbcode_regex.compile("\\[\\\\?\\w*\\]")
	sfx_player = AudioStreamPlayer2D.new()
	add_child(sfx_player)

func _process(delta: float) -> void:
	
	if not is_typing:
		var lstick = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		
		if lstick.y > 0.2 and get_v_scroll_bar().ratio < 1.0:
			get_v_scroll_bar().ratio += lstick.y * delta
		if lstick.y < -0.2 and get_v_scroll_bar().ratio > 0.0:
			get_v_scroll_bar().ratio += lstick.y * delta
	else:
		get_v_scroll_bar().ratio = 1.0
		
	if is_typing:
		# Type out text
		if visible_ratio < 1:
			# If cancel is pressed then skip typing it out
			if Input.is_action_just_pressed(skip_action):
				# Run any inline mutations that haven't been run yet
				for i in range(visible_characters - log_line_start, get_total_character_count()):
					mutate_inline_mutations(i)
				visible_characters = log_line_start + get_total_character_count()
				has_finished = true
				emit_signal("finished_typing")
				return
			
			# Otherwise, see if we are waiting
			if waiting_seconds > 0:
				waiting_seconds = waiting_seconds - delta
			# If we are no longer waiting then keep typing
			if waiting_seconds <= 0:
				type_next(delta, waiting_seconds)
		else:
			is_typing = false
			if has_finished == false:
				has_finished = true
				emit_signal("finished_typing")


func reset_height() -> void:
	# For some reason, RichTextLabels within containers don't resize properly when their content 
	# changes so we make a clone that isn't bound by a VBox
	var size_check_label: RichTextLabel = duplicate(DUPLICATE_USE_INSTANTIATION)
	size_check_label.modulate.a = 0
	size_check_label.anchor_left = 1
	get_tree().current_scene.add_child(size_check_label)
	size_check_label.size = Vector2(size.x, 0)
	
	if start_with_full_height:
		# Give the size check a chance to resize
		await get_tree().process_frame
	
	# Resize our dialogue label with the new size hint
	custom_minimum_size = size_check_label.size
	size = Vector2.ZERO
	
	# Destroy our clone
	size_check_label.free()


# Start typing out the text
func type_out() -> void:
	if not log_mode:
		text = dialogue_line.text
		visible_characters = 0
	else:
		text = line_separator.join(PackedStringArray(log_buffer))
		visible_characters = log_line_start
	has_finished = false
	waiting_seconds = 0
	
	# Text isn't calculated until the next frame
	await get_tree().process_frame
	
	if get_total_character_count() == 0:
		emit_signal("finished_typing")
	elif seconds_per_step == 0:
		is_typing = false
		# Run any inline mutations
		for i in range(0, get_total_character_count()):
			mutate_inline_mutations(i)
		visible_characters += get_total_character_count()
		emit_signal("finished_typing")
	else:
#		percent_per_index = 100.0 / float(get_total_character_count()) / 100.0
		is_typing = true


# Type out the next character(s)
func type_next(delta: float, seconds_needed: float) -> void:
	if visible_characters - log_line_start == get_total_character_count():
		return
	
	if last_mutation_index != visible_characters - log_line_start:
		last_mutation_index = visible_characters - log_line_start
		mutate_inline_mutations(visible_characters - log_line_start)
	
	if last_wait_index != visible_characters - log_line_start and get_pause(visible_characters - log_line_start) > 0:
		last_wait_index = visible_characters - log_line_start
		waiting_seconds += get_pause(visible_characters - log_line_start)
		emit_signal("paused_typing", get_pause(visible_characters - log_line_start))
	else:
#		visible_ratio += percent_per_index
		var add_num = 1
		if gpt_mode:
			add_num = clampi(randi_range(1, 3), 1, get_total_character_count() - visible_characters)
		visible_characters += add_num
		seconds_needed += seconds_per_step * (1.0 / get_speed(visible_characters - log_line_start))
		if seconds_needed > delta:
			waiting_seconds += seconds_needed
			if visible_characters - log_line_start < get_total_character_count():
				sfx_player.stream = type_sound
				sfx_player.pitch_scale = randf_range(0.95, 1.05)
				sfx_player.play()
				emit_signal(
					"spoke", 
					text[visible_characters - log_line_start - 1], 
					visible_characters - log_line_start - 1, 
					get_speed(visible_characters - log_line_start)
				)
		else:
			type_next(delta, seconds_needed)


# Get the pause for the current typing position if there is one
func get_pause(at_index: int) -> float:
	return dialogue_line.pauses.get(at_index, 0)


# Get the speed for the current typing position
func get_speed(at_index: int) -> float:
	var speed: float = 1
	for index in dialogue_line.speeds:
		if index > at_index:
			return speed
		speed = dialogue_line.speeds[index]
	return speed


# Run any mutations at the current typing position
func mutate_inline_mutations(index: int) -> void:
	for inline_mutation in dialogue_line.inline_mutations:
		# inline mutations are an array of arrays in the form of [character index, resolvable function]
		if inline_mutation[0] > index:
			return
		if inline_mutation[0] == index:
			# The DialogueManager can't be referenced directly here so we need to get it by its path
			get_node("/root/DialogueManager").mutate(inline_mutation[1], dialogue_line.extra_game_states)
