public enum WindowOrder {
    /// 先放实际的前台窗口，其他窗口保持最近使用顺序。
    public static func byRecency<Window>(_ windows: [Window], id: KeyPath<Window, String>,
                                         focusedID: String?, recent: [String]) -> [Window] {
        let ranks = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($0.element, $0.offset) })
        func rank(_ window: Window, offset: Int) -> Int {
            let identifier = window[keyPath: id]
            if identifier == focusedID { return -1 }
            return ranks[identifier] ?? recent.count + offset
        }
        return windows.enumerated().sorted { rank($0.element, offset: $0.offset) < rank($1.element, offset: $1.offset) }.map(\.element)
    }
}
