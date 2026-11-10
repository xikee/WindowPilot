import Foundation
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
    ("快速松键保留切换意图", {
        var session = SwitchSession()
        session.begin(backward: false)
        try expect(session.release() == nil && session.commitWhenReady, "加载时应等待而非丢失确认")
        session.load(["a", "b"], currentID: "a")
        try expect(session.release() == "b", "加载后应提交正确窗口")
        try expect(!session.isActive, "提交后应结束会话")
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
    ("新会话不继承旧搜索和确认状态", {
        var session = SwitchSession()
        session.begin(backward: false)
        _ = session.release()
        session.begin(backward: true)
        session.load(["a", "b", "c"], currentID: "a")
        try expect(!session.commitWhenReady && session.selectedID == "c", "新会话应完全重置")
    })
]
