import Foundation

/// 文件搜索返回的文件或文件夹元数据，与具体平台无关。
struct FileDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let isDirectory: Bool
    /// 用户最近一次“碰过”该文件的时间：打开、修改或加入目录中的最新者。
    /// 仅按打开时间排序会让刚下载、刚创建却从未打开的文件沉底。
    let activityDate: Date

    init(name: String, url: URL, isDirectory: Bool, activityDate: Date = .distantPast) {
        self.id = url.standardizedFileURL.path
        self.name = name
        self.url = url.standardizedFileURL
        self.isDirectory = isDirectory
        self.activityDate = activityDate
    }
}
