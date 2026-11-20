import Foundation
import CoreGraphics
import SwitchCore

struct ScenarioFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ScenarioFailure(description: message) }
}

let switchScenarios: [(String, () throws -> Void)] = [
    ("正向切换与循环", {
        var session = SwitchSession()
        session.begin(backward: false)
        session.load(["current", "previous", "third"], currentID: "current")
        try expect(session.selectedID == "previous", "首次应选中上次窗口")
        session.move(2)
        try expect(session.selectedID == "current", "应循环回到开头")
    }),
    ("反向循环", {
        var session = SwitchSession()
        session.begin(backward: true)
        session.load(["a", "b", "c"], currentID: "a")
        try expect(session.selectedID == "c", "反向首次应选中末尾")
    }),
    ("原窗口不在列表时从边界开始", {
        var session = SwitchSession()
        session.begin(backward: false)
        session.load(["a", "b", "c"], currentID: "closed")
        try expect(session.selectedID == "a", "原窗口不可用时应选择最近窗口")
        session.begin(backward: false)
        session.move(-1)
        session.load(["a", "b", "c"], currentID: nil)
        try expect(session.selectedID == "c", "加载期间的反向操作应从首项向前循环")
        session.begin(backward: true)
        session.load(["a", "b", "c"], currentID: nil)
        try expect(session.selectedID == "c", "反向启动时应选择末项")
    }),
    ("快速松键保留切换意图", {
        var session = SwitchSession()
        session.begin(backward: false)
        try expect(session.release() == nil && session.commitWhenReady, "加载时应等待而非丢失确认")
        session.load(["a", "b"], currentID: "a")
        try expect(session.release() == "b", "加载后应提交正确窗口")
        try expect(!session.isActive, "提交后应结束会话")
    }),
    ("刚打开的窗口不会被第一次切换重新选中", {
        let recent = ["previous", "older"]
        for snapshot in [["previous", "new", "older"], ["previous", "older"]] {
            var session = SwitchSession()
            session.begin(backward: false)
            try expect(session.release() == nil && session.commitWhenReady, "焦点查询返回前的松键应保留")
            let ordered = WindowOrder.byRecency(snapshot, id: \.self, focusedID: "new", recent: recent)
            session.load(ordered, currentID: "new")
            try expect(session.release() == "previous", "第一次切换必须回到上一窗口，即使新窗口还没进快照")
        }
    }),
    ("加载期间连续按键", {
        var session = SwitchSession()
        session.begin(backward: false)
        session.move(1)
        session.move(1)
        session.load(["a", "b", "c", "d"], currentID: "a")
        try expect(session.release() == "d", "应保留所有排队的移动操作")
    }),
    ("取消后忽略迟到结果", {
        var session = SwitchSession()
        session.begin(backward: false)
        _ = session.release()
        session.cancel()
        session.load(["a", "b"], currentID: "a")
        try expect(session.release() == nil && session.ids.isEmpty && !session.commitWhenReady, "取消后不能恢复旧会话")
    }),
    ("搜索筛选与清空恢复", {
        var session = SwitchSession()
        session.begin(backward: false)
        session.load(["a", "b", "c"], currentID: "a")
        session.filter(to: ["b", "c"])
        try expect(session.selectedID == "b", "筛选应保留已有选择")
        session.filter(to: [])
        session.move(1)
        try expect(session.selectedID == nil, "空列表不能产生选择")
        session.filter(to: ["a", "c"])
        try expect(session.selectedID == "a", "恢复后应选中首项")
    }),
    ("空列表与单窗口", {
        for ids: [String] in [[], ["only"]] {
            var session = SwitchSession()
            session.begin(backward: true)
            session.load(ids, currentID: ids.first)
            session.move(-3)
            try expect(session.release() == ids.first, "空列表或单窗口选择错误")
        }
    }),
    ("中英文与多关键词搜索", {
        try expect(WindowSearch.matches(query: " safari  周末 ", title: "周末，去山里走走", app: "Safari"), "应同时匹配应用名与中文标题")
        try expect(WindowSearch.matches(query: "cafe", title: "Café inspiration", app: "Notes"), "应忽略重音符号")
        try expect(!WindowSearch.matches(query: "safari missing", title: "周末", app: "Safari"), "所有关键词都必须匹配")
        try expect(WindowSearch.matches(query: "  ", title: "任何窗口", app: "应用"), "空白搜索应显示所有窗口")
    }),
    ("大量正反向移动保持索引有效", {
        for count in 1...30 {
            let ids = (0..<count).map(String.init)
            for steps in -40...40 {
                var session = SwitchSession()
                session.begin(backward: false)
                session.load(ids, currentID: "0")
                session.move(steps)
                let expected = ids[((1 + steps) % count + count) % count]
                try expect(session.selectedID == expected, "循环索引越界：\(count), \(steps)")
            }
        }
    }),
    ("同名但不同位置的窗口不能关联截图", {
        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let candidates = [WindowMatchCandidate(id: 1, bounds: frame.offsetBy(dx: 500, dy: 0), title: "文稿")]
        try expect(WindowMatcher.match(bounds: frame, title: "文稿", candidates: candidates) == nil, "标题相同不能越过几何约束")
    }),
    ("重叠窗口只使用无歧义的匹配", {
        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let candidates = [WindowMatchCandidate(id: 1, bounds: frame, title: "A"),
                          WindowMatchCandidate(id: 2, bounds: frame, title: "B")]
        try expect(WindowMatcher.match(bounds: frame, title: "B", candidates: candidates) == 2, "同位置时标题可以消除歧义")
        try expect(WindowMatcher.match(bounds: frame, title: "", candidates: candidates) == nil, "同位置且没有标题时不能猜测")
        let duplicate = candidates + [WindowMatchCandidate(id: 3, bounds: frame, title: "B")]
        try expect(WindowMatcher.match(bounds: frame, title: "B", candidates: duplicate) == nil, "同名重叠时不能猜测")
        try expect(WindowMatcher.match(bounds: frame, title: "AX标题", candidates: [WindowMatchCandidate(id: 4, bounds: frame, title: nil)]) == 4, "唯一几何匹配不要求屏幕录制权限提供标题")
    }),
    ("多个 AX 窗口争用同一截图编号时全部放弃关联", {
        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let candidates = [WindowMatchCandidate(id: 1, bounds: frame, title: "文稿")]
        let windows = [(id: "a", bounds: frame, title: "文稿"), (id: "b", bounds: frame, title: "文稿")]
        try expect(WindowMatcher.matchAll(windows, candidates: candidates).isEmpty, "不能用枚举顺序决定截图归属")
        try expect(WindowMatcher.matchAll(Array(windows.reversed()), candidates: candidates).isEmpty, "倒序也应保守降级")
    }),
    ("目录过期以最后成功读取为准", {
        var freshness = CatalogFreshness(lifetime: 6)
        freshness.record("slow", at: 10)
        try expect(freshness.isFresh("slow", at: 15), "短暂超时应保留窗口")
        try expect(!freshness.isFresh("slow", at: 17), "重复超时不能永久续期")
        try expect(!freshness.isFresh("unknown", at: 10), "未成功读取的窗口不可当作缓存")
        freshness.record("slow", at: 18)
        freshness.retain([])
        try expect(!freshness.isFresh("slow", at: 18), "关闭窗口应移除时间记录")
    }),
    ("新会话不继承旧搜索和确认状态", {
        var session = SwitchSession()
        session.begin(backward: false)
        _ = session.release()
        session.begin(backward: true)
        session.load(["a", "b", "c"], currentID: "a")
        try expect(!session.commitWhenReady && session.selectedID == "c", "新会话应完全重置")
    })
]
