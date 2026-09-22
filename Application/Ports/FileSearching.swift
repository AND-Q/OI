import Foundation

/// 用于按名称检索文件与文件夹的应用层端口。
/// `limit` 是候选条数上限，按实现方的粗排顺序截取；最终展示条数由用例层排序后决定。
protocol FileSearching: Sendable {
    func search(query: String, limit: Int) async throws -> [FileDescriptor]
}
