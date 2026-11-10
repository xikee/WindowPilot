import Foundation

/// 选择状态独立于系统窗口与视图，保证快速按下、松开时行为一致。
public struct SwitchSession {
    public private(set) var ids: [String] = []
    public private(set) var selectedID: String?
    public private(set) var isLoading = false
    public private(set) var commitWhenReady = false
    public private(set) var isActive = false
    private var pendingSteps = 0

    public init() {}

    public mutating func begin(backward: Bool) {
        ids = []
        selectedID = nil
        isActive = true
        isLoading = true
        commitWhenReady = false
        pendingSteps = backward ? -1 : 1
    }

    public mutating func load(_ newIDs: [String], currentID: String?) {
        guard isActive else { return }
        ids = newIDs
        isLoading = false
        let origin = currentID.flatMap { ids.firstIndex(of: $0) } ?? 0
        selectedID = ids.isEmpty ? nil : ids[wrapped(origin + pendingSteps)]
        pendingSteps = 0
    }

    public mutating func move(_ steps: Int) {
        guard isActive else { return }
        if isLoading { pendingSteps += steps; return }
        guard !ids.isEmpty else { return }
        let index = selectedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        selectedID = ids[wrapped(index + steps)]
    }

    public mutating func select(_ id: String) {
        guard ids.contains(id) else { return }
        selectedID = id
    }

    public mutating func filter(to newIDs: [String]) {
        ids = newIDs
        if !ids.contains(selectedID ?? "") { selectedID = ids.first }
    }

    public mutating func release() -> String? {
        guard isActive else { return nil }
        if isLoading { commitWhenReady = true; return nil }
        let result = selectedID
        cancel()
        return result
    }

    public mutating func cancel() {
        isActive = false
        isLoading = false
        commitWhenReady = false
        ids = []
        selectedID = nil
        pendingSteps = 0
    }

    private func wrapped(_ index: Int) -> Int { (index % ids.count + ids.count) % ids.count }
}

public enum WindowSearch {
    public static func matches(query: String, title: String, app: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        let text = "\(app) \(title)"
        return terms.allSatisfy {
            text.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
