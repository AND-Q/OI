import CoreGraphics
import Foundation

/// 全局触控板用力点按（二段压力）监听端口。
@MainActor
protocol ForceTouchMonitoring: AnyObject {
    /// 开始监听；每次按压进入第二段时在主线程回调一次，参数为当时的指针位置（全局显示坐标）。
    func start(handler: @escaping (CGPoint) -> Void)
    func stop()
}
