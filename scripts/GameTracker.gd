extends Node
## 记牌器数据层（自动加载为 GameTracker）：
## 记录本局双方各自“已使用”的卡牌——种类、费用、类型与使用次数。

signal tracker_changed()

var _used: Array[Dictionary] = [{}, {}]


func _ready() -> void:
	GameManager.card_played.connect(_on_card_played)
	GameManager.game_started.connect(reset)
	reset()


func reset() -> void:
	_used = [{}, {}]
	tracker_changed.emit()


func _on_card_played(pid: int, card: CardData) -> void:
	if card == null or pid < 0 or pid >= _used.size():
		return
	var key: String = card.id if card.id != "" else card.card_name
	var bucket: Dictionary = _used[pid]
	if bucket.has(key):
		bucket[key]["count"] = int(bucket[key]["count"]) + 1
	else:
		bucket[key] = {
			"id": key,
			"name": card.card_name,
			"cost": card.cost,
			"type": int(card.card_type),
			"count": 1,
		}
	tracker_changed.emit()


## 按费用升序（同费用按名称）返回统计条目
func entries(pid: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if pid < 0 or pid >= _used.size():
		return out
	for key in _used[pid]:
		out.append((_used[pid][key] as Dictionary).duplicate())
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["cost"]) != int(b["cost"]):
			return int(a["cost"]) < int(b["cost"])
		return str(a["name"]) < str(b["name"])
	)
	return out


func total_used(pid: int) -> int:
	var n := 0
	for e in entries(pid):
		n += int(e["count"])
	return n


func kind_count(pid: int) -> int:
	return entries(pid).size()
