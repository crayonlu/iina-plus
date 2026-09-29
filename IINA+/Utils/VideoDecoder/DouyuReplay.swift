//
//  DouyuReplay.swift
//  IINA+
//
//  斗鱼回放（直播录像）：场次列表、分P、逐档清晰度与播放地址签名。
//

import Foundation
import Alamofire
import Marshal
import JavaScriptCore

// MARK: - Endpoints

private let vodShowEndpoint = "https://v.douyu.com/show/"
private let vodListEndpoint = "https://v.douyu.com/wgapi/vod/center/authorShowVideoList"
private let vodPartsEndpoint = "https://v.douyu.com/wgapi/vod/center/getShowReplayList"
private let vodStreamEndpoint = "https://v.douyu.com/wgapi/vodnc/front/stream/getStreamUrlWeb"

/// 回放接口对 did 无校验，沿用与直播签名相同的匿名 did。
private let vodDID = "10000000000000000000000000001501"
/// authorShowVideoList 的 limit 上限为 20。
let vodListLimit = 20

// MARK: - Models

/// 一次直播（一场）的录像。`hashId` 为该场第 1 个分P。
struct DouyuReplaySession: Sendable {
	var hashId: String
	var title: String
	var cover: String
	var durationStr: String
	var durationSecs: Int
	/// 开播时间（unix 秒）
	var recordedAt: Int
	var partCount: Int
	var showId: Int
	var upID: String
	var viewText: String
	var timeFormat: String
}

/// 一场录像里的一个分P。
struct DouyuReplayPart: Sendable {
	var hashId: String
	var title: String
	var remark: String
	var durationStr: String
	var durationSecs: Int
	/// 1-based
	var partNum: Int
	var showId: Int
	var cover: String
	var viewText: String
}

/// 一档清晰度，字段全部来自 getStreamUrlWeb 的 thumb_video 条目，逐档原样保留。
struct DouyuReplayQuality: Sendable {
	var name: String
	var streamType: String
	var streamFormat: String
	var level: Int
	var bitRate: Int
	var fileSize: Int64
	var nowFree: Int
	var url: String
}

/// 回放播放页的解析结果。
struct DouyuVodPage: Sendable {
	var hashId: String
	var vid: String
	var pointID: String
	var signScript: String
	var title: String
	var cover: String
	var author: String
	var duration: Int
	var upID: String
}

struct DouyuVodInfo: LiveInfo {
	var title: String = ""
	var name: String = ""
	var avatar: String = ""
	var cover: String = ""
	var isLiving = true
	var site: SupportSites = .douyuVod
}

// MARK: - URL 构造

/// 本地回放地址的构造规则；这些地址同时是播放器的 watch_later 记账凭据，必须稳定。
enum DouyuReplayURL {
	static let pathPrefix = "/douyu/replay/"

	/// 从 https://v.douyu.com/show/{hash_id} 之类的链接里取 hash_id。
	static func hashId(from url: String) -> String? {
		guard let comps = URLComponents(string: url) else { return nil }
		let comps2 = comps.path.split(separator: "/").map(String.init)
		guard let index = comps2.firstIndex(of: "show"), comps2.count > index + 1 else { return nil }
		let hashId = comps2[index + 1]
		guard !hashId.isEmpty else { return nil }
		return hashId.split(separator: ".").first.map(String.init)
	}

	/// 播放器实际打开的地址：本地播放列表（含当前分P及之后的分P）。
	static func playlist(hashId: String, upID: String, level: Int, partNum: Int) -> String {
		var url = "http://127.0.0.1:\(Preferences.shared.dmPort)\(pathPrefix)\(hashId)/playlist.m3u?level=\(level)"
		if partNum > 0, !upID.isEmpty {
			url += "&p=\(partNum)&up=\(upID)"
		}
		return url
	}

	/// 播放列表条目：单个分P的稳定地址，由本地服务器现签后直接返回 m3u8 内容。
	/// 不走 302：播放器是按「跳转后」的地址给播放列表条目记账的，一旦跳转，
	/// 进度就不是记在这条稳定地址上了。
	static func stream(hashId: String, level: Int) -> String {
		"http://127.0.0.1:\(Preferences.shared.dmPort)\(pathPrefix)\(hashId)/stream.m3u8?level=\(level)"
	}
}

// MARK: - JS 签名

/// 执行播放页内联的 `ub98484234(point_id, did, ts)` 签名函数。
///
/// 签名脚本会 eval 出依赖 `CryptoJS.MD5` 的代码，crypto-js 由 App bundle 提供
/// （`Contents/Resources/crypto-js.js`）。`JSContext` 不是 `Sendable`，因此只在
/// 同步函数内创建与使用，不做跨线程缓存。
enum DouyuVodSigner {
	private static let cryptoJS: String? = {
		guard let url = Bundle.main.url(forResource: "crypto-js", withExtension: "js"),
			  let script = try? String(contentsOf: url, encoding: .utf8) else {
			return nil
		}
		return script
	}()

	static func sign(pointID: String, script: String, did: String, ts: Int) -> String? {
		guard let cryptoJS else {
			Log("Douyu replay: crypto-js.js not found in bundle.")
			return nil
		}
		guard let context = JSContext() else { return nil }
		context.exceptionHandler = { _, error in
			Log("Douyu replay sign error: \(error?.toString() ?? "unknown")")
		}
		context.evaluateScript(cryptoJS)
		context.evaluateScript(script)
		let expression = "ub98484234(\(pointID), \"\(did)\", \(ts))"
		guard let result = context.evaluateScript(expression)?.toString(),
			  !result.isEmpty,
			  result != "undefined" else {
			return nil
		}
		return result
	}
}

// MARK: - 解析工具

/// Marshal 的 JSON 里数字是 NSNumber、字符串是 String；两种都要能吃下。
private func douyuText(_ value: Any?) -> String {
	switch value {
	case let s as String:
		return s.trimmingCharacters(in: .whitespacesAndNewlines)
	case let n as NSNumber:
		return n.stringValue
	default:
		return ""
	}
}

private func douyuInt(_ value: Any?) -> Int {
	switch value {
	case let n as NSNumber:
		return n.intValue
	case let s as String:
		return Int(s) ?? 0
	default:
		return 0
	}
}

private func douyuInt64(_ value: Any?) -> Int64 {
	switch value {
	case let n as NSNumber:
		return n.int64Value
	case let s as String:
		return Int64(s) ?? 0
	default:
		return 0
	}
}

/// "MM:SS" / "HH:MM:SS"（分可超过 59，如 "120:02"）→ 秒。
private func douyuDurationSeconds(_ value: Any?) -> Int {
	let text = douyuText(value)
	guard !text.isEmpty else { return 0 }
	let parts = text.split(separator: ":").compactMap { Int($0) }
	switch parts.count {
	case 2:
		return parts[0] * 60 + parts[1]
	case 3:
		return parts[0] * 3600 + parts[1] * 60 + parts[2]
	default:
		return 0
	}
}

private func douyuMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
	guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
	let range = NSRange(text.startIndex..., in: text)
	guard let match = regex.firstMatch(in: text, range: range),
		  match.numberOfRanges > group,
		  let found = Range(match.range(at: group), in: text) else {
		return nil
	}
	return String(text[found])
}

/// 播放页里的 `$DATA.ROOM` 对象字面量（未加引号的键，不是合法 JSON）。
private func douyuRoomBlock(in html: String) -> String? {
	guard let keyRange = html.range(of: "ROOM:"),
		  let open = html[keyRange.upperBound...].firstIndex(of: "{") else {
		return nil
	}
	var depth = 0
	var index = open
	while index < html.endIndex {
		let char = html[index]
		if char == "{" {
			depth += 1
		} else if char == "}" {
			depth -= 1
			if depth == 0 {
				return String(html[open...index])
			}
		}
		index = html.index(after: index)
	}
	return nil
}

/// 取出内联的签名脚本（包含 ub98484234 的那段）。
private func douyuSignScript(in html: String) -> String? {
	guard let regex = try? NSRegularExpression(pattern: "<script\\b[^>]*>([\\s\\S]*?)</script>") else {
		return nil
	}
	let range = NSRange(html.startIndex..., in: html)
	for match in regex.matches(in: html, range: range) {
		guard match.numberOfRanges > 1,
			  let found = Range(match.range(at: 1), in: html) else { continue }
		let body = String(html[found])
		if body.contains("ub98484234") {
			return body
		}
	}
	return nil
}

/// 把 JS 字符串字面量的内容还原（处理 \uXXXX、\/ 等转义）。
private func douyuUnescape(_ raw: String) -> String {
	guard raw.contains("\\"),
		  let data = "\"\(raw)\"".data(using: .utf8),
		  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else {
		return raw
	}
	return value
}

private func douyuStringField(_ key: String, in block: String) -> String {
	guard let raw = douyuMatch("\"\(key)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"", in: block) else {
		return ""
	}
	return douyuUnescape(raw)
}

/// thumb_video 的键并不稳定（normal/high/super/1080p60/…），展示与排序都不能依赖它。
private func douyuQualityKey(_ quality: DouyuReplayQuality, used: inout Set<String>) -> String {
	var base = quality.name.isEmpty ? quality.streamType : quality.name
	if used.contains(base) {
		let suffix = quality.streamFormat.isEmpty
			? quality.streamType
			: "\(quality.streamType) \(quality.streamFormat)"
		base = suffix.isEmpty ? base : "\(base) (\(suffix))"
	}
	var candidate = base
	var index = 2
	while used.contains(candidate) {
		candidate = "\(base) #\(index)"
		index += 1
	}
	used.insert(candidate)
	return candidate
}

/// 把 m3u8 里的相对地址补成绝对地址（分片行、以及 URI="…" 属性）。
private func douyuAbsolutizePlaylist(_ body: String, url: String) -> String {
	guard let comps = URLComponents(string: url),
		  let scheme = comps.scheme,
		  let host = comps.host else {
		return body
	}
	var pathParts = comps.path.split(separator: "/").map(String.init)
	pathParts.removeLast()
	let port = comps.port.map { ":\($0)" } ?? ""
	let prefix = "\(scheme)://\(host)\(port)" + (pathParts.isEmpty ? "" : "/" + pathParts.joined(separator: "/"))

	func absolute(_ value: String) -> String {
		let trimmed = value.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty,
			  !trimmed.hasPrefix("http://"),
			  !trimmed.hasPrefix("https://"),
			  !trimmed.hasPrefix("data:") else {
			return value
		}
		return prefix + "/" + trimmed
	}

	let uriRegex = try? NSRegularExpression(pattern: #"URI="([^"]+)""#)
	var lines: [String] = []
	for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
		let text = String(line)
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		if trimmed.isEmpty {
			lines.append(text)
		} else if trimmed.hasPrefix("#") {
			guard let uriRegex else {
				lines.append(text)
				continue
			}
			let range = NSRange(text.startIndex..., in: text)
			let matches = uriRegex.matches(in: text, range: range).reversed()
			var replaced = text
			for match in matches {
				guard match.numberOfRanges > 1,
					  let full = Range(match.range(at: 0), in: replaced),
					  let value = Range(match.range(at: 1), in: replaced) else { continue }
				let target = absolute(String(replaced[value]))
				replaced.replaceSubrange(full, with: "URI=\"\(target)\"")
			}
			lines.append(replaced)
		} else {
			lines.append(absolute(text))
		}
	}
	return lines.joined(separator: "\n")
}

// MARK: - 回放接口

extension Douyu {
	// MARK: 作者 ID

	func vodUpID(_ rid: String) async throws -> String {
		guard let id = Int(rid) else { throw VideoGetError.douyuNotFoundRoomId }
		let info = try await douyuBetard(id)
		guard !info.upID.isEmpty else {
			Log("Douyu replay: no up_id for room \(rid).")
			throw VideoGetError.douyuReplayEmpty
		}
		return info.upID
	}

	// MARK: 场次列表

	func replaySessions(roomId: String, page: Int = 1) async throws -> [DouyuReplaySession] {
		let upID = try await vodUpID(roomId)
		return try await replaySessions(upID: upID, page: page)
	}

	func replaySessions(upID: String, page: Int = 1) async throws -> [DouyuReplaySession] {
		let data = try await AF.request(vodListEndpoint,
										parameters: ["up_id": upID,
													 "page": page,
													 "limit": vodListLimit])
			.serializingData().value
		let json = try JSONParser.JSONObjectWithData(data)
		let error = douyuInt(json["error"])
		guard error == 0 else {
			Log("Douyu replay list error \(error): \(douyuText(json["msg"]))")
			throw VideoGetError.douyuReplayFailed("list error \(error)")
		}
		let list = (json["data"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
		guard !list.isEmpty else { throw VideoGetError.douyuReplayEmpty }

		return list.compactMap { show -> DouyuReplaySession? in
			// 每场只带第 1 个分P；分P 总数看 re_num。
			let videos = show["video_list"] as? [[String: Any]] ?? []
			guard let first = videos.first else { return nil }
			let hashId = douyuText(first["hash_id"])
			guard !hashId.isEmpty else { return nil }

			let showTitle = douyuText(show["title"])
			return DouyuReplaySession(
				hashId: hashId,
				title: showTitle.isEmpty ? douyuText(first["title"]) : showTitle,
				cover: douyuText(first["video_pic"]),
				durationStr: douyuText(show["replay_duration"]),
				durationSecs: douyuDurationSeconds(show["replay_duration"]),
				recordedAt: douyuInt(first["start_time"]),
				partCount: max(douyuInt(show["re_num"]), 1),
				showId: douyuInt(show["show_id"]),
				upID: upID,
				viewText: douyuText(first["view_num"]),
				timeFormat: douyuText(show["time_format"]))
		}
	}

	// MARK: 分P

	func replayParts(hashId: String, upId: String) async throws -> [DouyuReplayPart] {
		let data = try await AF.request(vodPartsEndpoint,
										parameters: ["vid": hashId, "up_id": upId])
			.serializingData().value
		let json = try JSONParser.JSONObjectWithData(data)
		let error = douyuInt(json["error"])
		guard error == 0 else {
			Log("Douyu replay parts error \(error): \(douyuText(json["msg"]))")
			throw VideoGetError.douyuReplayFailed("parts error \(error)")
		}
		let list = (json["data"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
		guard !list.isEmpty else { throw VideoGetError.douyuReplayEmpty }

		return list.enumerated().compactMap { offset, part -> DouyuReplayPart? in
			let partHash = douyuText(part["hash_id"])
			guard !partHash.isEmpty else { return nil }
			let durationStr = douyuText(part["video_duration"])
			return DouyuReplayPart(
				hashId: partHash,
				title: douyuText(part["title"]),
				remark: douyuText(part["show_remark"]),
				durationStr: durationStr,
				durationSecs: douyuDurationSeconds(durationStr),
				partNum: max(douyuInt(part["rank"]), offset + 1),
				showId: douyuInt(part["show_id"]),
				cover: douyuText(part["cover"]),
				viewText: douyuText(part["view_num"]))
		}
	}

	// MARK: 播放页

	/// 播放页（point_id / vid / 签名脚本 / 标题封面）带 30 分钟缓存；
	/// 连播时每个分P都要现签，不开缓存会重复抓页面。
	func vodPage(_ hashId: String, refresh: Bool = false) async throws -> DouyuVodPage {
		if !refresh, let entry = vodPageCache[hashId], Date().timeIntervalSince(entry.date) < 1800 {
			return entry.page
		}
		let data = try await AF.request(vodShowEndpoint + hashId).serializingData().value
		let html = String(data: data, encoding: .utf8) ?? ""
		let page = try DouyuVodPage(hashId: hashId, html: html)
		vodPageCache[hashId] = (page, Date())
		return page
	}

	// MARK: 清晰度

	/// 返回该分P的全部清晰度，逐档原样、不做裁剪与合并，按 level 降序。
	func replayQualities(hashId: String, refresh: Bool = false) async throws -> [DouyuReplayQuality] {
		let page = try await vodPage(hashId, refresh: refresh)
		let ts = Int(Date().timeIntervalSince1970)
		guard let params = DouyuVodSigner.sign(pointID: page.pointID,
											  script: page.signScript,
											  did: vodDID,
											  ts: ts) else {
			throw VideoGetError.douyuSignError
		}
		var body = [String: String]()
		for pair in params.split(separator: "&") {
			let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
			if kv.count == 2 {
				body[kv[0]] = kv[1]
			}
		}
		body["vid"] = page.vid

		let data = try await AF.request(vodStreamEndpoint,
										method: .post,
										parameters: body,
										encoding: URLEncoding.httpBody)
			.serializingData().value
		let json = try JSONParser.JSONObjectWithData(data)
		let error = douyuInt(json["error"])
		guard error == 0 else {
			// 签名过期 / 页面改版时，刷新播放页重试一次。
			if !refresh {
				return try await replayQualities(hashId: hashId, refresh: true)
			}
			Log("Douyu replay stream error \(error): \(douyuText(json["msg"]))")
			throw VideoGetError.douyuReplayFailed("stream error \(error)")
		}
		guard let thumb = (json["data"] as? [String: Any])?["thumb_video"] as? [String: Any] else {
			throw VideoGetError.douyuReplayFailed("thumb_video missing")
		}

		let qualities = thumb.compactMap { key, value -> DouyuReplayQuality? in
			guard let entry = value as? [String: Any] else { return nil }
			let url = douyuText(entry["url"])
			guard !url.isEmpty else { return nil }
			let name = douyuText(entry["name"])
			let streamType = douyuText(entry["stream_type"])
			return DouyuReplayQuality(
				name: name.isEmpty ? key : name,
				streamType: streamType.isEmpty ? key : streamType,
				streamFormat: douyuText(entry["stream_format"]),
				level: douyuInt(entry["level"]),
				bitRate: douyuInt(entry["bit_rate"]),
				fileSize: douyuInt64(entry["fsize"]),
				nowFree: douyuInt(entry["now_free"]),
				url: url)
		}
		guard !qualities.isEmpty else { throw VideoGetError.notFountData }

		return qualities.sorted {
			$0.level == $1.level ? $0.streamType < $1.streamType : $0.level > $1.level
		}
	}

	/// 只取某一档的播放地址（本地路由现签用）。
	/// 缺档时回退到最接近的较低档，再退到可用最高档。
	func replayStreamURL(hashId: String, level: Int) async throws -> String {
		let qualities = try await replayQualities(hashId: hashId)
		let picked = qualities.first { $0.level == level }
			?? qualities.first { $0.level < level }
			?? qualities.first
		guard let picked else { throw VideoGetError.notFountData }
		if picked.level != level {
			Log("Douyu replay: level \(level) unavailable for \(hashId), fallback to \(picked.level).")
		}
		return picked.url
	}

	/// 现签某一档的 m3u8 内容，并把其中的相对分片地址补成绝对地址，
	/// 让播放器直接从 CDN 拉分片、但媒体地址仍然是我们这条稳定地址。
	///
	/// 接口返回的是 http 地址，这里统一升级成 https：App 自身受 ATS 限制抓不了明文 http，
	/// 而该 CDN 的 https 与 http 等价。
	func replayPlaylist(hashId: String, level: Int) async throws -> String {
		let url = try await replayStreamURL(hashId: hashId, level: level).https()
		let body = try await AF.request(url).serializingString().value
		return douyuAbsolutizePlaylist(body, url: url)
	}

	// MARK: 解码

	func vodInfo(_ url: String) async throws -> DouyuVodInfo {
		guard let hashId = DouyuReplayURL.hashId(from: url) else { throw VideoGetError.invalidLink }
		let page = try await vodPage(hashId)
		var info = DouyuVodInfo()
		info.title = page.title
		info.name = page.author
		// 直播类站点的封面取 avatar。
		info.avatar = page.cover
		info.cover = page.cover
		return info
	}

	func decodeVodUrl(_ url: String) async throws -> YouGetJSON {
		guard let hashId = DouyuReplayURL.hashId(from: url) else { throw VideoGetError.invalidLink }
		let page = try await vodPage(hashId)
		let qualities = try await replayQualities(hashId: hashId)

		// 找到当前分P在本场里的位置，用于连播后续分P；失败就只播这一段。
		let parts = try? await replayParts(hashId: hashId, upId: page.upID)
		let partNum = parts?.first { $0.hashId == hashId }?.partNum ?? 0
		if let duration = parts?.first(where: { $0.hashId == hashId })?.durationSecs, duration > 0 {
			await ReplayProgressStore.shared.setDuration(hashId, Double(duration))
		}

		var json = YouGetJSON(rawUrl: url)
		json.site = .douyuVod
		json.title = page.title.isEmpty ? hashId : page.title
		json.id = Int(page.pointID) ?? -1
		json.duration = page.duration

		var used = Set<String>()
		for (index, quality) in qualities.enumerated() {
			let key = douyuQualityKey(quality, used: &used)
			let stream = Stream(url: DouyuReplayURL.playlist(hashId: hashId,
															upID: page.upID,
															level: quality.level,
															partNum: partNum),
								quality: quality.level,
								qualityIndex: index)
			json.streams[key] = stream
		}
		guard !json.streams.isEmpty else { throw VideoGetError.notFountData }
		Log("Douyu replay \(hashId): \(json.streams.count) qualities, part \(partNum).")
		return json
	}
}

// MARK: - 播放页解析

extension DouyuVodPage {
	init(hashId: String, html: String) throws {
		guard let pointID = douyuMatch("\"point_id\"\\s*:\\s*(\\d+)", in: html),
			  let signScript = douyuSignScript(in: html) else {
			Log("Douyu replay: \(hashId) is not a playable replay page.")
			throw VideoGetError.notFountData
		}
		let block = douyuRoomBlock(in: html) ?? html

		self.hashId = hashId
		self.pointID = pointID
		self.signScript = signScript
		vid = douyuMatch("ROOM\\s*:\\s*\\{\\s*\"vid\"\\s*:\\s*\"([^\"]+)\"", in: html) ?? hashId
		title = douyuStringField("name", in: block)
		cover = douyuStringField("pic", in: block)
		author = douyuStringField("author_name", in: block)
		upID = douyuStringField("up_id", in: block)
		duration = Int(Double(douyuMatch("\"duration\"\\s*:\\s*([\\d.]+)", in: block) ?? "") ?? 0)
	}
}
