package com.moviepilottools.mptools.data

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 流量账本（今日 / 本月累计下载、上传）——与鸿蒙版 data/TrafficLedger.ets 同逻辑。
 *
 * 为什么要本地记账：
 * qBittorrent 的 alltime_dl / alltime_ul、Transmission 的 cumulative-stats 只给
 * 「装机以来的累计值」，两家都没有「今天用了多少 / 这个月用了多少」这种分时段口径
 * （历史版曾接第三方 torrent-traffic-monitor 面板，要额外部署一套服务 + 填账号，v1.5.1 已删）。
 *
 * 这里用「累计值的差值」自己算：
 *   - 每次刷新把各服务器当前的累计计数器记下来；
 *   - 跨天 / 跨月时，把「上一次观测到的累计值」当作新周期的起点（baseline）；
 *   - 今日 = 当前累计 − 今日起点，本月 = 当前累计 − 本月起点。
 * 累计计数器在下载器端是持久化的，所以 App 没开的时候流量也照跑，重开一次就对上了。
 *
 * 两个防御：
 *   1. 计数器变小（重装 qB / 换数据目录）→ 基线就地重置，不会出现天文数字；
 *   2. 跨周期时如果上次观测已经是 48 小时（月：7 天）以前，说明中间好久没开 App，
 *      那段流量没法合理归到「今天」，直接把当前值当起点，宁可从 0 起算。
 *
 * 存储：独立 SharedPreferences（mpt_traffic，不含任何账号密码，明文 JSON 即可），
 * 每 20 秒最多落一次盘。
 */
class TrafficLedger(context: Context) {

    /** 仪表盘流量瓦片要用的四个数字 */
    data class Totals(
        val dayDownload: Long = 0,
        val dayUpload: Long = 0,
        val monthDownload: Long = 0,
        val monthUpload: Long = 0,
        /** 至少有一台服务器参与了统计（否则页面显示「—」而不是 0 B） */
        val hasBaseline: Boolean = false
    )

    private data class Counter(val dl: Long, val ul: Long)

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREF_TRAFFIC, Context.MODE_PRIVATE)

    private var loaded = false
    private var day = ""
    private var month = ""
    /** 今日起点（当天第一次观测到的累计值） */
    private val base = mutableMapOf<String, Counter>()
    /** 本月起点 */
    private val mbase = mutableMapOf<String, Counter>()
    /** 最近一次观测到的累计值 */
    private val last = mutableMapOf<String, Counter>()
    private var lastAt = 0L
    private var savedAt = 0L
    private var dirty = false

    /**
     * 每轮刷新调一次：更新基线 / 最近观测，并按需落盘。
     * [samples] 必须是「全部已配置服务器」的快照（离线也要在里面，用来清理已删除的服务器）。
     */
    fun record(samples: Map<String, ServerSnapshot>, nowMs: Long = System.currentTimeMillis()) {
        ensureLoaded()
        val today = dayKey(nowMs)
        val thisMonth = monthKey(nowMs)
        val gapHours = if (lastAt > 0) (nowMs - lastAt) / 3_600_000.0 else 0.0

        if (day != today) {
            // 跨天：昨天的最后一个观测值就是今天的起点
            base.clear()
            if (gapHours <= DAY_GAP_LIMIT_HOURS) base.putAll(last)
            day = today
            dirty = true
        }
        if (month != thisMonth) {
            mbase.clear()
            if (gapHours <= MONTH_GAP_LIMIT_HOURS) mbase.putAll(last)
            month = thisMonth
            dirty = true
        }

        samples.forEach { (id, snap) ->
            if (!snap.online || !snap.cumulativeReliable) return@forEach
            val dl = snap.totalDownloaded
            val ul = snap.totalUploaded
            // 两个计数器都读不到（老版本下载器 / 接口裁剪）就跳过，不要把 0 当成真值写进基线
            if (dl <= 0 && ul <= 0) return@forEach
            val prev = last[id]
            if (prev != null && (dl < prev.dl || ul < prev.ul)) {
                // 计数器被清零（重装 / 换目录）：基线同步重置，本周期从当前值重新算
                base[id] = Counter(dl, ul)
                mbase[id] = Counter(dl, ul)
            }
            if (!base.containsKey(id)) base[id] = Counter(dl, ul)
            if (!mbase.containsKey(id)) mbase[id] = Counter(dl, ul)
            val cur = last[id]
            if (cur == null || cur.dl != dl || cur.ul != ul) {
                last[id] = Counter(dl, ul)
                dirty = true
            }
        }

        // 服务器被删掉：顺手把它的基线清掉，免得以后重加同 id 时串味
        prune(base, samples)
        prune(mbase, samples)
        prune(last, samples)

        lastAt = nowMs
        maybeSave(nowMs)
    }

    private fun prune(map: MutableMap<String, Counter>, samples: Map<String, ServerSnapshot>) {
        val dead = map.keys.filter { !samples.containsKey(it) }
        if (dead.isEmpty()) return
        dead.forEach { map.remove(it) }
        dirty = true
    }

    /** 取指定服务器集合的今日 / 本月累计（选中服务器过滤后的口径） */
    fun totalsFor(ids: Collection<String>): Totals {
        ensureLoaded()
        var dayDl = 0L
        var dayUl = 0L
        var monthDl = 0L
        var monthUl = 0L
        var hasBase = false
        ids.forEach { id ->
            val cur = last[id] ?: return@forEach
            base[id]?.let {
                hasBase = true
                dayDl += (cur.dl - it.dl).coerceAtLeast(0)
                dayUl += (cur.ul - it.ul).coerceAtLeast(0)
            }
            mbase[id]?.let {
                monthDl += (cur.dl - it.dl).coerceAtLeast(0)
                monthUl += (cur.ul - it.ul).coerceAtLeast(0)
            }
        }
        return Totals(
            dayDownload = dayDl,
            dayUpload = dayUl,
            monthDownload = monthDl,
            monthUpload = monthUl,
            hasBaseline = hasBase
        )
    }

    /** 立即落盘（退到后台 / ViewModel 销毁时调用，避免最后一段数据丢失） */
    fun flush() {
        if (dirty) save(System.currentTimeMillis())
    }

    private fun ensureLoaded() {
        if (loaded) return
        loaded = true
        val raw = prefs.getString(KEY_LEDGER, "") ?: return
        if (raw.isEmpty()) return
        try {
            val obj = JSONObject(raw)
            day = obj.optString("day", "")
            month = obj.optString("month", "")
            lastAt = obj.optLong("lastAt", 0L)
            readCounters(obj.optJSONArray("base"), base)
            readCounters(obj.optJSONArray("mbase"), mbase)
            readCounters(obj.optJSONArray("last"), last)
        } catch (e: Exception) {
            Log.w(TAG, "读取账本失败: ${e.message}")
        }
    }

    private fun readCounters(arr: JSONArray?, into: MutableMap<String, Counter>) {
        if (arr == null) return
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val id = o.optString("id", "")
            if (id.isEmpty()) continue
            into[id] = Counter(o.optLong("dl", 0L), o.optLong("ul", 0L))
        }
    }

    private fun maybeSave(nowMs: Long) {
        if (!dirty) return
        if (nowMs - savedAt < SAVE_INTERVAL_MS) return
        save(nowMs)
    }

    private fun save(nowMs: Long) {
        try {
            val obj = JSONObject()
            obj.put("day", day)
            obj.put("month", month)
            obj.put("lastAt", lastAt)
            obj.put("base", toJson(base))
            obj.put("mbase", toJson(mbase))
            obj.put("last", toJson(last))
            prefs.edit().putString(KEY_LEDGER, obj.toString()).apply()
            dirty = false
            savedAt = nowMs
        } catch (e: Exception) {
            Log.w(TAG, "账本落盘失败: ${e.message}")
        }
    }

    private fun toJson(src: Map<String, Counter>): JSONArray {
        val arr = JSONArray()
        src.forEach { (id, c) ->
            arr.put(
                JSONObject()
                    .put("id", id)
                    .put("dl", c.dl)
                    .put("ul", c.ul)
            )
        }
        return arr
    }

    private fun dayKey(ts: Long): String =
        SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(ts))

    private fun monthKey(ts: Long): String =
        SimpleDateFormat("yyyy-MM", Locale.US).format(Date(ts))

    private companion object {
        const val TAG = "TrafficLedger"
        const val PREF_TRAFFIC = "mpt_traffic"
        /**
         * v2：旧账本可能把「任务累计和」当成全量计数器写下基线（接口抖动时），
         * 导致今日/本月显示装机总流量。升级后整套基线作废，从下一轮可靠快照重新起算。
         */
        const val KEY_LEDGER = "ledger_v2"
        /** 落盘节流：轮询 5~10 秒一次，没必要每次都写盘 */
        const val SAVE_INTERVAL_MS = 20_000L
        /** 跨天时「上次观测」超过这个间隔就不再当作今天的起点 */
        const val DAY_GAP_LIMIT_HOURS = 48.0
        /** 跨月时的同类上限 */
        const val MONTH_GAP_LIMIT_HOURS = 24.0 * 7
    }
}
