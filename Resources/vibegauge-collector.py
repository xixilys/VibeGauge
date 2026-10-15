#!/usr/bin/env python3
# VibeGauge 远程采集器：在远端主机上只读 opencode 的 SQLite，把每条 assistant 消息的 token
# 用量按 JSON Lines 打到 stdout，最后一行固定为哨兵。仅用标准库，兼容 Python 3.6+。
# 用法：python3 vibegauge-collector.py [--db PATH] [--since MS]
#       python3 vibegauge-collector.py --summary                 # 今日各 CLI 用量汇总（单行 JSON）
#       python3 vibegauge-collector.py --records --since MS [--gz] # Claude / Codex 逐条请求用量（WSL / Linux 远程日统计）
#       python3 vibegauge-collector.py --selftest
#       cat vibegauge-collector.py | python3 - [--db PATH] [--since MS | --summary]
import argparse, json, os, sys
import calendar, datetime, re, time
import base64, collections, zlib
import math, shlex, subprocess

try:
    import sqlite3
except ImportError:  # 模块缺失时也要给出失败哨兵
    sqlite3 = None

# 只取 assistant 且带 tokens 的行；字段用 json_extract 在 SQL 里取，便于筛选
_FIELDS = (("model", "$.modelID"), ("provider", "$.providerID"), ("inp", "$.tokens.input"),
           ("outp", "$.tokens.output"), ("reasoning", "$.tokens.reasoning"),
           ("cache_read", "$.tokens.cache.read"), ("cache_write", "$.tokens.cache.write"))
SQL_COLS = ("id, session_id, time_created, time_updated, "
            + ", ".join("json_extract(data,'%s') AS %s" % (p, n) for n, p in _FIELDS) + ", data AS raw")
WHERE = "json_extract(data,'$.role')='assistant' AND json_extract(data,'$.tokens') IS NOT NULL"

def resolve_db(explicit):
    # 默认：$XDG_DATA_HOME/opencode/opencode.db，否则 ~/.local/share/opencode/opencode.db
    base = explicit if explicit else os.environ.get("XDG_DATA_HOME")
    return os.path.join(base if base else os.path.expanduser("~/.local/share"), "opencode", "opencode.db")

def to_num(v):
    # 缺失/null/非法 → 0；负数一律归 0
    try:
        n = int(v)
    except (TypeError, ValueError):
        return 0
    return n if n > 0 else 0

def to_str(v):
    return v if isinstance(v, str) else ""

def emit_fail(reason):
    # 失败哨兵只写 stdout，其余诊断走 stderr
    sys.stdout.write(json.dumps({"__ok__": False, "error": reason[:200]}, separators=(",", ":")) + "\n")
    sys.stderr.write("vibegauge-collector: %s\n" % reason)
    sys.stdout.flush()

def run(db_path, since):
    if sqlite3 is None:
        emit_fail("python sqlite3 module unavailable")
        return 1
    if not os.path.exists(db_path):
        emit_fail("db not found: %s" % db_path)
        return 1
    conn = None
    try:
        # 只读打开 + busy_timeout，绝不写库
        conn = sqlite3.connect("file:" + db_path + "?mode=ro", uri=True)
        conn.execute("PRAGMA busy_timeout=4000")
        conn.execute("PRAGMA query_only=1")
        cur = conn.cursor()
        sql = "SELECT " + SQL_COLS + " FROM message WHERE " + WHERE
        params = ()
        if since and since > 0:
            sql += " AND time_updated > ? ORDER BY time_updated"
            params = (since,)
        cur.execute(sql, params)
        out = sys.stdout
        count = 0
        max_u = 0
        for row in cur:
            # 防御：data 解析失败就静默跳过，绝不崩溃、绝不输出
            try:
                json.loads(row[11])
            except (TypeError, ValueError):
                continue
            u = to_num(row[3])
            rec = {"id": to_str(row[0]), "t": to_num(row[2]) // 1000, "u": u, "s": to_str(row[1]),
                   "m": to_str(row[4]), "p": to_str(row[5]), "in": to_num(row[6]), "out": to_num(row[7]),
                   "r": to_num(row[8]), "cr": to_num(row[9]), "cw": to_num(row[10])}
            out.write(json.dumps(rec, separators=(",", ":")) + "\n")
            count += 1
            if u > max_u:
                max_u = u
        out.write(json.dumps({"__ok__": True, "count": count, "max_u": max_u}, separators=(",", ":")) + "\n")
        out.flush()
        return 0
    except Exception as exc:  # 任何查询/连接错误都转成失败哨兵
        emit_fail("%s: %s" % (type(exc).__name__, exc))
        return 1
    finally:
        if conn is not None:
            conn.close()

# ---- 汇总模式：今日各 CLI 用量（只读；单代理失败即省略该键）----
_ISO_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|z|[+-]\d{2}:?\d{2})?")

def _today_start_ms():
    # 远端本地日历日 0 点（毫秒），与 sqlite date('now','localtime') 对齐
    lt = time.localtime()
    return int(time.mktime(tuple(lt[:3]) + (0, 0, 0, 0, 0, -1))) * 1000

def _iso_epoch(s):
    # ISO8601 → UTC epoch；小数秒忽略，Z / ±HH:MM 都支持，坏值返回 None
    m = _ISO_RE.match(s.strip()) if isinstance(s, str) else None
    if not m:
        return None
    y, mo, d, h, mi, sec = (int(m.group(i)) for i in range(1, 7))
    dg = (m.group(7) or "Z")[1:].replace(":", "")
    off = 0 if not dg else (-1 if m.group(7)[0] == "-" else 1) * (int(dg[:2]) * 3600 + (int(dg[2:4]) if len(dg) >= 4 else 0) * 60)
    try:
        return calendar.timegm((y, mo, d, h, mi, sec, 0, 0, 0)) - off
    except (ValueError, OverflowError):
        return None

def _files(root, cutoff, suffix=".jsonl"):
    # 遍历 root，产出 (path, 行列表)；mtime < cutoff 或读失败则跳过
    for dp, _d, names in os.walk(root, onerror=lambda _e: None):
        for nm in names:
            p = os.path.join(dp, nm)
            try:
                if not nm.endswith(suffix) or os.path.getmtime(p) < cutoff:
                    continue
                yield p, open(p, encoding="utf-8", errors="replace").read().splitlines()
            except OSError:
                pass

def _collect_opencode(start_ms):
    # opencode：一次 SQL 聚合；口径 = input+cache.read+cache.write / output+reasoning
    if sqlite3 is None:
        return None
    try:
        conn = sqlite3.connect("file:" + resolve_db(None) + "?mode=ro", uri=True)
        conn.execute("PRAGMA busy_timeout=4000"); conn.execute("PRAGMA query_only=1")
        sums = ",".join("COALESCE(SUM(json_extract(data,'$.tokens.%s')),0)" % c
                        for c in ("input", "cache.read", "cache.write", "output", "reasoning"))
        row = conn.execute("SELECT " + sums + ",COUNT(*) FROM message WHERE " + WHERE
                           + " AND time_created >= ?", (start_ms,)).fetchone()
        conn.close()
    except Exception:
        return None
    if not row or to_num(row[5]) <= 0:
        return None
    return {"ctx": to_num(row[0]) + to_num(row[1]) + to_num(row[2]), "cache_read": to_num(row[1]), "cache_write": to_num(row[2]),
            "out": to_num(row[3]) + to_num(row[4]), "think": to_num(row[4]), "requests": to_num(row[5])}

def _read_claude_usage(home):
    # 保持旧 claude_usage 字段，但只返回配额窗口和采集时间，不转发任意用户字段。
    obj = _read_json_bounded(_claude_usage_paths(home), 256 * 1024)
    if not isinstance(obj, dict):
        return None
    out = {}
    captured = _finite_number(obj.get("_captured_at"))
    if captured is not None:
        out["_captured_at"] = captured
    for key, value in obj.items():
        if key == "_captured_at" or not isinstance(value, dict):
            continue
        if key not in ("five_hour", "seven_day") and not key.startswith(("five_hour_", "seven_day_")):
            continue
        used = _pct(value.get("used_percentage"))
        if used is None:
            continue
        win = {"used_percentage": used}
        reset = _finite_number(value.get("resets_at"))
        if reset is not None:
            win["resets_at"] = reset
        out[key] = win
    return out

def _finite_number(value):
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
        return number if math.isfinite(number) else None
    except (TypeError, ValueError, OverflowError):
        return None

def _pct(value):
    number = _finite_number(value)
    return max(0.0, min(100.0, number)) if number is not None else None

def _claude_usage_paths(home):
    paths = []
    config = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    if config:
        paths.append(os.path.join(os.path.expanduser(config), "claude-usage.json"))
    paths.extend((os.path.join(home, ".claude", "claude-usage.json"),
                  os.path.join(home, ".config", "claude", "claude-usage.json")))
    return paths

def _read_json_bounded(paths, max_bytes):
    for path in paths:
        try:
            with open(path, "rb") as fh:
                raw = fh.read(max_bytes + 1)
            if len(raw) > max_bytes:
                continue
            value = json.loads(raw.decode("utf-8", "replace"))
            if isinstance(value, dict):
                return value
        except (OSError, ValueError, UnicodeError):
            continue
    return None

def _window(used, resets_at=None, captured_at=None, seconds=None):
    pct = _pct(used)
    if pct is None:
        return None
    result = {"used_percentage": pct}
    if resets_at is not None:
        result["resets_at"] = resets_at
    if captured_at is not None:
        result["captured_at"] = captured_at
    if seconds is not None and _finite_number(seconds) is not None:
        result["window_seconds"] = max(0.0, float(seconds))
    return result

def _codex_rate_limits(value, depth=0):
    if depth > 8 or not isinstance(value, dict):
        return None
    if "primary" in value or "secondary" in value:
        return value
    for child in value.values():
        found = _codex_rate_limits(child, depth + 1)
        if found is not None:
            return found
    return None

def _codex_recent_files(home, now):
    base = os.environ.get("CODEX_HOME") or os.path.join(home, ".codex")
    found = []
    # Date-addressed directories keep traversal bounded to the last eight local days.
    lt = time.localtime(now)
    today = datetime.date(lt.tm_year, lt.tm_mon, lt.tm_mday)
    for back in range(8):
        day = (today - datetime.timedelta(days=back)).strftime("%Y/%m/%d")
        for sub in ("sessions", "archived_sessions"):
            directory = os.path.join(base, sub, day)
            try:
                names = os.listdir(directory)
            except OSError:
                continue
            for name in names:
                if not name.endswith(".jsonl"):
                    continue
                path = os.path.join(directory, name)
                try:
                    mt = os.path.getmtime(path)
                    if now - mt <= 8 * 86400:
                        found.append((mt, path))
                except OSError:
                    pass
    return [p for _mt, p in sorted(found, reverse=True)[:48]]

def _read_tail(path, max_bytes):
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - max_bytes))
            data = fh.read(max_bytes)
        if size > max_bytes:
            data = data[data.find(b"\n") + 1:] if b"\n" in data else b""
        return data.decode("utf-8", "replace").splitlines()
    except OSError:
        return []

def _codex_quotas(home, now):
    best, plan, best_captured = None, "", -1
    for path in _codex_recent_files(home, now):
        for line in _read_tail(path, 256 * 1024):
            if "used_percent" not in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            limits = _codex_rate_limits(row)
            if limits is None:
                continue
            # Spark and other named buckets are separate limits. Only the main Codex
            # bucket belongs in this platform row; old logs omitted limit_id entirely.
            if "limit_id" in limits and limits.get("limit_id") != "codex":
                continue
            captured = _iso_epoch(row.get("timestamp")) or _finite_number(row.get("timestamp"))
            if captured is None:
                captured = os.path.getmtime(path)
            if captured <= best_captured:
                continue
            bucket, priority = {}, {}
            for field in ("primary", "secondary"):
                window = limits.get(field)
                if not isinstance(window, dict):
                    continue
                mins = _finite_number(window.get("window_minutes"))
                if mins is None or mins <= 0:
                    continue
                weekly = mins >= 1440
                slot = "seven_day" if weekly else "five_hour"
                seconds = mins * 60
                parsed = _window(window.get("used_percent"), _finite_number(window.get("resets_at")), captured, seconds)
                source_priority = 0 if field == "primary" else 1
                if parsed is not None and source_priority < priority.get(slot, 2):
                    bucket[slot] = parsed
                    priority[slot] = source_priority
            if bucket:
                best, best_captured = bucket, captured
                plan = limits.get("plan_type") if isinstance(limits.get("plan_type"), str) else ""
    if best is None:
        return {}, "", None
    return best, plan, best_captured

def _grok_quota(home):
    path = os.path.join(home, ".grok", "logs", "unified.jsonl")
    tier, best = "", None
    for line in reversed(_read_tail(path, 512 * 1024)):
        if "fetched credits config" not in line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        ctx = row.get("ctx") if isinstance(row.get("ctx"), dict) else {}
        cfg = ctx.get("config") if isinstance(ctx.get("config"), dict) else {}
        used = _pct(cfg.get("creditUsagePercent"))
        if used is None:
            continue
        period = cfg.get("currentPeriod") if isinstance(cfg.get("currentPeriod"), dict) else {}
        start, end = _iso_epoch(period.get("start")), _iso_epoch(period.get("end"))
        captured = _iso_epoch(row.get("ts"))
        best = _window(used, end, captured, max(0, end - start) if start is not None and end is not None else None)
        value = ctx.get("subscriptionTier")
        tier = value if isinstance(value, str) else ""
        break
    return best, tier

def _agy_quotas(home):
    path = os.path.join(home, ".cache", "agy-hud", "quota_cache.json")
    obj = _read_json_bounded([path], 1024 * 1024)
    if not isinstance(obj, dict) or not isinstance(obj.get("pools"), dict):
        return None, None
    pools = obj["pools"]
    captured_default = _finite_number(obj.get("updated_at"))
    def parse(pool_name, field, default_seconds):
        pool = pools.get(pool_name)
        value = pool.get(field) if isinstance(pool, dict) else None
        if not isinstance(value, dict):
            return None
        remaining = _finite_number(value.get("remaining_fraction"))
        if remaining is None:
            return None
        used = max(0.0, min(100.0, (1.0 - remaining) * 100.0))
        seconds = default_seconds
        return _window(used, _finite_number(value.get("reset_at")),
                       _finite_number(value.get("recorded_at")) or captured_default, seconds)
    return {"five_hour": parse("gemini", "5h", 5 * 3600),
            "seven_day": parse("gemini", "weekly", 7 * 86400),
            "secondary_name": "3p",
            "secondary_five_hour": parse("3p", "5h", 5 * 3600),
            "secondary_seven_day": parse("3p", "weekly", 7 * 86400)}, captured_default

def _session_counts():
    names = ("claude", "codex", "grok", "agy")
    result = dict((name, 0) for name in names)
    try:
        proc = subprocess.Popen(["/bin/ps", "-axo", "pid=,ppid=,command="], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
        raw = proc.stdout.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            proc.terminate(); proc.wait(timeout=1)
            return result, False
        proc.stdout.close()
        if proc.wait(timeout=2) != 0:
            return result, False
    except (OSError, subprocess.SubprocessError):
        return result, False
    procs, matched = {}, {}
    for line in raw.decode("utf-8", "replace").splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        procs[pid] = (ppid, parts[2])
        try:
            argv = shlex.split(parts[2])
        except ValueError:
            continue
        if not argv:
            continue
        base = os.path.basename(argv[0]).lower()
        kind = None
        if base == "claude": kind = "claude"
        elif base in ("codex", "codex.js") or ("node" in base and len(argv) > 1 and os.path.basename(argv[1]).lower() in ("codex", "codex.js")): kind = "codex"
        elif base == "grok": kind = "grok"
        elif base == "agy": kind = "agy"
        if kind and ppid != 1 and not any(term in parts[2].lower() for term in ("mcp-server", "grep", "codex-darwin", "/vendor/", "/plugins/cache/", "cua_node", "agy-routed", "agy-batch", "agy-review", "agy-video")):
            matched[pid] = kind
    roots = set()
    for pid, kind in matched.items():
        parent, hops = procs[pid][0], 0
        nested = False
        while parent > 1 and hops < 30:
            if parent in matched:
                nested = True; break
            parent = procs.get(parent, (1, ""))[0]
            hops += 1
        if not nested:
            roots.add((pid, kind))
    for _pid, kind in roots:
        result[kind] += 1
    return result, True

def collect_platform_quotas(home, now=None):
    now = time.time() if now is None else now
    sessions, sessions_ok = _session_counts()
    claude = _read_claude_usage(home) or {}
    claude_capture = _finite_number(claude.get("_captured_at"))
    def claude_window(key, seconds):
        obj = claude.get(key)
        if not isinstance(obj, dict): return None
        return _window(obj.get("used_percentage"), _finite_number(obj.get("resets_at")), claude_capture, seconds)
    extra_name, extra5, extra7 = "", None, None
    for key, obj in claude.items():
        if key in ("five_hour", "seven_day", "_captured_at") or not isinstance(obj, dict): continue
        base_name = key.replace("five_hour_", "").replace("seven_day_", "")
        win = _window(obj.get("used_percentage"), _finite_number(obj.get("resets_at")), claude_capture,
                      5 * 3600 if key.startswith("five_hour") else 7 * 86400)
        if win is None: continue
        if extra_name and extra_name != base_name: continue
        extra_name = base_name
        if key.startswith("five_hour"): extra5 = win
        else: extra7 = win
    claude_quota = {"five_hour": claude_window("five_hour", 5 * 3600), "seven_day": claude_window("seven_day", 7 * 86400),
                    "secondary_name": extra_name, "secondary_five_hour": extra5, "secondary_seven_day": extra7}
    codex_quota, codex_tier, codex_capture = _codex_quotas(home, now)
    grok_window, grok_tier = _grok_quota(home)
    agy_quota, agy_capture = _agy_quotas(home)
    def row(tier="", quota=None, captured=None, note=None):
        result = {"tier": tier or "", "sessions": 0, "quota": quota or {}}
        if captured is not None: result["captured_at"] = captured
        if note: result["note"] = note
        return result
    has_agy_quota = bool(agy_quota and any(agy_quota.get(k) is not None for k in
                         ("five_hour", "seven_day", "secondary_five_hour", "secondary_seven_day")))
    rows = {"claude": row(quota=claude_quota, captured=claude_capture),
            "codex": row(tier=codex_tier, quota=codex_quota, captured=codex_capture),
            "grok": row(tier=grok_tier, quota={"seven_day": grok_window}, captured=grok_window.get("captured_at") if grok_window else None),
            "agy": row(tier="已登录" if has_agy_quota else "", quota=agy_quota or {}, captured=agy_capture)}
    for key in rows:
        rows[key]["sessions"] = sessions[key]
        if not sessions_ok: rows[key]["note"] = "session_count_unavailable"
    return rows

def run_summary():
    # 只打一行 __summary__ + 哨兵；任何异常转失败哨兵，绝不写文件
    try:
        start_ms, home = _today_start_ms(), os.path.expanduser("~")
        recs, _ = collect_records(home, start_ms - 1)
        today = dict((k, v) for k, v in (
            ("opencode", _collect_opencode(start_ms)),
            ("claude", _today_totals([r for r in recs if r["k"] == "claude"], start_ms / 1000.0)),
            ("codex", _today_totals([r for r in recs if r["k"] == "codex"], start_ms / 1000.0)),
        ) if v)
        sys.stdout.write(json.dumps({"__summary__": {"today": today, "claude_usage": _read_claude_usage(home),
                                                       "platforms": collect_platform_quotas(home)}}, separators=(",", ":")) + "\n")
        sys.stdout.write(json.dumps({"__ok__": True, "count": len(today), "max_u": 0}, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        return 0
    except Exception as exc:
        emit_fail("%s: %s" % (type(exc).__name__, exc))
        return 1

def run_quotas():
    # 额度刷新不扫描 Claude/Codex 全量逐条用量文件。
    try:
        platforms = collect_platform_quotas(os.path.expanduser("~"))
        sys.stdout.write(json.dumps({"__summary__": {"platforms": platforms}}, separators=(",", ":")) + "\n")
        sys.stdout.write(json.dumps({"__ok__": True, "count": len(platforms), "max_u": 0}, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        return 0
    except Exception as exc:
        emit_fail("%s: quota collection failed" % type(exc).__name__)
        return 1

# ---- 逐条记录模式：Claude / Codex 的每次请求（给 Mac 端算按天、按模型、按金额）----
# 口径与 Mac 端 UsageHistory 一致：
#   Claude：同一 requestId 取 token 最多的那条；1h 缓存写入单列；speed=fast 记 fast 档；跳过 synthetic / API 错误行
#   Codex：有 token_usage_record 就只认它（response_id 去重）；否则用 token_count 的 last_token_usage（累计没前进不算）
#          sessions/ 与 archived_sessions/ 同名文件只算一次；旧版 fork 开头 1 秒内的重放串只当基线

def _claude_roots(home):
    roots = []
    env = os.environ.get("CLAUDE_CONFIG_DIR", "")
    for item in [x.strip() for x in env.split(",") if x.strip()]:
        roots.append(os.path.join(os.path.expanduser(item), "projects"))
    roots += [os.path.join(home, ".config", "claude", "projects"), os.path.join(home, ".claude", "projects")]
    seen, out = set(), []
    for r in roots:
        if r not in seen and os.path.isdir(r):
            seen.add(r); out.append(r)
    return out

def _codex_files(home):
    base = os.environ.get("CODEX_HOME") or os.path.join(home, ".codex")
    picked = {}
    for sub in ("sessions", "archived_sessions"):     # sessions 优先
        root = os.path.join(base, sub)
        for dp, _d, names in os.walk(root, onerror=lambda _e: None):
            for nm in names:
                if nm.endswith(".jsonl") and nm not in picked:
                    picked[nm] = os.path.join(dp, nm)
    return list(picked.values())

def _claude_files(home):
    out = []
    for root in _claude_roots(home):
        for dp, _d, names in os.walk(root, onerror=lambda _e: None):
            for nm in names:
                if nm.endswith(".jsonl"):
                    out.append(os.path.join(dp, nm))
    return out

def _mtime_ms(p):
    try:
        return int(os.path.getmtime(p) * 1000)
    except OSError:
        return -1

def _read_lines(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as fh:
            return fh.read().splitlines()
    except OSError:
        return []

def _claude_record(o, session):
    # 子代理进度行：完整的 assistant 记录包在 data.message 里
    entry = o
    if (o.get("type") != "assistant" or not isinstance(o.get("message"), dict)) and isinstance(o.get("data"), dict):
        inner = o["data"].get("message")
        if isinstance(inner, dict) and isinstance(inner.get("message"), dict):
            entry = inner
    if entry.get("type", "assistant") != "assistant" or entry.get("isApiErrorMessage"):
        return None
    m = entry.get("message")
    u = m.get("usage") if isinstance(m, dict) else None
    if not isinstance(u, dict):
        return None
    model = m.get("model") or "?"
    if "synthetic" in model:
        return None
    ts = _iso_epoch(entry.get("timestamp"))
    rid = entry.get("requestId") or (m.get("id") if isinstance(m.get("id"), str) else "") or entry.get("uuid") or ""
    if ts is None or not rid:
        return None
    i, r, w = (to_num(u.get(k)) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
    cc = u.get("cache_creation") if isinstance(u.get("cache_creation"), dict) else {}
    rec = {"k": "claude", "id": rid, "t": ts, "m": model, "in": i + r + w, "cr": r, "cw": w,
           "c1": min(w, to_num(cc.get("ephemeral_1h_input_tokens"))), "out": to_num(u.get("output_tokens")), "th": 0, "s": session}
    if str(u.get("speed") or "").lower() == "fast":
        rec["tier"] = "fast"
    return rec

def _codex_usage(d):
    if not isinstance(d, dict) or "input_tokens" not in d or "output_tokens" not in d:
        return None
    inp = to_num(d.get("input_tokens"))
    cr = min(to_num(d.get("cached_input_tokens")), inp)
    cw = min(to_num(d.get("cache_write_input_tokens")), inp - cr)
    return {"in": inp, "cr": cr, "cw": cw, "out": to_num(d.get("output_tokens")), "th": to_num(d.get("reasoning_output_tokens"))}

def _codex_file_records(path):
    name = os.path.basename(path)
    model, tier, prev, has_tur, forked = "?", None, None, False, False
    burst_last, burst_first, burst_done = None, None, False
    recs = collections.OrderedDict()
    for n, line in enumerate(_read_lines(path)):
        if not any(k in line for k in ('"token_count"', '"turn_context"', '"session_meta"', '"token_usage_record"', '"thread_settings_applied"')):
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        p = o.get("payload") if isinstance(o.get("payload"), dict) else {}
        t = o.get("type")
        if t == "session_meta":
            forked = bool(p.get("forked_from_id"))
            if p.get("model"):
                model = p["model"]
        elif t == "turn_context":
            if p.get("model"):
                model = p["model"]
        elif t == "token_usage_record":
            u = _codex_usage(p.get("usage"))
            ts = _iso_epoch(o.get("timestamp"))
            if u is None or ts is None:
                continue
            if not has_tur:
                has_tur = True
                recs = collections.OrderedDict((k, v) for k, v in recs.items() if k.startswith("resp"))
            if u["in"] + u["out"] <= 0:
                continue
            rid = p.get("response_id") or ("resp-%s:%d" % (name, n))
            rec = dict(u, k="codex", id=rid, t=ts, m=model, s=name)
            if tier:
                rec["tier"] = tier
            recs[rid] = rec
        elif t == "event_msg":
            et = p.get("type")
            if et == "thread_settings_applied":
                st = (p.get("thread_settings") or {}).get("service_tier")
                if isinstance(st, str):
                    tier = st.lower()
                continue
            if et != "token_count" or not isinstance(p.get("info"), dict):
                continue
            info = p["info"]
            total = _codex_usage(info.get("total_token_usage"))
            last = _codex_usage(info.get("last_token_usage"))
            old = prev
            if total is not None:
                prev = total
                if total == old:
                    continue
            if last is None:
                if total is None:
                    continue
                last = dict((k, total[k] - (old or {}).get(k, 0)) for k in total)
                if any(v < 0 for v in last.values()):
                    continue
            if has_tur or last["in"] + last["out"] <= 0:
                continue
            ts = _iso_epoch(o.get("timestamp"))
            if ts is None:
                continue
            rid = "%s:%d" % (name, n)
            if forked and not burst_done:
                if burst_last is not None:
                    if ts - burst_last <= 1.0:
                        if burst_first is not None:
                            recs.pop(burst_first, None); burst_first = None
                        burst_last = ts
                        continue
                    burst_done = True
                else:
                    burst_last, burst_first = ts, rid
            rec = dict(last, k="codex", id=rid, t=ts, m=p.get("model") or model, s=name)
            if tier:
                rec["tier"] = tier
            recs[rid] = rec
    return list(recs.values())

def collect_records(home, since_ms):
    """返回 (记录列表, 最大 mtime 毫秒)。只看 mtime > since_ms 的文件。"""
    out, max_m = [], 0
    claude = {}
    for p in _claude_files(home):
        mt = _mtime_ms(p)
        max_m = max(max_m, mt)
        if mt <= since_ms:
            continue
        session = os.path.splitext(os.path.basename(p))[0]
        for line in _read_lines(p):
            if '"usage"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            rec = _claude_record(o, session)
            if rec is None:
                continue
            old = claude.get(rec["id"])
            if old is None or rec["in"] + rec["out"] > old["in"] + old["out"]:
                claude[rec["id"]] = rec
    out.extend(claude.values())
    for p in _codex_files(home):
        mt = _mtime_ms(p)
        max_m = max(max_m, mt)
        if mt <= since_ms:
            continue
        out.extend(_codex_file_records(p))
    return out, max_m

def run_records(since, gz):
    try:
        recs, max_m = collect_records(os.path.expanduser("~"), since)
        lines = [json.dumps(r, separators=(",", ":")) for r in recs]
        lines.append(json.dumps({"__ok__": True, "count": len(recs), "max_mtime": max_m}, separators=(",", ":")))
        text = "\n".join(lines) + "\n"
        if gz:
            co = zlib.compressobj(6, zlib.DEFLATED, -15)     # 原始 DEFLATE，Mac 端用 Foundation 直接解
            blob = co.compress(text.encode("utf-8")) + co.flush()
            sys.stdout.write(base64.b64encode(blob).decode("ascii") + "\n")
        else:
            sys.stdout.write(text)
        sys.stdout.flush()
        return 0
    except Exception as exc:
        emit_fail("%s: %s" % (type(exc).__name__, exc))
        return 1

def _today_totals(recs, start_s):
    acc = dict.fromkeys(("ctx", "cache_read", "cache_write", "out", "think", "requests"), 0)
    for r in recs:
        if r["t"] < start_s:
            continue
        acc["ctx"] += r["in"]; acc["cache_read"] += r["cr"]; acc["cache_write"] += r["cw"]
        acc["out"] += r["out"]; acc["think"] += r.get("th", 0); acc["requests"] += 1
    return acc if acc["requests"] > 0 else None

def selftest():
    global _session_counts, collect_platform_quotas
    import tempfile, shutil, contextlib, io
    tmp = tempfile.mkdtemp(prefix="vg-collector-")
    try:
        def w(rel, rows):
            p = os.path.join(tmp, rel)
            if not os.path.isdir(os.path.dirname(p)):
                os.makedirs(os.path.dirname(p))
            with open(p, "w") as fh:
                fh.write("\n".join(json.dumps(r) for r in rows) + "\n")
        a = lambda rid, out, ts="2026-09-18T10:00:00Z", **extra: dict({"type": "assistant", "timestamp": ts, "requestId": rid, "message": {"model": "claude-opus-5", "id": "m" + rid,
            "usage": {"input_tokens": 10, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 5, "output_tokens": out,
                      "cache_creation": {"ephemeral_1h_input_tokens": 5}}}}, **extra)
        w(".claude/projects/p/s1.jsonl", [a("r1", 3), a("r1", 9), a("r2", 4), a("r3", 1, isApiErrorMessage=True)])
        w(".claude/projects/p/s2.jsonl", [a("r1", 9)])
        usage = lambda i, c, o: {"input_tokens": i, "cached_input_tokens": c, "cache_write_input_tokens": 0, "output_tokens": o, "reasoning_output_tokens": 0}
        tur = lambda rid, u, ts: {"type": "token_usage_record", "timestamp": ts, "payload": {"response_id": rid, "usage": u}}
        tc = lambda total, last, ts: {"type": "event_msg", "timestamp": ts, "payload": {"type": "token_count", "info": {"total_token_usage": total, "last_token_usage": last}}}
        rows = [{"type": "session_meta", "payload": {"id": "x"}}, {"type": "turn_context", "payload": {"model": "gpt-6-sol"}},
                {"type": "event_msg", "timestamp": "2026-09-18T10:00:00Z", "payload": {"type": "thread_settings_applied", "thread_settings": {"service_tier": "priority"}}},
                tur("resp_1", usage(100, 40, 10), "2026-09-18T10:00:01Z"), tc(usage(100, 40, 10), usage(100, 40, 10), "2026-09-18T10:00:01Z"),
                tur("resp_2", usage(50, 10, 5), "2026-09-18T10:00:09Z"), tc(usage(150, 50, 15), usage(50, 10, 5), "2026-09-18T10:00:09Z"),
                tc(usage(150, 50, 15), usage(50, 10, 5), "2026-09-18T10:00:10Z")]
        w(".codex/sessions/2026/09/18/rollout-a.jsonl", rows)
        w(".codex/archived_sessions/rollout-a.jsonl", rows)
        old = [{"type": "turn_context", "payload": {"model": "gpt-5.6-sol"}},
               tc(usage(10, 0, 1), usage(10, 0, 1), "2026-09-18T11:00:00Z"), tc(usage(10, 0, 1), usage(10, 0, 1), "2026-09-18T11:00:05Z"),
               tc(usage(30, 5, 3), usage(20, 5, 2), "2026-09-18T11:00:09Z")]
        w(".codex/sessions/2026/09/18/rollout-b.jsonl", old)
        # The host may set CODEX_HOME to a real, large log tree; tests stay fixture-only.
        saved_codex_home = os.environ.get("CODEX_HOME")
        os.environ["CODEX_HOME"] = os.path.join(tmp, ".codex")
        recs, max_m = collect_records(tmp, 0)
        cl = [r for r in recs if r["k"] == "claude"]
        cx = [r for r in recs if r["k"] == "codex"]
        assert len(cl) == 2, cl
        assert [r["out"] for r in cl if r["id"] == "r1"] == [9], "同一 requestId 取 token 最多的那条"
        assert cl[0]["c1"] == 5 and cl[0]["in"] == 35
        assert len(cx) == 4, cx
        assert sorted(r["id"] for r in cx if r["id"].startswith("resp")) == ["resp_1", "resp_2"], "有 token_usage_record 就只认它，归档副本不重复"
        assert all(r.get("tier") == "priority" for r in cx if r["id"].startswith("resp"))
        assert sorted(r["in"] for r in cx if not r["id"].startswith("resp")) == [10, 20], "旧格式：累计没前进的重复行不算"
        assert max_m > 0
        recs2, _ = collect_records(tmp, max_m)
        assert recs2 == [], "游标之后没有新文件就不重发"
        if saved_codex_home is None: os.environ.pop("CODEX_HOME", None)
        else: os.environ["CODEX_HOME"] = saved_codex_home
        today = _today_totals(recs, 0)
        assert today["requests"] == 6
        # 配额 fixtures: 用户字段不外传，时间/窗口规范化，坏缺文件保持未知。
        quota_home = os.path.join(tmp, "quota-home")
        os.makedirs(os.path.join(quota_home, ".config", "claude"))
        with open(os.path.join(quota_home, ".config", "claude", "claude-usage.json"), "w") as fh:
            json.dump({"_captured_at": 1780000000, "five_hour": {"used_percentage": 31.5, "resets_at": 1780000300},
                       "seven_day": {"used_percentage": 120}, "account_email": "must-not-leak"}, fh)
        custom_claude = os.path.join(quota_home, "custom-claude")
        os.makedirs(custom_claude)
        with open(os.path.join(custom_claude, "claude-usage.json"), "w") as fh:
            json.dump({"five_hour": {"used_percentage": 12}}, fh)
        old_claude_config = os.environ.get("CLAUDE_CONFIG_DIR")
        os.environ["CLAUDE_CONFIG_DIR"] = custom_claude
        assert _read_claude_usage(quota_home)["five_hour"]["used_percentage"] == 12
        if old_claude_config is None: os.environ.pop("CLAUDE_CONFIG_DIR", None)
        else: os.environ["CLAUDE_CONFIG_DIR"] = old_claude_config
        os.makedirs(os.path.join(quota_home, ".grok", "logs"))
        grok = {"ts": "2026-05-29T12:00:00Z", "message": "billing: fetched credits config",
                "ctx": {"subscriptionTier": "SuperGrok", "config": {"creditUsagePercent": 44,
                "currentPeriod": {"start": "2026-05-22T12:00:00Z", "end": "2026-05-29T12:00:00Z"}}}}
        with open(os.path.join(quota_home, ".grok", "logs", "unified.jsonl"), "w") as fh: fh.write(json.dumps(grok) + "\n")
        os.makedirs(os.path.join(quota_home, ".cache", "agy-hud"))
        with open(os.path.join(quota_home, ".cache", "agy-hud", "quota_cache.json"), "w") as fh:
            json.dump({"updated_at": 1780000001, "pools": {"gemini": {"5h": {"remaining_fraction": 0.25, "reset_at": 1780001000}},
                "3p": {"weekly": {"remaining_fraction": 0.5, "recorded_at": 1780000000}}}}, fh)
        codex_day = datetime.datetime.fromtimestamp(time.time()).strftime("%Y/%m/%d")
        codex_dir = os.path.join(quota_home, ".codex", "sessions", codex_day)
        os.makedirs(codex_dir)
        with open(os.path.join(codex_dir, "quota.jsonl"), "w") as fh:
            fh.write(json.dumps({"timestamp": "2026-05-29T12:00:00Z", "payload": {"rate_limits": {
                "limit_id": "codex", "plan_type": "pro", "primary": {"used_percent": 22, "window_minutes": 300,
                "resets_at": 1780000400}, "secondary": {"used_percent": 77, "window_minutes": 10080,
                "resets_at": 1780600000}}}}) + "\n")
            # A newer Spark bucket must not replace the main Codex platform quota.
            fh.write(json.dumps({"timestamp": "2026-05-29T12:01:00Z", "payload": {"rate_limits": {
                "limit_id": "codex_spark", "plan_type": "spark", "primary": {"used_percent": 99,
                "window_minutes": 300}, "secondary": {"used_percent": 98, "window_minutes": 10080}}}}) + "\n")
        old_home = os.environ.get("CODEX_HOME")
        os.environ["CODEX_HOME"] = os.path.join(quota_home, ".codex")
        old_count = _session_counts
        _session_counts = lambda: (dict((k, 0) for k in ("claude", "codex", "grok", "agy")), False)
        try:
            platforms = collect_platform_quotas(quota_home, now=time.time())
        finally:
            _session_counts = old_count
            if old_home is None: os.environ.pop("CODEX_HOME", None)
            else: os.environ["CODEX_HOME"] = old_home
        assert set(platforms) == {"claude", "codex", "grok", "agy"}
        assert platforms["claude"]["quota"]["five_hour"]["used_percentage"] == 31.5
        assert platforms["claude"]["quota"]["seven_day"]["used_percentage"] == 100
        assert "account_email" not in (_read_claude_usage(quota_home) or {})
        assert platforms["grok"]["tier"] == "SuperGrok"
        assert platforms["grok"]["quota"]["seven_day"]["window_seconds"] == 604800
        assert platforms["agy"]["quota"]["five_hour"]["used_percentage"] == 75
        assert platforms["agy"]["quota"]["secondary_seven_day"]["used_percentage"] == 50
        assert platforms["codex"]["tier"] == "pro"
        assert platforms["codex"]["quota"]["five_hour"]["used_percentage"] == 22
        assert platforms["codex"]["quota"]["seven_day"]["used_percentage"] == 77
        assert "secondary_seven_day" not in platforms["codex"]["quota"]
        assert platforms["agy"]["note"] == "session_count_unavailable"
        legacy_home = os.path.join(tmp, "legacy")
        legacy_dir = os.path.join(legacy_home, ".codex", "sessions", codex_day)
        os.makedirs(legacy_dir)
        with open(os.path.join(legacy_dir, "legacy.jsonl"), "w") as fh:
            fh.write(json.dumps({"timestamp": "2026-05-29T12:00:00Z", "payload": {"rate_limits": {
                "plan_type": "legacy", "primary": {"used_percent": 31, "window_minutes": 300},
                "secondary": {"used_percent": 61, "window_minutes": 10080}}}}) + "\n")
        legacy_old_codex_home = os.environ.get("CODEX_HOME")
        os.environ["CODEX_HOME"] = os.path.join(legacy_home, ".codex")
        try:
            legacy_quota, legacy_plan, _legacy_capture = _codex_quotas(legacy_home, time.time())
        finally:
            if legacy_old_codex_home is None: os.environ.pop("CODEX_HOME", None)
            else: os.environ["CODEX_HOME"] = legacy_old_codex_home
        assert legacy_plan == "legacy" and legacy_quota["five_hour"]["used_percentage"] == 31
        assert legacy_quota["seven_day"]["used_percentage"] == 61
        for platform in platforms.values():
            assert {"tier", "sessions", "quota"}.issubset(platform)
            assert isinstance(platform["sessions"], int)
            for window in platform["quota"].values():
                if isinstance(window, dict) and "used_percentage" in window:
                    assert 0 <= window["used_percentage"] <= 100
                    assert set(window).issubset({"used_percentage", "resets_at", "captured_at", "window_seconds"})
        class FakeProc:
            def __init__(self, output): self.stdout = io.BytesIO(output)
            def wait(self, timeout=None): return 0
        ps_rows = (b"100 10 /usr/local/bin/claude\n101 100 /usr/local/bin/claude\n"
                   b"102 10 /usr/local/bin/codex\n103 10 /usr/local/bin/grok\n104 10 /usr/local/bin/agy\n"
                   b"105 10 /bin/zsh -lc 'codex --version'\n106 1 /usr/local/bin/claude\n"
                   b"107 10 /usr/bin/python3 -c 'task prompt mentions codex'\n")
        saved_popen = subprocess.Popen
        subprocess.Popen = lambda *_a, **_k: FakeProc(ps_rows)
        try:
            counted, ok = _session_counts()
        finally:
            subprocess.Popen = saved_popen
        assert ok and counted == {"claude": 1, "codex": 1, "grok": 1, "agy": 1}
        assert _read_claude_usage(os.path.join(tmp, "missing")) is None
        assert _grok_quota(os.path.join(tmp, "missing")) == (None, "")
        assert _agy_quotas(os.path.join(tmp, "missing")) == (None, None)
        assert _pct("bad") is None and _pct(float("nan")) is None and _pct(-3) == 0 and _pct(123) == 100
        saved_collect = collect_platform_quotas
        captured_out, captured_err = io.StringIO(), io.StringIO()
        collect_platform_quotas = lambda *_a, **_k: (_ for _ in ()).throw(RuntimeError("fixture failure"))
        try:
            with contextlib.redirect_stdout(captured_out), contextlib.redirect_stderr(captured_err):
                assert run_quotas() == 1
        finally:
            collect_platform_quotas = saved_collect
        failure = json.loads(captured_out.getvalue().splitlines()[0])
        assert failure.get("__ok__") is False and failure.get("error", "").startswith("RuntimeError")
        # 压缩往返
        co = zlib.compressobj(6, zlib.DEFLATED, -15)
        blob = co.compress(b"hello") + co.flush()
        assert zlib.decompress(blob, -15) == b"hello"
        print("collector selftest OK: 记录去重/游标/压缩 + 四平台额度窗口/缺失与脱敏")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

def main(argv):
    parser = argparse.ArgumentParser(description="VibeGauge remote opencode usage collector")
    parser.add_argument("--db", default=None, help="opencode.db 路径")
    parser.add_argument("--since", type=int, default=0, help="只输出 time_updated > MS 的行")
    parser.add_argument("--summary", action="store_true", help="输出今日各 CLI 用量汇总（单行 JSON）")
    parser.add_argument("--quotas", action="store_true", help="只输出平台额度与会话数，不扫描历史用量记录")
    parser.add_argument("--records", action="store_true", help="输出 Claude / Codex 逐条请求用量（mtime > --since 的文件）")
    parser.add_argument("--gz", action="store_true", help="--records 输出压缩成一行 base64(raw deflate)")
    parser.add_argument("--selftest", action="store_true", help="用临时目录自测解析口径")
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    if args.records:
        return run_records(args.since, args.gz)
    if args.quotas:
        return run_quotas()
    if args.summary:
        return run_summary()
    return run(resolve_db(args.db), args.since)

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
