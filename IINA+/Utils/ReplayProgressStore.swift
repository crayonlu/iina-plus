//
//  ReplayProgressStore.swift
//  IINA+
//
//  回放播放进度：落盘在 UserDefaults，位置从播放器的 watch_later 回读。
//
//  播放器把进度记在 watch_later/<MD5(交给它的 URL) 大写>，内容形如 `start=121.146667`。
//  回放的分P地址是稳定的本地地址，因此这个键对同一分P、同一档清晰度始终一致。
//

import Foundation
import CryptoSwift

actor ReplayProgressStore {
	static let shared = ReplayProgressStore()

	struct Progress: Codable, Sendable {
		var position: Double = 0
		var duration: Double = 0
		var updatedAt: Double = 0
		var completed: Bool = false
		/// 上一次交给播放器的地址，用于回读 watch_later
		var url: String = ""
	}

	private let defaultsKey = "douyuReplayProgress"
	private var items: [String: Progress]

	private init() {
		if let data = UserDefaults.standard.data(forKey: defaultsKey),
		   let decoded = try? JSONDecoder().decode([String: Progress].self, from: data) {
			items = decoded
		} else {
			items = [:]
		}
	}

	// MARK: - 读写

	func setDuration(_ id: String, _ duration: Double) {
		guard duration > 0 else { return }
		var entry = items[id] ?? Progress()
		entry.duration = duration
		items[id] = entry
		save()
	}

	/// 用已记录的播放地址回读播放器写的进度。
	@discardableResult
	func refresh(id: String) -> Progress? {
		guard var entry = items[id] else { return nil }
		guard !entry.url.isEmpty,
			  let position = Self.watchLaterPosition(for: entry.url) else {
			return entry
		}
		if entry.position != position {
			entry.position = position
			entry.updatedAt = Date().timeIntervalSince1970
			if entry.duration > 0 {
				entry.completed = position >= entry.duration - 15
			}
			items[id] = entry
			save()
		}
		return entry
	}

	/// 打开某个分P前调用：先按旧地址回读位置，再记录本次的播放地址。
	/// 返回可直接拼进 mpvOptions 的续播参数。
	///
	/// 续播本身交给播放器：watch_later 是按条目地址记账的，mpv/IINA 会自己按条目恢复，
	/// 连播到下一分P时也能各自恢复。这里只做两件事：保证这次的位置会被写下来，
	/// 以及把「已看完」的分P恢复到从头播（清掉它那条片尾位置）。
	///
	/// 不传 `start=`：命令行参数会作用于播放列表里的每一个条目，
	/// 拿它给首条目续播会把后面的分P一起带到同一个位置。
	func beginPlayback(id: String, url: String) -> [String] {
		let previous = refresh(id: id)
		var entry = items[id] ?? Progress()
		entry.url = url
		entry.updatedAt = Date().timeIntervalSince1970
		if let previous {
			entry.duration = max(entry.duration, previous.duration)
			if previous.completed {
				Self.removeWatchLater(for: url)
				entry.position = 0
			}
			entry.completed = false
		}
		items[id] = entry
		save()
		return ["save-position-on-quit=yes"]
	}

	private func save() {
		guard let data = try? JSONEncoder().encode(items) else { return }
		UserDefaults.standard.set(data, forKey: defaultsKey)
	}

	// MARK: - watch_later

	/// IINA 与 mpv 的 watch_later 目录；找不到就当没有进度。
	static func watchLaterDirectories() -> [URL] {
		var dirs: [URL] = []
		if let base = try? FileManager.default.url(for: .applicationSupportDirectory,
												   in: .userDomainMask,
												   appropriateFor: nil,
												   create: false) {
			dirs.append(base.appendingPathComponent("com.colliderli.iina/watch_later", isDirectory: true))
		}
		if let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !config.isEmpty {
			dirs.append(URL(fileURLWithPath: config).appendingPathComponent("mpv/watch_later", isDirectory: true))
		}
		dirs.append(FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(".config/mpv/watch_later", isDirectory: true))
		return dirs
	}

	static func watchLaterPosition(for url: String) -> Double? {
		let name = url.md5().uppercased()
		for dir in watchLaterDirectories() {
			let file = dir.appendingPathComponent(name)
			guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
			for line in content.split(separator: "\n") where line.hasPrefix("start=") {
				return Double(line.dropFirst("start=".count))
			}
		}
		return nil
	}

	/// 清掉某条地址的播放器进度（「已看完」的分P重播时用）。
	static func removeWatchLater(for url: String) {
		let name = url.md5().uppercased()
		for dir in watchLaterDirectories() {
			let file = dir.appendingPathComponent(name)
			guard FileManager.default.fileExists(atPath: file.path) else { continue }
			try? FileManager.default.removeItem(at: file)
		}
	}
}
