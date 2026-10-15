import Foundation
import SQLite3

/// opencode（v1.18+）把每个 assistant 回合的用量写进自己的 SQLite 库，国产模型（deepseek / glm / kimi …）
/// 也在这里，所以这是把它们算进统计的唯一来源。
///
/// 读法：只读打开、一次读全部 assistant 行、整表重建。不做增量游标 —— 实测 message 表的活数据只有
/// 十几 MB，全量重读比「游标 + 重叠窗口」更便宜；而且 message 行是流式写入的，`time_updated` 可以比
/// `time_created` 晚好几个小时才定稿，任何固定的重叠窗口都会漏掉最后的 token 值。
enum OpenCodeUsage {
    /// 一行 assistant 用量。字段名对齐 opencode 的 data JSON。
    struct Row: Equatable {
        var id: String
        var session: String?
        var provider: String
        var model: String
        /// time_created，毫秒 → 秒
        var createdAt: TimeInterval
        var input: Int64
        var output: Int64
        var reasoning: Int64
        var cacheRead: Int64
        var cacheWrite: Int64
    }

    /// 口径与 Claude / Codex 一致：ctx 是「全部输入」（新鲜 + 缓存读 + 缓存写），out 含思考。
    /// opencode 的 total = input + output + reasoning + cache.read + cache.write，
    /// 映射后 tokenTotal = ctx + out 正好等于它。
    static func totals(_ row: Row) -> UsageHistory.ModelTotals {
        UsageHistory.ModelTotals(
            ctx: row.input + row.cacheRead + row.cacheWrite,
            cacheRead: row.cacheRead,
            cacheWrite: row.cacheWrite,
            out: row.output + row.reasoning,
            think: row.reasoning)
    }

    /// 纯函数：把行映射成记录表，键 = 消息 id（重复读不会重复计数）。
    static func records(rows: [Row], source: String = "OpenCode") -> [String: UsageHistory.Record] {
        var out: [String: UsageHistory.Record] = [:]
        for row in rows where !row.id.isEmpty {
            out[row.id] = UsageHistory.Record(
                id: row.id,
                source: source,
                timestamp: row.createdAt,
                model: row.model.isEmpty ? "?" : row.model,
                usage: totals(row),
                session: row.session)
        }
        return out
    }

    /// `$XDG_DATA_HOME/opencode/opencode.db`，否则 `~/.local/share/opencode/opencode.db`。
    static func databasePath(home: String) -> String {
        let xdg = (ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? "").trimmingCharacters(in: .whitespaces)
        return xdg.isEmpty ? "\(home)/.local/share/opencode/opencode.db" : "\(xdg)/opencode/opencode.db"
    }

    /// 只读打开并整表读一遍。读失败返回 nil（调用方保留上次快照，绝不拿空表覆盖）；
    /// 库不存在或没有 assistant 行则返回空表。
    static func read(dbPath: String) -> [String: UsageHistory.Record]? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [:] }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(db) }
        // WAL 模式下读不挡写、写不挡读；偶发的 SQLITE_BUSY 交给 busy_timeout 重试，仍失败就下轮再来。
        sqlite3_busy_timeout(db, 4000)
        let sql = """
        SELECT id, time_created, session_id,
               json_extract(data,'$.modelID'), json_extract(data,'$.providerID'),
               json_extract(data,'$.tokens.input'), json_extract(data,'$.tokens.output'),
               json_extract(data,'$.tokens.reasoning'), json_extract(data,'$.tokens.cache.read'),
               json_extract(data,'$.tokens.cache.write')
        FROM message
        WHERE json_extract(data,'$.role')='assistant' AND json_extract(data,'$.tokens') IS NOT NULL
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else { return nil }
        defer { sqlite3_finalize(prepared) }
        var rows: [Row] = []
        var step = sqlite3_step(prepared)
        while step == SQLITE_ROW {
            autoreleasepool {
                guard let idText = sqlite3_column_text(prepared, 0) else { return }
                func text(_ index: Int32) -> String? {
                    guard let raw = sqlite3_column_text(prepared, index) else { return nil }
                    return String(cString: raw)
                }
                func count(_ index: Int32) -> Int64 { max(0, sqlite3_column_int64(prepared, index)) }
                rows.append(Row(
                    id: String(cString: idText),
                    session: text(2),
                    provider: text(4) ?? "",
                    model: text(3) ?? "",
                    createdAt: Double(sqlite3_column_int64(prepared, 1)) / 1000.0,
                    input: count(5), output: count(6), reasoning: count(7),
                    cacheRead: count(8), cacheWrite: count(9)))
            }
            step = sqlite3_step(prepared)
        }
        // 中途报错就别拿半份数据去覆盖，保留上次快照。
        guard step == SQLITE_DONE else { return nil }
        return records(rows: rows)
    }
}
