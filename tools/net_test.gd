extends SceneTree
## 联机框架测试：同一个进程里起「房主 + 客机 + 观战」三个会话，用**真实 ENet 环回**（127.0.0.1）
## 跑完：握手与座位分配、按人定制的快照（隐藏信息）、操作意图与非法意图拒绝、回合超时、
## 观战降级、掉线保留座位、令牌重连、宽限期超时判负。
##
## 两条经验（写进注释免得下次再踩）：
##   1. **ENet 握手要真实时间**：等待必须跨帧 + 每帧 `OS.delay_msec`，帧内 while 循环等不到；
##   2. **必须等连接建立后再发包**：`create_client()` 之后立刻 `put_packet` 会被丢掉并报
##      「multiplayer instance isn't currently connected」。
##
## 运行：godot --headless --path <项目目录> --script res://tools/net_test.gd

const PORT := 27615
const HANDSHAKE_WAIT := 240        ## 握手最多等多少帧（每帧 4ms 真实时间）
const SETTLE_WAIT := 12            ## 发包之后等几帧让对面处理

var _fails := 0
var _frames := 0
var _stage := 0
var _wait := 0
var _gm
var _db
var host
var client
var spectator
var _token := ""
var _fail_lines: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		return _bootstrap()
	_pump()
	_wait += 1
	match _stage:
		1:
			if client.connected or _wait > HANDSHAKE_WAIT:
				_stage_handshake_done()
		2:
			if _wait > SETTLE_WAIT:
				_stage_intent_done()
		3:
			if _wait > SETTLE_WAIT:
				_stage_reject_done()
		4:
			if spectator == null:
				spectator = _session()
				_check(spectator.join_game("127.0.0.1", PORT, "观战丙", true), "观战者发起连接")
				_wait = 0
			elif spectator.connected or _wait > HANDSHAKE_WAIT:
				_stage_spectator_done()
		5:
			if int(host.get("_disconnected_seat")) >= 0 or _wait > 60:
				_stage_lost_done()
		6:
			if client.connected or _wait > HANDSHAKE_WAIT:
				_stage_reconnect_done()
		7:
			if _wait > SETTLE_WAIT:
				_finish()
				return true
	return _frames > 8000


func _bootstrap() -> bool:
	_gm = root.get_node_or_null("GameManager")
	_db = root.get_node_or_null("CardDB")
	if _gm == null or _db == null:
		_check(false, "GameManager / CardDB 自动加载")
		_finish()
		return true
	_db.reset_to_default()
	host = _session()
	client = _session()
	host.reconnect_grace = 5.0          # 观察窗口内先不判负，最后单独验证超时
	_check(host.host_game("测试房", PORT, "房主甲", 60), "房主创建房间（端口 %d）" % PORT)
	_check(host.is_host() and host.my_seat == 0, "房主身份与座位正确")
	_check(client.join_game("127.0.0.1", PORT, "客机乙"), "客机发起连接")
	_stage = 1
	_wait = 0
	return false


# ------------------------------ 阶段 1：握手 + 隐藏信息 ------------------------------

func _stage_handshake_done() -> void:
	_check(client.connected, "客机与房主完成握手（等了 %d 帧）" % _wait)
	_check(client.my_seat == 1, "客机拿到座位 1（实际 %d）" % client.my_seat)
	_check(host.peers.size() == 2, "房主看到 2 个成员（实际 %d）" % host.peers.size())
	_check(client.reconnect_token != "", "房主给客机下发了重连令牌（%s）" % client.reconnect_token)
	_token = client.reconnect_token
	# 客机会话一连上就把本机 GameManager 标成「无权威」（这是生产行为：客户端不跑规则）。
	# 本测试里房主与客机共用同一个 GameManager（同一个进程），所以断言之后要还原成房主侧，
	# 否则后面的房主行为断言会被这个标记挡住。
	_check(not _gm.net_authority, "客机连上后本机被标记为「无权威」（客户端不跑规则）")
	_check(_gm.net_locked == false, "客机不是观战，因此没有被锁成只读")
	_gm.net_authority = true
	_test_redaction()
	_gm.new_game()
	_gm.current_player = 1                       # 轮到客机
	client.send_intent({"kind": "end_turn"})
	_stage = 2
	_wait = 0


func _test_redaction() -> void:
	_gm.new_game()
	var foe: PlayerState = _gm.get_player(1)
	var for_host: Dictionary = _gm.net_snapshot(0)
	var for_guest: Dictionary = _gm.net_snapshot(1)
	var for_spec: Dictionary = _gm.net_snapshot(-1)
	_check(for_host["players"][0]["hand"].size() > 0, "房主快照里自己的手牌内容完整")
	_check(for_host["players"][1]["hand"].size() == 0, "房主快照里对手手牌内容不下发（看不到）")
	_check(int(for_host["players"][1]["hand_count"]) == foe.hand.size(),
		"对手手牌只下发张数（%d）" % int(for_host["players"][1]["hand_count"]))
	_check(for_host["players"][0].has("deck_count") and not for_host["players"][0].has("deck"),
		"牌库只下发张数、不下发内容")
	_check(int(for_guest["players"][0]["id"]) == 0 and for_guest["players"][0]["hand"].size() == foe.hand.size(),
		"客机快照是镜像的：自己在下标 0 且能看到自己的手牌（%d 张）" % for_guest["players"][0]["hand"].size())
	_check(for_guest["players"][1]["hand"].size() == 0 and int(for_guest["players"][1]["id"]) == 1,
		"客机看不到房主的手牌内容")
	_check(for_spec["players"][0]["hand"].size() == 0 and for_spec["players"][1]["hand"].size() == 0,
		"观战快照两侧手牌内容都不下发")
	_gm.summon_unit(1, _db.get_card("c001"))
	var units: Array = _gm.net_snapshot(1)["players"][0]["board"]
	_check(units.size() == 1 and int(units[0]["owner"]) == 0,
		"客机视角里自己的随从 owner 被镜像成 0（%d）" % int(units[0]["owner"]))


# ------------------------------ 阶段 2/3：意图与拒绝 ------------------------------

func _stage_intent_done() -> void:
	_check(_gm.current_player == 0, "客机的「结束回合」意图被房主执行（现在轮到 %d）" % _gm.current_player)
	client.send_intent({"kind": "play_card", "hand": 0})
	_stage = 3
	_wait = 0


func _stage_reject_done() -> void:
	_check(_gm.current_player == 0, "非我方回合的意图没有改变行动方（仍是 %d）" % _gm.current_player)
	# 回合超时（纯逻辑，不用等）
	_gm.turn_time_limit = 1
	_gm.current_player = 0
	_gm.turn_deadline_msec = Time.get_ticks_msec() - 1
	var before: int = _gm.current_player
	_gm._process(0.0)
	_check(_gm.current_player != before, "回合超时会自动结束回合（%d -> %d）" % [before, _gm.current_player])
	_gm.turn_time_limit = 0
	_gm.turn_deadline_msec = 0
	_stage = 4
	_wait = 0


# ------------------------------ 阶段 4：观战 ------------------------------

func _stage_spectator_done() -> void:
	_check(spectator.connected, "观战者完成握手（等了 %d 帧）" % _wait)
	_check(spectator.my_seat < 0 and spectator.is_spectator(), "观战者没有座位（seat=%d）" % spectator.my_seat)
	var seated := 0
	for pid in host.peers.keys():
		if int(host.peers[pid].get("seat", -1)) >= 0:
			seated += 1
	_check(seated == 2, "观战者不算座位（有座位的玩家 %d 个）" % seated)
	_check(host.peers.size() == 3, "房主看到房主 + 客机 + 观战者（实际 %d）" % host.peers.size())
	# 掉线检测：塞一个「幽灵成员」验证房主的判定（真实 ENet 断开要等它自己的超时，默认几十秒）
	host.peers[999] = {"name": "客机乙", "seat": 1, "spectator": false, "ready": true}
	_stage = 5
	_wait = 0


# ------------------------------ 阶段 5/6：掉线与重连 ------------------------------

func _stage_lost_done() -> void:
	_check(int(host.get("_disconnected_seat")) == 1,
		"房主检测到成员掉线并保留了座位（等了 %d 帧）" % _wait)
	_check(not host.peers.has(999), "掉线成员已从名单里摘掉（剩下 %d 个）" % host.peers.size())
	_check(_gm.game_active(), "掉线瞬间还没有判负（宽限期 %.0f 秒）" % float(host.reconnect_grace))
	# 真实客机也退掉，然后用令牌重连
	client.leave_game()
	client = _session()
	_check(client.join_game("127.0.0.1", PORT, "客机乙"), "客机用重连令牌重连")
	client.reconnect_token = _token
	_stage = 6
	_wait = 0


func _stage_reconnect_done() -> void:
	_check(client.connected, "重连握手完成（等了 %d 帧）" % _wait)
	_check(client.my_seat == 1, "重连后回到原来的座位 1（实际 %d）" % client.my_seat)
	_check(int(host.get("_disconnected_seat")) < 0, "房主清掉了「等待重连」标记")
	_check(client.reconnect_token == _token, "重连令牌保持不变（%s）" % client.reconnect_token)
	# 宽限期超时判负：直接推进等待时钟，不真等 60 秒
	host.reconnect_grace = 0.05
	host._disconnected_seat = 1
	host._watch_peers(0.2)
	_check(not _gm.game_active() and _gm.winner == 0, "重连超时判掉线者负（winner=%d）" % _gm.winner)
	_stage = 7
	_wait = 0


# ------------------------------ 辅助 ------------------------------

## 建一个会话实例（挂进树里但关掉自动 _process，由测试逐帧推进）
func _session():
	var sess = load("res://scripts/NetSession.gd").new()
	root.add_child(sess)
	sess.set_process(false)
	return sess


func _pump() -> void:
	OS.delay_msec(4)        # ENet 握手要真实时间
	for s in [host, client, spectator]:
		if s != null and is_instance_valid(s):
			s._process(0.004)


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	for s in [host, client, spectator]:
		if s != null and is_instance_valid(s):
			s.leave_game()
			s.queue_free()
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 联机测试结束：失败 %d 项（共 %d 帧）===" % [_fails, _frames])
	quit(1 if _fails > 0 else 0)
