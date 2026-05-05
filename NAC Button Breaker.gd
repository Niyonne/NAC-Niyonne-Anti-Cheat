class_name NacLocal
extends RefCounted

const PSEUDO_CHANGE_COOLDOWN := 24 * 60 * 60

var min_cps: int = 40
var detections_per_sanction: int = 3
var max_temp_sanctions: int = 5
var sanction_step_minutes: int = 5
var ms_pattern_seconds_required: int = 3
var ms_pattern_average_max: float = 0.035
var ms_pattern_variance_max: float = 0.0000002

var anti_cheat_triggered := false
var anti_cheat_close_on_ack := false
var detected_cps: int = 0
var cps_counter_second: int = -1
var cps_counter_clicks: int = 0
var anti_cheat_detection_count: int = 0
var temp_sanction_count: int = 0
var sanction_end_unix: int = 0
var permanent_ban := false
var recent_click_intervals: Array[float] = []
var last_click_timestamp_ms: int = -1
var last_detection_constant_pattern := false
var constant_pattern_second_streak: int = 0
var history: Array[Dictionary] = []


func configure(config: Dictionary) -> void:
	min_cps = int(config.get("min_cps", min_cps))
	detections_per_sanction = int(config.get("detections_per_sanction", detections_per_sanction))
	max_temp_sanctions = int(config.get("max_temp_sanctions", max_temp_sanctions))
	sanction_step_minutes = int(config.get("sanction_step_minutes", sanction_step_minutes))
	ms_pattern_seconds_required = int(config.get("ms_pattern_seconds_required", ms_pattern_seconds_required))
	ms_pattern_average_max = float(config.get("ms_pattern_average_max", ms_pattern_average_max))
	ms_pattern_variance_max = float(config.get("ms_pattern_variance_max", ms_pattern_variance_max))


func load_state(data: Dictionary) -> void:
	anti_cheat_detection_count = maxi(0, int(data.get("anti_cheat_detection_count", 0)))
	temp_sanction_count = maxi(0, int(data.get("temp_sanction_count", 0)))
	sanction_end_unix = maxi(0, int(data.get("sanction_end_unix", 0)))
	permanent_ban = bool(data.get("permanent_ban", false))
	history.clear()
	var loaded_history: Variant = data.get("nac_history", [])
	if typeof(loaded_history) == TYPE_ARRAY:
		for entry in loaded_history:
			if typeof(entry) == TYPE_DICTIONARY:
				history.append(entry)


func save_state(data: Dictionary) -> Dictionary:
	data["anti_cheat_detection_count"] = anti_cheat_detection_count
	data["temp_sanction_count"] = temp_sanction_count
	data["sanction_end_unix"] = sanction_end_unix
	data["permanent_ban"] = permanent_ban
	data["nac_history"] = history
	return data


func register_click(now_ms: int) -> Dictionary:
	var now_second: int = int(now_ms / 1000.0)
	if cps_counter_second == -1:
		cps_counter_second = now_second
	if now_second != cps_counter_second:
		var carry_result := finalize_second(now_second)
		cps_counter_clicks += 1
		if last_click_timestamp_ms >= 0:
			var carry_interval: float = float(now_ms - last_click_timestamp_ms) / 1000.0
			recent_click_intervals.append(carry_interval)
			if recent_click_intervals.size() > 12:
				recent_click_intervals.remove_at(0)
		last_click_timestamp_ms = now_ms
		return carry_result
	cps_counter_clicks += 1

	if last_click_timestamp_ms >= 0:
		var interval: float = float(now_ms - last_click_timestamp_ms) / 1000.0
		recent_click_intervals.append(interval)
		if recent_click_intervals.size() > 12:
			recent_click_intervals.remove_at(0)
	last_click_timestamp_ms = now_ms
	return {"triggered": false}


func update_second(now_ms: int) -> Dictionary:
	if cps_counter_second == -1:
		return {"triggered": false}
	var now_second: int = int(now_ms / 1000.0)
	if now_second != cps_counter_second:
		return finalize_second(now_second)
	return {"triggered": false}


func finalize_second(next_second: int) -> Dictionary:
	detected_cps = cps_counter_clicks
	cps_counter_second = next_second
	cps_counter_clicks = 0
	last_detection_constant_pattern = has_millisecond_constant_click_pattern()

	if last_detection_constant_pattern:
		constant_pattern_second_streak += 1
	else:
		constant_pattern_second_streak = 0

	if detected_cps >= min_cps:
		return trigger_detection("L'anti-cheat (NAC) a detecte une activite suspecte dans votre style de jeu. Veuillez jouer convenablement", false, _get_unix_time_now())

	if last_detection_constant_pattern and constant_pattern_second_streak >= ms_pattern_seconds_required:
		return trigger_detection("L'anti-cheat (NAC) a detecte une activite suspecte dans votre style de jeu. Veuillez jouer convenablement", false, _get_unix_time_now())

	return {"triggered": false}


func has_millisecond_constant_click_pattern() -> bool:
	if recent_click_intervals.size() < 8:
		return false
	var total := 0.0
	for interval in recent_click_intervals:
		total += interval
	var average: float = total / recent_click_intervals.size()
	if average <= 0.0 or average > ms_pattern_average_max:
		return false
	var variance := 0.0
	for interval in recent_click_intervals:
		var diff := interval - average
		variance += diff * diff
	variance /= recent_click_intervals.size()
	return variance <= ms_pattern_variance_max


func trigger_detection(message: String, close_on_ack: bool, now_unix: int) -> Dictionary:
	if anti_cheat_triggered:
		return {"triggered": false}

	anti_cheat_triggered = true
	anti_cheat_close_on_ack = close_on_ack
	var sanction_created := register_detection(now_unix)
	return {
		"triggered": true,
		"message": message,
		"close_on_ack": close_on_ack,
		"sanction_created": sanction_created
	}


func register_detection(now_unix: int) -> bool:
	anti_cheat_detection_count += 1
	history.append(make_warning())
	if anti_cheat_detection_count < detections_per_sanction:
		return false

	anti_cheat_detection_count = 0
	temp_sanction_count += 1
	if temp_sanction_count >= max_temp_sanctions:
		permanent_ban = true
		sanction_end_unix = 0
		history.append(make_permanent_ban())
	else:
		var duration_minutes: int = temp_sanction_count * sanction_step_minutes
		sanction_end_unix = now_unix + (duration_minutes * 60)
		history.append(make_temp_ban(duration_minutes * 60))
	return true


func has_active_sanction(now_unix: int) -> bool:
	if permanent_ban:
		return true
	if sanction_end_unix <= 0:
		return false
	return now_unix < sanction_end_unix


func clear_sanctions() -> void:
	anti_cheat_detection_count = 0
	temp_sanction_count = 0
	sanction_end_unix = 0
	permanent_ban = false
	cps_counter_second = -1
	cps_counter_clicks = 0
	detected_cps = 0


func clear_runtime_state() -> void:
	recent_click_intervals.clear()
	last_click_timestamp_ms = -1
	last_detection_constant_pattern = false
	constant_pattern_second_streak = 0
	anti_cheat_triggered = false
	anti_cheat_close_on_ack = false
	detected_cps = 0
	cps_counter_second = -1
	cps_counter_clicks = 0


func get_sanction_time_remaining(now_unix: int) -> int:
	return maxi(0, sanction_end_unix - now_unix)


func make_warning() -> Dictionary:
	return {
		"sanction_type": "warning",
		"time_remaining": "Avertissement",
		"active": false
	}


func make_temp_ban(duration_seconds: int) -> Dictionary:
	return {
		"sanction_type": "temporary_ban",
		"time_remaining": format_remaining_time(duration_seconds),
		"active": true
	}


func make_permanent_ban() -> Dictionary:
	return {
		"sanction_type": "permanent_ban",
		"time_remaining": "Definitif",
		"active": true
	}


static func can_change_pseudo(last_change_unix: int, now_unix: int) -> bool:
	if last_change_unix <= 0:
		return true
	return now_unix - last_change_unix >= PSEUDO_CHANGE_COOLDOWN


static func remaining_before_pseudo_change(last_change_unix: int, now_unix: int) -> int:
	if can_change_pseudo(last_change_unix, now_unix):
		return 0
	return PSEUDO_CHANGE_COOLDOWN - (now_unix - last_change_unix)


static func format_remaining_time(total_seconds: int) -> String:
	var safe_seconds := maxi(total_seconds, 0)
	var minutes: int = int(safe_seconds / 60.0)
	var seconds: int = safe_seconds % 60
	var hours: int = int(minutes / 60.0)
	minutes = minutes % 60
	if hours > 0:
		return "%02d h %02d min %02d s" % [hours, minutes, seconds]
	return "%02d min %02d s" % [minutes, seconds]


func _get_unix_time_now() -> int:
	return int(Time.get_unix_time_from_system())
