//
//  ManagedHeadersViewModel.swift
//  Orange Cloud
//

import Foundation
import SwiftUI   // ObservableObject（iOS 16 基线：@Observable 是 iOS 17+）

@MainActor
final class ManagedHeadersViewModel: ObservableObject {

    @Published
    private(set) var requestHeaders: [ManagedTransform] = []
    @Published
    private(set) var responseHeaders: [ManagedTransform] = []
    @Published
    var isLoading = false
    @Published
    var loaded = false
    @Published
    var isMutating = false
    @Published
    var error: String?
    @Published
    var didMutate = false

    private let service: ManagedHeaderService
    private let zoneId: String

    init(service: ManagedHeaderService, zoneId: String) {
        self.service = service
        self.zoneId = zoneId
    }

    private func apply(_ transforms: ManagedTransforms) {
        // 接口不保证顺序，按 id 排一下，避免每次刷新行位置跳动
        requestHeaders = (transforms.managedRequestHeaders ?? []).sorted { $0.id < $1.id }
        responseHeaders = (transforms.managedResponseHeaders ?? []).sorted { $0.id < $1.id }
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            apply(try await service.transforms(zoneId: zoneId))
            loaded = true
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func setEnabled(_ item: ManagedTransform, enabled: Bool, isRequest: Bool) async {
        guard !isMutating else { return }
        isMutating = true
        error = nil
        do {
            apply(try await service.setEnabled(
                zoneId: zoneId, id: item.id, enabled: enabled, isRequest: isRequest
            ))
            didMutate.toggle()
        } catch {
            self.error = error.localizedDescription
        }
        isMutating = false
    }
}
