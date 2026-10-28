extends Node
## 联机会话（自动加载为 Net）：完整的「创建房间 / 加入房间 / 观战 / 断线重连 / 延迟显示」框架。
##
## 权威模型：**房主权威**。房主跑真正的 `GameManager`，客户端只做两件事：
##   1. 把自己的操作意图（intent）发给房主；2. 把房主下发的状态快照渲染出来。
## 这样做的好处是客户端不需要跑一套战斗规则，也就不存在两边结算不一致的问题。
##
## 隐藏信息（联机必需）：快照是**按人定制**的——只有自己的手牌内容会下发，
## 对手的手牌只给张数；牌库只给张数。观战者两侧手牌都只看得到张数。
##
## 为什么不用 MultiplayerAPI / RPC：RPC 需要把节点树 × 多套 MultiplayerAPI 绑在一起，
## 在同一个进程里做「服务器 + 客户端」的自测非常别扭。这里直接用 ENetMultiplayerPeer
## 收发 JSON 包（自带 `topic` 字段），既好测也少一层魔法。

signal room_list_changed()
signal roster_changed()
signal session_started()
signal session_ended(reason: String)
signal snapshot_applied()
signal latency_changed(ms: int)
signal log_line(text: String)
## 匹配成功：双方座位就绪，可以进对局界面了
signal match_found()
## 匹配状态变化（搜索中 / 已开房等待 / 已匹配），界面刷新用
signal matchmaking_changed()

enum Role { OFFLINE, HOST, CLIENT }

const PROTOCOL := 1
const MAX_CONNECTIONS := 8
const DISCOVERY_PORT := 27016
const BEACON_INTERVAL := 1.0
const LOBBY_TIMEOUT := 8.0        ## 客户端等待房主确认的秒数

## 掉线后保留座位的秒数（超时判负）；做成变量是为了让测试不必真等 60 秒
var reconnect_grace := 60.0
## 匹配：找不到可加入的房间时，等这么久就自己开房等对手
var match_host_delay := 4.0
var matchmaking := false          ## 正在匹配中
var match_hosted := false         ## 匹配过程中自己开了房（等对手进来）
var _match_clock := 0.0

var role: int = Role.OFFLINE
var my_seat: int = -1             ## 0 = 房主席位（GameManager.PLAYER_ID），1 = 客机席位，-1 = 观战
var room_name := ""
var net_port := 27015
var player_name := "玩家"
var connected := false            ## 客户端：是否已和房主完成握手
var rtt_ms := 0
var turn_time_limit := 90         ## 联机每回合秒数（0 = 不限）；单人模式不用它
var last_error := ""

## peer_id -> {"name": String, "seat": int, "spectator": bool, "ready": bool}
var peers: Dictionary = {}
var reconnect_token := ""         ## 客机自己的重连令牌（掉线后用它对回原座位）
var guest_token := ""             ## 房主视角：客机座位对应的令牌
var _lan_rooms: Dictionary = {}   ## ip:port -> {"room","players","max","port","seen"}

var _peer: ENetMultiplayerPeer = null
var _udp: PacketPeerUDP = null
var _beacon_clock := 0.0
var _lobby_clock := 0.0
var _rtt_clock := 0.0
var _grace_clock := 0.0
var _disconnected_seat := -1      ## 房主视角：正在等待重连的座位（-1 = 没有）
var _pending_join := false        ## 客机已发起连接，还没收到 welcome
var _hello_sent := false          ## hello 是否已发出（必须等 ENet 握手完成后再发）
var _want_spectator := false      ## 本次加入是否是观战


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_discovery_socket()
	var gs := get_node_or_null("/root/GameSettings")
	if gs != null and gs.has_method("load_settings"):
		player_name = str(gs.get("player_name")) if str(gs.get("player_name")) != "" else player_name
		net_port = int(gs.get("net_port")) if int(gs.get("net_port")) > 0 else net_port


# ------------------------------ 对外：匹配（主界面的「开始匹配」） ------------------------------

## 开始匹配：先看局域网里有没有空房间（有就直接加入），等不到就自己开房等对手。
## 匹配成功后 `match_found` 会发出，界面据此切到对局。
func start_matchmaking(pname: String = "", port: int = -1, p_turn_limit: int = -1) -> void:
	leave_game()
	matchmaking = true
	match_hosted = false
	_match_clock = 0.0
	if pname != "":
		player_name = pname
	if port > 0:
		net_port = port
	if p_turn_limit >= 0:
		turn_time_limit = p_turn_limit
	last_error = ""
	_log("开始匹配对手…（局域网房间优先，找不到就自己开房等对手）")
	matchmaking_changed.emit()


## 取消匹配
func cancel_matchmaking() -> void:
	if not matchmaking:
		return
	matchmaking = false
	match_hosted = false
	leave_game()
	_log("已取消匹配")
	matchmaking_changed.emit()


## 匹配中的状态文案（界面直接用）
func matchmaking_text() -> String:
	if not matchmaking:
		return ""
	# 房主自己的 connected 一直是 true（那是它自己的服务器），所以要先判身份
	if is_host():
		return "已开房等待对手（房间 %s，端口 %d）" % [room_name, net_port]
	if connected:
		return "匹配成功，正在进入对局…"
	return "正在搜索对手…（%.0f 秒后仍没有就自己开房）" % maxf(0.0, match_host_delay - _match_clock)


## 房主 / 客机身份变化时同步「谁有权威、谁只读」，让 GameManager 的判定始终正确。
## 放在 NetSession 而不是界面里：快照可能在界面加载之前就到（必须早点把权威交出去）。
func _sync_authority() -> void:
	var gm := get_node_or_null("/root/GameManager")
	if gm == null:
		return
	var online := is_online()
	gm.net_authority = (not online) or is_host()
	gm.net_locked = online and is_spectator()
	gm.turn_time_limit = turn_time_limit if online else 0


# ------------------------------ 对外：房间生命周期 ------------------------------

func is_online() -> bool:
	return role != Role.OFFLINE


func is_host() -> bool:
	return role == Role.HOST


func is_spectator() -> bool:
	return role != Role.OFFLINE and my_seat < 0


## 联机时本机控制的座位（观战者为 -1）
func local_seat() -> int:
	return my_seat if role != Role.OFFLINE else GameManager.PLAYER_ID


## 创建房间（房主）。成功返回 true。
func host_game(p_room: String, p_port: int = -1, pname: String = "", p_turn_limit: int = -1) -> bool:
	leave_game()
	room_name = p_room if p_room != "" else "%s 的房间" % (pname if pname != "" else player_name)
	player_name = pname if pname != "" else player_name
	net_port = p_port if p_port > 0 else net_port
	if p_turn_limit >= 0:
		turn_time_limit = p_turn_limit
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(net_port, MAX_CONNECTIONS)
	if err != OK:
		last_error = "无法监听端口 %d（错误码 %d）：可能被占用或权限不足" % [net_port, err]
		return false
	_peer = peer
	role = Role.HOST
	my_seat = 0
	connected = true
	peers.clear()
	peers[0] = {"name": player_name, "seat": 0, "spectator": false, "ready": true}
	guest_token = _make_token()
	_disconnected_seat = -1
	_log("已创建房间「%s」，端口 %d（等待对手加入）" % [room_name, net_port])
	_sync_authority()
	roster_changed.emit()
	return true


## 加入房间（客机）。`as_spectator` = 观战，不进座位、不能操作。
func join_game(ip: String, p_port: int = -1, pname: String = "", as_spectator: bool = false) -> bool:
	leave_game()
	net_port = p_port if p_port > 0 else net_port
	player_name = pname if pname != "" else player_name
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, net_port)
	if err != OK:
		last_error = "无法连接 %s:%d（错误码 %d）" % [ip, net_port, err]
		return false
	_peer = peer
	role = Role.CLIENT
	my_seat = -1
	connected = false
	_pending_join = true
	_lobby_clock = 0.0
	peers.clear()
	_send(_to_host_id(), {"t": "hello", "v": PROTOCOL, "name": player_name,
		"spectator": as_spectator, "token": reconnect_token})
	_sync_authority()
	_log("正在连接 %s:%d …" % [ip, net_port])
	return true


func leave_game() -> void:
	if _peer != null and connected:
		# 主动离开要显式通知对方：ENet 自带的掉线检测默认要几十秒才认定断开
		if role == Role.CLIENT:
			_send(1, {"t": "bye"})
		else:
			_broadcast_raw({"t": "bye"})
		_peer.poll()
	if _peer != null:
		_peer.close()
	_peer = null
	role = Role.OFFLINE
	my_seat = -1
	connected = false
	peers.clear()
	_disconnected_seat = -1
	_pending_join = false
	_grace_clock = 0.0
	room_name = ""
	_sync_authority()


## 房主：开始对局并通知所有客户端
func start_session() -> void:
	if role != Role.HOST:
		return
	GameManager.new_game()
	_broadcast_snapshot(true)
	session_started.emit()


# ------------------------------ 对外：操作意图与快照 ------------------------------

## 客户端把自己的操作发给房主（房主就地执行；非法意图会被忽略并回一条提示）
func send_intent(action: Dictionary) -> void:
	if role == Role.OFFLINE:
		return
	if role == Role.HOST:
		_apply_intent(0, action)
		return
	if is_spectator():
		return
	if not connected:
		return          # 还没连上房主，包发不出去
	action["t"] = "intent"
	_send(1, action)


## 房主把（按人定制的）状态快照分发给所有人
func broadcast_state() -> void:
	if role == Role.HOST:
		_broadcast_snapshot(false)


# ------------------------------ 每帧：收包 / 心跳 / 掉线 ------------------------------

func _process(delta: float) -> void:
	_beacon_clock += delta
	_rtt_clock += delta
	if is_online() and _peer != null:
		_peer.poll()
		while _peer.get_available_packet_count() > 0:
			var sender := _peer.get_packet_peer()
			var raw := _peer.get_packet()
			var text := raw.get_string_from_utf8()
			var msg = JSON.parse_string(text)
			if typeof(msg) == TYPE_DICTIONARY:
				_handle(sender, msg)
		_watch_peers(delta)
		if _rtt_clock >= 1.0:
			_rtt_clock = 0.0
			_update_rtt()
	if role == Role.HOST and _beacon_clock >= BEACON_INTERVAL:
		_beacon_clock = 0.0
		_send_beacon()
	_poll_discovery(delta)
	if matchmaking and not connected:
		_match_clock += delta
		# ① 局域网里有空房间就直接进
		if not match_hosted and not is_online():
			for room in lan_rooms():
				if int(room["players"]) < int(room["max"]):
					_log("匹配到房间「%s」（%s:%d），正在加入…" % [str(room["room"]), str(room["ip"]), int(room["port"])])
					join_game(str(room["ip"]), int(room["port"]), player_name)
					matchmaking_changed.emit()
					break
		# ② 等不到就自己开房，让对手来匹配我
		if not is_online() and _match_clock >= match_host_delay:
			match_hosted = true
			if host_game("", net_port, player_name, turn_time_limit):
				_log("暂时没有可加入的房间，已开房等待对手（端口 %d）" % net_port)
				matchmaking_changed.emit()
	elif matchmaking and connected:
		_match_clock = 0.0
	if role == Role.CLIENT and _pending_join:
		# ENet 要先握手完成才能发数据包：连上之后再发 hello（提前发会被直接丢掉）
		if not _hello_sent and _peer != null and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			_hello_sent = true
			_send(1, {"t": "hello", "v": PROTOCOL, "name": player_name,
				"spectator": _want_spectator, "token": reconnect_token})
		_lobby_clock += delta
		if _lobby_clock > LOBBY_TIMEOUT:
			_pending_join = false
			last_error = "连接超时：房主没有响应（确认 IP / 端口、防火墙）"
			_log(last_error)
			session_ended.emit(last_error)
			leave_game()


func _watch_peers(delta: float) -> void:
	if role == Role.HOST:
		for pid in peers.keys():
			if pid == 0 or _peer_alive(pid):
				continue
			# 有人掉线：保留座位等待重连
			var info: Dictionary = peers[pid]
			peers.erase(pid)
			if info["seat"] == 1 and _disconnected_seat < 0:
				_disconnected_seat = 1
				_grace_clock = 0.0
				_log("对手掉线了，保留座位 %d 秒等待重连" % int(reconnect_grace))
				_broadcast_raw({"t": "peer_lost", "name": info["name"], "grace": reconnect_grace})
			roster_changed.emit()
		if _disconnected_seat >= 0:
			_grace_clock += delta
			if _grace_clock >= reconnect_grace:
				_disconnected_seat = -1
				_log("重连超时：对手判负")
				GameManager.net_judge_disconnect(1)
				_broadcast_snapshot(false)
				session_ended.emit("对手重连超时")
	elif role == Role.CLIENT:
		if _peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED and connected:
			connected = false
			_pending_join = false
			_log("与房主的连接已断开")
			session_ended.emit("与房主的连接已断开")


func _update_rtt() -> void:
	if _peer == null:
		return
	var ms := 0
	if role == Role.HOST:
		for pid in peers.keys():
			if pid == 0:
				continue
			var p := _peer.get_peer(pid)
			if p != null and p.get_state() != ENetPacketPeer.STATE_DISCONNECTED:
				ms = maxi(ms, int(p.get_statistic(ENetPacketPeer.PEER_LAST_ROUND_TRIP_TIME)))
	else:
		var p := _peer.get_peer(1)
		if p != null:
			ms = int(p.get_statistic(ENetPacketPeer.PEER_LAST_ROUND_TRIP_TIME))
	if ms != rtt_ms:
		rtt_ms = ms
		latency_changed.emit(rtt_ms)


# ------------------------------ 收包处理 ------------------------------

func _handle(sender: int, msg: Dictionary) -> void:
	var topic := str(msg.get("t", ""))
	match topic:
		"hello":
			_host_on_hello(sender, msg)
		"welcome":
			_client_on_welcome(sender, msg)
		"roster":
			if role == Role.CLIENT:
				_apply_roster(msg)
		"snapshot":
			if role == Role.CLIENT:
				_apply_snapshot(msg)
		"intent":
			if role == Role.HOST:
				_apply_intent(sender, msg)
		"log":
			if role == Role.CLIENT:
				log_line.emit(str(msg.get("text", "")))
		"event":
			if role == Role.CLIENT:
				_event(str(msg.get("name", "")), msg)
		"peer_lost":
			if role == Role.CLIENT:
				_log("%s 掉线了，等待重连…" % str(msg.get("name", "对手")))
		"bye":
			if role == Role.HOST:
				var info_bye: Dictionary = peers.get(sender, {})
				if int(info_bye.get("seat", -1)) == 1:
					peers.erase(sender)
					_disconnected_seat = 1
					_grace_clock = 0.0
					_log("对手离开了房间，保留座位 %.0f 秒等待重连" % reconnect_grace)
					_broadcast_raw({"t": "peer_lost", "name": str(info_bye.get("name", "对手")), "grace": reconnect_grace})
					roster_changed.emit()
				_peer.disconnect_peer(sender)
		_:
			pass


func _host_on_hello(sender: int, msg: Dictionary) -> void:
	if int(msg.get("v", 0)) != PROTOCOL:
		_send(sender, {"t": "reject", "reason": "版本不一致（对方协议 %s）" % str(msg.get("v"))})
		return
	var spectator := bool(msg.get("spectator", false))
	var token := str(msg.get("token", ""))
	var seat := -1
	if not spectator:
		# 座位是否空着只看「有座位的玩家」：观战者不占座，掉线等待重连的座位算被占
		var seated := 0
		for pid2 in peers.keys():
			if int(peers[pid2].get("seat", -1)) >= 0:
				seated += 1
		# 重连：令牌对得上就回到原座位
		if token != "" and token == guest_token and seated <= 1 and _disconnected_seat == 1:
			seat = 1
			_disconnected_seat = -1
			_log("对手用重连令牌回到了座位 1")
		elif seated <= 1:
			seat = 1
			guest_token = _make_token()
		else:
			# 座位满了：自动转为观战（满员时观战是"完整框架"里应有的降级）
			spectator = true
	peers[sender] = {"name": str(msg.get("name", "玩家")), "seat": seat, "spectator": spectator, "ready": true}
	_send(sender, {"t": "welcome", "seat": seat, "spectator": spectator, "host": peers[0]["name"],
		"room": room_name, "port": net_port, "token": guest_token if seat == 1 else ""})
	_log("%s %s" % [str(msg.get("name", "玩家")), "观战中" if spectator else "加入了房间（座位 %d）" % (seat + 1)])
	_broadcast_roster()
	_broadcast_snapshot(false)
	# 匹配来的：真人坐上座位 1，就算匹配成功
	if matchmaking and seat == 1:
		matchmaking = false
		_log("匹配成功：对手已就座，开始对局")
		match_found.emit()
		matchmaking_changed.emit()


func _client_on_welcome(_sender: int, msg: Dictionary) -> void:
	_pending_join = false
	connected = true
	my_seat = int(msg.get("seat", -1))
	room_name = str(msg.get("room", room_name))
	# 房主分配令牌：只有坐进座位的人拿得到，掉线后可以凭它对回座位
	var tok := str(msg.get("token", ""))
	if tok != "":
		reconnect_token = tok
	elif my_seat == 1:
		reconnect_token = str(msg.get("guest_token", ""))
	_log("已加入房间「%s」：%s" % [room_name, "观战" if my_seat < 0 else "座位 %d" % (my_seat + 1)])
	_sync_authority()
	roster_changed.emit()
	# 匹配来的：坐进座位就算匹配成功，界面可以切到对局了
	if matchmaking and my_seat == 1:
		matchmaking = false
		_log("匹配成功：你是客机（座位 2）")
		match_found.emit()
		matchmaking_changed.emit()


func _apply_roster(msg: Dictionary) -> void:
	peers.clear()
	var list: Array = msg.get("peers", [])
	for entry in list:
		peers[int(entry.get("peer", 0))] = entry
	roster_changed.emit()


func _apply_snapshot(msg: Dictionary) -> void:
	if not GameManager.apply_net_snapshot(msg.get("state", {})):
		return
	snapshot_applied.emit()


func _apply_intent(sender: int, action: Dictionary) -> void:
	if not GameManager.game_active() or not connected:
		return
	var seat := int(peers.get(sender, {}).get("seat", -1))
	if seat < 0:
		_send(sender, {"t": "log", "text": "观战者不能操作"})
		return
	if seat != GameManager.current_player:
		_send(sender, {"t": "log", "text": "现在不是你的回合"})
		return
	var kind := str(action.get("kind", ""))
	var ok := false
	match kind:
		"play_card":
			ok = GameManager.play_card(seat, int(action.get("hand", -1)),
				int(action.get("tu", -1)), int(action.get("tp", -1)), bool(action.get("front", false)),
				int(action.get("slot", -1)))
		"attack":
			ok = GameManager.attack(seat, int(action.get("unit", -1)),
				int(action.get("target", -1)), int(action.get("tp", -1)))
		"front":
			ok = GameManager.place_in_front(seat, int(action.get("unit", -1)))
		"leave_front":
			# 移出防御格：与移入共用「每回合一次」的名额，门禁由 GameManager.leave_front 兜底
			ok = GameManager.leave_front(seat, int(action.get("unit", -1)), int(action.get("slot", -1)))
		"use_skill":
			# 主动技能：座位校验照旧（上面已经挡掉“不是你的回合”“观战者”）；
			# 单位归属 / 横置 / 冻结 / 能量点 / 每回合一次都由 GameManager.use_skill 兜底
			ok = GameManager.use_skill(seat, int(action.get("unit", -1)),
				int(action.get("target", -1)), int(action.get("tp", -1)))
		"fuse":
			# 融合：材料数量 / 兵种 / 费用 / 前置条件全部由 GameManager.fuse 兜底
			ok = GameManager.fuse(seat, int(action.get("hand", -1)),
				action.get("mats", []))
		"end_turn":
			GameManager.advance_turn()
			ok = true
		"concede":
			GameManager.concede(seat)
			ok = true
		"discover":
			ok = GameManager.resolve_discover(int(action.get("index", -1)))
		"invoke_choice":
			ok = GameManager.resolve_invoke_choice(int(action.get("dest", -1)))
		"mulligan":
			# 客机的起手换牌：按卡牌 id 在房主那份手牌里找出对应对象再换（房主才是权威）
			var mp := GameManager.get_player(seat)
			var picks: Array = []
			if mp != null:
				for cid in action.get("ids", []):
					for c in mp.hand:
						if c.id == str(cid) and not picks.has(c):
							picks.append(c)
							break
			GameManager.finish_mulligan_cards(seat, picks)
			ok = true
		_:
			ok = false
	if not ok:
		_send(sender, {"t": "log", "text": str(action.get("hint", "操作无效"))})
	# 房主状态变了：把新的（定制）快照发给每个人
	_broadcast_snapshot(false)


# ------------------------------ 快照：按人定制（隐藏信息） ------------------------------

func _broadcast_snapshot(starting: bool) -> void:
	if role != Role.HOST:
		return
	var ids: Array = [0]
	for pid in peers.keys():
		if pid != 0:
			ids.append(pid)
	for pid in ids:
		var seat := 0 if pid == 0 else int(peers[pid]["seat"])
		var msg := {"t": "snapshot", "state": GameManager.net_snapshot(seat), "start": starting}
		_send(pid, msg)


# ------------------------------ 发送 / 日志 ------------------------------

## 房主视角：某个 peer 是否还在（ENetMultiplayerPeer 没有 get_peer_ids()，
## 只能用 get_peer(id) 拿到 ENetPacketPeer 再看它的连接状态；拿不到对象 = 已经不在了）
func _peer_alive(pid: int) -> bool:
	if _peer == null or pid == 0:
		return true
	var p := _peer.get_peer(pid)
	if p == null:
		return false
	return p.get_state() != ENetPacketPeer.STATE_DISCONNECTED


## 客户端发往房主的目标 peer 是 1（ENet 约定：0 = 广播，只有服务器能用）
func _to_host_id() -> int:
	return 1 if role == Role.CLIENT else 0


func _send(peer_id: int, msg: Dictionary) -> void:
	if _peer == null:
		return
	_peer.set_target_peer(peer_id)
	_peer.put_packet(JSON.stringify(msg).to_utf8_buffer())


func _broadcast_raw(msg: Dictionary) -> void:
	if _peer == null:
		return
	_peer.set_target_peer(0)
	_peer.put_packet(JSON.stringify(msg).to_utf8_buffer())


func _broadcast_roster() -> void:
	var list: Array = []
	for pid in peers.keys():
		var info: Dictionary = peers[pid].duplicate()
		info["peer"] = pid
		list.append(info)
	_broadcast_raw({"t": "roster", "peers": list})
	roster_changed.emit()


## 房主日志（会同步给客机；秘密信息由 GameManager 用 net_public_log 过滤）
func _log(text: String) -> void:
	log_line.emit(text)
	if role == Role.HOST:
		_broadcast_raw({"t": "log", "text": text})


## 房主向客户端广播一个「表现层事件」（音效 / 横幅等），不涉及隐藏信息
func broadcast_event(name: String, extra: Dictionary = {}) -> void:
	if role != Role.HOST:
		return
	var msg := {"t": "event", "name": name}
	msg.merge(extra, true)
	_broadcast_raw(msg)


func _event(name: String, _extra: Dictionary) -> void:
	if name == "":
		return
	log_line.emit("")


# ------------------------------ 局域网房间发现 ------------------------------

func _ensure_discovery_socket() -> void:
	if _udp != null:
		return
	_udp = PacketPeerUDP.new()
	_udp.set_broadcast_enabled(true)
	_udp.bind(DISCOVERY_PORT)


func _send_beacon() -> void:
	if _udp == null:
		return
	var payload := JSON.stringify({
		"t": "beacon", "room": room_name, "port": net_port,
		"players": peers.size(), "max": 2, "host": player_name,
	}).to_utf8_buffer()
	_udp.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	_udp.put_packet(payload)


func _poll_discovery(delta: float) -> void:
	if _udp == null:
		return
	while _udp.get_available_packet_count() > 0:
		var addr := _udp.get_packet_ip()
		var msg = JSON.parse_string(_udp.get_packet().get_string_from_utf8())
		if typeof(msg) == TYPE_DICTIONARY and str(msg.get("t", "")) == "beacon":
			var key := "%s:%d" % [addr, int(msg.get("port", net_port))]
			_lan_rooms[key] = {
				"ip": addr, "port": int(msg.get("port", net_port)), "room": str(msg.get("room", "")),
				"players": int(msg.get("players", 0)), "max": int(msg.get("max", 2)),
				"host": str(msg.get("host", "")), "seen": 0.0,
			}
			room_list_changed.emit()
	# 3 秒没再看到信标就从列表里移除
	var stale: Array[String] = []
	for key in _lan_rooms.keys():
		_lan_rooms[key]["seen"] = float(_lan_rooms[key]["seen"]) + delta
		if float(_lan_rooms[key]["seen"]) > 3.0:
			stale.append(key)
	for key in stale:
		_lan_rooms.erase(key)
		room_list_changed.emit()


## 房间列表（按房间名排序，供大厅显示）
func lan_rooms() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for key in _lan_rooms.keys():
		out.append(_lan_rooms[key])
	out.sort_custom(func(a, b): return str(a["room"]) < str(b["room"]))
	return out


# ------------------------------ 工具 ------------------------------

func _make_token() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var s := ""
	for i in 8:
		s += "0123456789ABCDEF"[rng.randi() % 16]
	return s


func roster_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	for pid in peers.keys():
		var info: Dictionary = peers[pid]
		var tag := "（房主）" if pid == 0 else ""
		var seat := int(info.get("seat", -1))
		lines.append("%s%s%s" % [str(info.get("name", "?")), tag, " · 观战" if seat < 0 else " · 座位 %d" % (seat + 1)])
	return lines
