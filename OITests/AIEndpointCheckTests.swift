import Foundation
import XCTest

@testable import OI

/// 设置面板的「获取模型」与「测试连接」：模型列表的请求地址与解析、用例的校验，以及设置面板的检查状态。
@MainActor
final class AIEndpointCheckTests: XCTestCase {
    // MARK: - 接口地址

    func testBaseURLAddsSchemeAndRejectsInvalidAddresses() {
        XCTAssertEqual(
            AIEndpointConfiguration.baseURL(from: " localhost:11434/v1 ")?.absoluteString,
            "http://localhost:11434/v1"
        )
        XCTAssertEqual(
            AIEndpointConfiguration.baseURL(from: "api.openai.com/v1")?.absoluteString,
            "https://api.openai.com/v1"
        )
        XCTAssertNil(AIEndpointConfiguration.baseURL(from: ""))
        XCTAssertNil(AIEndpointConfiguration.baseURL(from: "ftp://example.com"))
    }

    // MARK: - OpenAI 兼容客户端

    func testModelsURLAppendsModelsAndStripsChatCompletions() throws {
        typealias Client = OpenAICompatibleAIClient
        XCTAssertEqual(
            Client.modelsURL(for: try XCTUnwrap(URL(string: "https://api.openai.com/v1"))).absoluteString,
            "https://api.openai.com/v1/models"
        )
        XCTAssertEqual(
            Client.modelsURL(for: try XCTUnwrap(URL(string: "http://localhost:11434/v1/"))).absoluteString,
            "http://localhost:11434/v1/models"
        )
        XCTAssertEqual(
            Client.modelsURL(for: try XCTUnwrap(URL(string: "https://example.com/v1/chat/completions"))).absoluteString,
            "https://example.com/v1/models",
            "填的是完整的 chat/completions 地址时不重复拼接"
        )
    }

    /// OpenAI 与 Ollama 的模型列表格式相同：取出 ID，去重后按名称排序。
    func testModelIDsAreParsedDeduplicatedAndSorted() throws {
        let body = Data(
            #"{"object":"list","data":[{"id":"gpt-4o-mini","object":"model"},{"id":"gpt-4o"},{"id":"gpt-4o"}]}"#.utf8
        )
        XCTAssertEqual(try OpenAICompatibleAIClient.modelIDs(from: body, status: 200), ["gpt-4o", "gpt-4o-mini"])

        let ollama = Data(#"{"object":"list","data":[{"id":"qwen2.5:7b","object":"model","owned_by":"library"}]}"#.utf8)
        XCTAssertEqual(try OpenAICompatibleAIClient.modelIDs(from: ollama, status: 200), ["qwen2.5:7b"])
    }

    /// 401/403 提示检查 API Key，404 提示检查地址，其余状态码附带服务给出的原因。
    func testModelListFailuresExplainWhatToCheck() {
        func failure(_ body: String, status: Int) -> AIModelListError? {
            do {
                _ = try OpenAICompatibleAIClient.modelIDs(from: Data(body.utf8), status: status)
                return nil
            } catch {
                return error as? AIModelListError
            }
        }

        XCTAssertEqual(failure("", status: 401), .unauthorized(401))
        XCTAssertEqual(failure("", status: 403), .unauthorized(403))
        XCTAssertEqual(failure("", status: 404), .notFound)
        XCTAssertEqual(failure(#"{"error":{"message":"boom"}}"#, status: 500), .httpStatus(500, "boom"))
        XCTAssertEqual(failure("not json", status: 200), .invalidResponse)
        XCTAssertEqual(AIModelListError.unauthorized(401).errorDescription, "API Key 无效或没有权限（401）")
    }

    // MARK: - 用例

    func testListAIModelsValidatesAddressAndTrimsKey() async throws {
        let lister = StubAIModelLister(result: .success(["llama3"]))
        let useCase = ListAIModels(lister: lister)

        do {
            _ = try await useCase.execute(baseURLString: "  ", apiKey: "sk")
            XCTFail("地址无效时应抛出未配置错误")
        } catch {
            XCTAssertEqual(error as? ApplicationError, .aiNotConfigured)
        }
        XCTAssertTrue(lister.requests.isEmpty, "地址无效时不发请求")

        let models = try await useCase.execute(baseURLString: "localhost:11434/v1", apiKey: "  ")
        XCTAssertEqual(models, ["llama3"])
        XCTAssertEqual(
            lister.requests,
            [StubAIModelLister.Request(baseURL: try XCTUnwrap(URL(string: "http://localhost:11434/v1")), apiKey: nil)]
        )
    }

    func testListAIModelsMapsFailuresToReadableReasons() async {
        let useCase = ListAIModels(lister: StubAIModelLister(result: .failure(AIModelListError.unauthorized(401))))

        do {
            _ = try await useCase.execute(baseURLString: "https://api.openai.com/v1", apiKey: "sk-wrong")
            XCTFail("应抛出请求失败")
        } catch {
            XCTAssertEqual(error as? ApplicationError, .aiRequestFailed(reason: "API Key 无效或没有权限（401）"))
        }
    }

    // MARK: - 设置面板

    /// 用面板上尚未保存的 API Key 检查；没填模型时只报告可用模型数。
    func testCheckUsesCurrentInputAndReportsModelCount() async throws {
        let lister = StubAIModelLister(result: .success(["gpt-4o", "gpt-4o-mini"]))
        let viewModel = makeViewModel(lister: lister, settings: AppSettings(quickAIBaseURL: "https://api.example.com/v1"))
        viewModel.setQuickAIAPIKey(" sk-test ")

        let task = try XCTUnwrap(viewModel.checkAIEndpoint(.quickAI))
        XCTAssertEqual(viewModel.aiEndpointStatus(for: .quickAI), .checking)
        await task.value

        XCTAssertEqual(viewModel.aiEndpointStatus(for: .quickAI), .connected(modelCount: 2))
        XCTAssertEqual(viewModel.availableModels(for: .quickAI), ["gpt-4o", "gpt-4o-mini"])
        XCTAssertEqual(
            lister.requests,
            [StubAIModelLister.Request(baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")), apiKey: "sk-test")]
        )
        XCTAssertNil(viewModel.aiEndpointStatus(for: .translation), "两组接口的检查互不影响")
    }

    /// 填写的模型不在列表中时提示检查模型名；从列表中选择后提示随之消失，所选模型写回设置。
    func testModelMissingFromListIsReportedUntilOneIsSelected() async throws {
        let store = MemoryAppSettingsStore(initial: AppSettings(
            translationBaseURL: "https://api.example.com/v1",
            translationModel: "gpt-5"
        ))
        let viewModel = makeViewModel(
            lister: StubAIModelLister(result: .success(["gpt-4o", "gpt-4o-mini"])),
            settingsStore: store
        )

        _ = await viewModel.checkAIEndpoint(.translation)?.value
        XCTAssertEqual(viewModel.aiEndpointStatus(for: .translation), .modelNotListed("gpt-5"))

        viewModel.selectModel("gpt-4o-mini", for: .translation)
        XCTAssertEqual(viewModel.settings.translationModel, "gpt-4o-mini")
        XCTAssertEqual(store.load().translationModel, "gpt-4o-mini")
        XCTAssertEqual(viewModel.aiEndpointStatus(for: .translation), .connected(modelCount: 2))
    }

    func testEmptyModelListIsReported() async {
        let viewModel = makeViewModel(
            lister: StubAIModelLister(result: .success([])),
            settings: AppSettings(quickAIBaseURL: "https://api.example.com/v1")
        )

        _ = await viewModel.checkAIEndpoint(.quickAI)?.value

        XCTAssertEqual(viewModel.aiEndpointStatus(for: .quickAI), .noModels)
        XCTAssertTrue(viewModel.availableModels(for: .quickAI).isEmpty)
    }

    /// 失败时显示原因；之后改动接口地址或 API Key，旧的结果不再对应当前输入，随即清除。
    func testFailureShowsReasonAndEditingInputClearsResult() async {
        let viewModel = makeViewModel(
            lister: StubAIModelLister(result: .failure(AIModelListError.notFound)),
            settings: AppSettings(quickAIBaseURL: "https://api.example.com")
        )

        _ = await viewModel.checkAIEndpoint(.quickAI)?.value
        XCTAssertEqual(
            viewModel.aiEndpointStatus(for: .quickAI),
            .failed("接口地址不正确，或该服务不支持查询模型列表（404）")
        )

        viewModel.settings.quickAIBaseURL = "https://api.example.com/v1"
        XCTAssertNil(viewModel.aiEndpointStatus(for: .quickAI))

        _ = await viewModel.checkAIEndpoint(.quickAI)?.value
        XCTAssertNotNil(viewModel.aiEndpointStatus(for: .quickAI))
        viewModel.setQuickAIAPIKey("sk-new")
        XCTAssertNil(viewModel.aiEndpointStatus(for: .quickAI))
    }

    /// 检查进行中改动了输入：旧检查的结果到达后丢弃。
    func testResultArrivingAfterInputChangeIsDropped() async {
        let viewModel = makeViewModel(
            lister: StubAIModelLister(result: .success(["gpt-4o"])),
            settings: AppSettings(quickAIBaseURL: "https://api.example.com/v1")
        )

        let task = viewModel.checkAIEndpoint(.quickAI)
        viewModel.settings.quickAIBaseURL = "https://other.example.com/v1"
        _ = await task?.value

        XCTAssertNil(viewModel.aiEndpointStatus(for: .quickAI))
        XCTAssertTrue(viewModel.availableModels(for: .quickAI).isEmpty)
    }

    func testInvalidAddressFailsWithoutRequest() async {
        let lister = StubAIModelLister(result: .success(["gpt-4o"]))
        let viewModel = makeViewModel(lister: lister, settings: AppSettings())

        _ = await viewModel.checkAIEndpoint(.translation)?.value

        XCTAssertEqual(viewModel.aiEndpointStatus(for: .translation), .failed("请先填写有效的接口地址"))
        XCTAssertTrue(lister.requests.isEmpty)
    }

    func testCheckIsUnavailableWithoutListingService() {
        let viewModel = SettingsViewModel(
            settingsStore: MemoryAppSettingsStore(),
            loginItemController: StubLoginItemController()
        )

        XCTAssertNil(viewModel.checkAIEndpoint(.quickAI))
        XCTAssertNil(viewModel.aiEndpointStatus(for: .quickAI))
    }

    // MARK: - 辅助方法

    private func makeViewModel(
        lister: StubAIModelLister,
        settings: AppSettings = AppSettings(),
        settingsStore: MemoryAppSettingsStore? = nil
    ) -> SettingsViewModel {
        SettingsViewModel(
            settingsStore: settingsStore ?? MemoryAppSettingsStore(initial: settings),
            loginItemController: StubLoginItemController(),
            listAIModels: ListAIModels(lister: lister)
        )
    }
}

/// 返回给定的模型列表（或以给定错误失败），并记录收到的地址与 API Key。
private final class StubAIModelLister: AIModelListing, @unchecked Sendable {
    struct Request: Equatable {
        let baseURL: URL
        let apiKey: String?
    }

    private let lock = NSLock()
    private let result: Result<[String], any Error>
    private var storedRequests: [Request] = []

    init(result: Result<[String], any Error>) {
        self.result = result
    }

    var requests: [Request] {
        lock.withLock { storedRequests }
    }

    func models(baseURL: URL, apiKey: String?) async throws -> [String] {
        lock.withLock { storedRequests.append(Request(baseURL: baseURL, apiKey: apiKey)) }
        return try result.get()
    }
}
