//
//  CacheStore.swift
//  Orange Cloud
//
//  iOS 16 基线适配：本文件取代了原 `CacheContainer.swift`（SwiftData ModelContainer 容器）
//  与 `SafeCache.swift`（CoreData 的 ObjC @try 垫片）。
//
//  为什么不再需要 SafeCache 那一层：
//  原 SafeCache 用 ObjC `@try` 兜 CoreData 抛出的 NSException（iOS 17.0 某些设备上
//  fetch 会越过 Swift 的 try? 直接崩，见原注释里的 Sentry APPLE-IOS-1 / TF 崩溃点）。
//  换成 JSON 编解码后，失败模式退化为普通 Swift 错误（解码失败 / 文件损坏），
//  `try?` 接得住，**NSException 这一整类崩溃在设计上不复存在**，故该垫片退休。
//
//  缓存是「随时可按账号从 API 重拉」的非关键数据，任何读写失败都只降级为「无缓存」，
//  绝不允许把 App 启动拖崩——这是从原 CacheContainer 延续下来的核心约束。
//

import Foundation

// MARK: - JSON 文件持久化

/// 泛型 JSON 文件存储：负责「读整个数组 → 解码 / 编码 → 原子写回」。
///
/// 泛型本身只做**落盘**，不含任何 SwiftUI / 观察语义 —— 观察与账号分区由
/// `ZoneCache` / `WorkerCache` / `DNSCache` 各自承担（它们需要表达
/// 「按当前账号过滤 + 排序」这两个 SwiftData `@Query` 谓词所提供的语义）。
nonisolated enum CacheStore {

    /// 缓存目录。放 Application Support（不随 iCloud 备份走的系统建议目录不合适，
    /// 这里跟随既有行为放在 Documents/OrangeCloudCache，便于用户重装时一并清理）。
    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OrangeCloudCache", isDirectory: true)
    }

    nonisolated static func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).json")
    }

    /// 读取并解码。文件不存在 / 解码失败均返回 nil（调用方按「无缓存」处理）。
    nonisolated static func load<T: Decodable>(_ type: T.Type, from name: String) -> [T] {
        let url = fileURL(name)
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder.ocDecoder.decode([T].self, from: data)
        } catch {
            // 文件损坏（可能被外部中断写坏，或旧版本残留格式）：删掉它让下次重新拉取，
            // 不让一个坏文件在之后每次启动都失败一遍。
            AppLog.app.error("缓存 \(name).json 解码失败，已丢弃重建：\(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
            return []
        }
    }

    /// 原子写回。先写临时文件再替换，避免写一半掉电导致文件截断。
    nonisolated static func save<T: Encodable>(_ items: [T], to name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder.ocEncoder.encode(items)
            let tmp = fileURL(name).appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            // replaceItemAt 需要目标已存在；不存在时直接移动更稳。
            if FileManager.default.fileExists(atPath: fileURL(name).path) {
                _ = try FileManager.default.replaceItemAt(fileURL(name), withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL(name))
            }
        } catch {
            // 落盘失败（磁盘满 / 权限）不影响本次会话的内存数据，静默放弃即可。
            AppLog.app.error("缓存 \(name).json 写入失败：\(error.localizedDescription)")
        }
    }

    /// 清空全部缓存文件（供「退出登录」或旧版清库标记沿用）。
    nonisolated static func destroyAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 消费旧版本（≤2.1.0 SwiftData 期）遗留的清库标记。
    /// SwiftData 的 store 文件由系统按 `.store` 命名放在别处，这里直接删掉整个缓存目录即可，
    /// 顺带保证从旧版升级上来的用户不会读到 SwiftData 残留。
    nonisolated static func consumeLegacyRebuildFlagIfNeeded() {
        let key = "ocCacheStoreNeedsRebuild"
        guard UserDefaults.standard.bool(forKey: key) else { return }
        AppLog.app.notice("消费旧版清库标记，启动前清空缓存目录")
        destroyAll()
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: "ocCacheFetchExceptionCount")
    }
}

// MARK: - 编解码器

extension JSONEncoder {
    /// 统一编码器：`updatedAt` 用绝对时间戳（跨启动可读），不排序键（体积更小）。
    nonisolated static var ocEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    nonisolated static var ocDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - Store 名称

/// 三个缓存的落盘文件名。集中在此，避免拼写漂移。
nonisolated enum CacheStoreName {
    static let zones = "zones"
    static let workers = "workers"
    static let dns = "dns"
}
