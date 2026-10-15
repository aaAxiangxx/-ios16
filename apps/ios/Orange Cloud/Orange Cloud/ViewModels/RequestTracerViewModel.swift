//
//  RequestTracerViewModel.swift
//  Orange Cloud
//

import Foundation
import SwiftUI   // ObservableObject（iOS 16 基线：@Observable 是 iOS 17+）

@MainActor
final class RequestTracerViewModel: ObservableObject {

    @Published
    var urlText = ""
    @Published
    var method = "GET"
    @Published
    private(set) var result: TraceResult?
    @Published
    private(set) var flatSteps: [FlatTraceStep] = []
    @Published
    var isTracing = false
    @Published
    var error: String?
    @Published
    var didTrace = false

    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]

    private let service: RequestTracerService
    private let accountId: String

    init(service: RequestTracerService, accountId: String) {
        self.service = service
        self.accountId = accountId
    }

    /// 只做最基本的形态校验，具体是否可达交给接口判断
    var canTrace: Bool {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.contains("://") && !isTracing
    }

    func run() async {
        guard canTrace else { return }
        isTracing = true
        error = nil
        do {
            let traceResult = try await service.trace(
                accountId: accountId,
                method: method,
                url: urlText.trimmingCharacters(in: .whitespaces)
            )
            result = traceResult
            flatSteps = (traceResult.trace ?? []).flattened()
            didTrace.toggle()
        } catch {
            self.error = error.localizedDescription
            result = nil
            flatSteps = []
        }
        isTracing = false
    }
}
