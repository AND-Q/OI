import Foundation

/// 启动器中的错误提示：失败横幅、Quick AI 回答区与后台打开失败的系统通知各自使用的文案。
enum LauncherErrorMessage {
    static func message(for error: Error) -> String {
        switch error {
        case let applicationError as ApplicationError:
            message(for: applicationError)
        default:
            "操作未能完成，请重试。"
        }
    }

    private static func message(for applicationError: ApplicationError) -> String {
        switch applicationError {
        case .discoveryFailed(let reason):
            "无法加载应用列表：\(reason)"
        case .launchFailed(let applicationName, let reason):
            "无法启动 \(applicationName)：\(reason)"
        case .fileSearchFailed(let reason):
            "无法搜索文件：\(reason)"
        case .fileOpenFailed(let fileName, let reason):
            "无法打开 \(fileName)：\(reason)"
        case .urlOpenFailed(let reason):
            "无法打开链接：\(reason)"
        case .aiNotConfigured:
            "请先在「设置… → Quick AI」中填写接口地址与模型。"
        case .aiRequestFailed(let reason):
            "回答失败：\(reason)"
        case .updateCheckFailed(let reason):
            "检查更新失败：\(reason)"
        }
    }

    /// 后台打开失败的系统通知：标题说明哪一项没能打开，正文为原因。
    static func notification(for error: Error) -> (title: String, body: String) {
        switch error as? ApplicationError {
        case .launchFailed(let applicationName, let reason)?:
            ("无法启动 \(applicationName)", reason)
        case .fileOpenFailed(let fileName, let reason)?:
            ("无法打开 \(fileName)", reason)
        case .urlOpenFailed(let reason)?:
            ("无法打开链接", reason)
        default:
            ("操作未能完成", "请重试。")
        }
    }
}
