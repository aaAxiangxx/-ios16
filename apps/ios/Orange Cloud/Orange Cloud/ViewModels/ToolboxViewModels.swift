//
//  ToolboxViewModels.swift
//  Orange Cloud
//
//  免登录工具箱各工具的 ViewModel（@Observable / @MainActor）。
//  CIDR 为纯本地同步计算，无 VM，直接在 View 里调 CIDRCalculator。
//

import Foundation
import SwiftUI   // ObservableObject（iOS 16 基线：@Observable 是 iOS 17+）

// MARK: - DNS 查询

@MainActor
final class DNSLookupViewModel: ObservableObject {
    @Published
    var name = ""
    @Published
    var type: DNSQueryType = .a
    @Published
    private(set) var results: [DNSRecordResult] = []
    @Published
    var isLoading = false
    @Published
    var error: String?
    @Published
    private(set) var hasRun = false

    private let service = DNSLookupService()

    func run() async {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isLoading = true
        error = nil
        do {
            results = try await service.lookup(name: query, type: type)
        } catch {
            results = []
            self.error = error.localizedDescription
        }
        hasRun = true
        isLoading = false
    }
}

// MARK: - CF 数据中心 trace

@MainActor
final class CFTraceViewModel: ObservableObject {
    @Published
    var host = "1.1.1.1"
    @Published
    private(set) var result: CFTraceResult?
    @Published
    var isLoading = false
    @Published
    var error: String?

    private let service = CFTraceService()

    func run() async {
        isLoading = true
        error = nil
        do {
            result = try await service.trace(host: host)
        } catch {
            result = nil
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - HTTP 请求器

@MainActor
final class HTTPProbeViewModel: ObservableObject {
    @Published
    var urlString = "https://"
    @Published
    var method = "GET"
    let methods = ["GET", "HEAD", "POST"]
    @Published
    private(set) var result: HTTPProbeResult?
    @Published
    var isLoading = false
    @Published
    var error: String?

    private let service = HTTPProbeService()

    func run() async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "https://" else { return }
        isLoading = true
        error = nil
        do {
            result = try await service.probe(method: method, urlString: trimmed)
        } catch {
            result = nil
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - SSL 证书检查

@MainActor
final class CertInspectViewModel: ObservableObject {
    @Published
    var host = ""
    @Published
    private(set) var info: CertInfo?
    @Published
    var isLoading = false
    @Published
    var error: String?

    private let service = CertInspectService()

    func run() async {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return }
        isLoading = true
        error = nil
        do {
            info = try await service.inspect(host: h)
        } catch {
            info = nil
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - WHOIS

@MainActor
final class WhoisViewModel: ObservableObject {
    @Published
    var domain = ""
    @Published
    private(set) var info: WhoisInfo?
    @Published
    var isLoading = false
    @Published
    var error: String?

    private let service = RDAPService()

    func run() async {
        let d = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return }
        isLoading = true
        error = nil
        do {
            info = try await service.lookup(domain: d)
        } catch {
            info = nil
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - GeoIP

@MainActor
final class GeoIPViewModel: ObservableObject {
    @Published
    var ip = ""
    @Published
    private(set) var result: GeoIPResult?
    @Published
    private(set) var hasRun = false
    @Published
    var isLoading = false
    @Published
    var error: String?

    private let service = GeoIPService()

    func run() async {
        isLoading = true
        error = nil
        do {
            let r = try await service.lookup(ip: ip.trimmingCharacters(in: .whitespacesAndNewlines))
            if r.success {
                result = r
            } else {
                result = nil
                error = r.message ?? String(localized: "查询失败")
            }
        } catch {
            result = nil
            self.error = error.localizedDescription
        }
        hasRun = true
        isLoading = false
    }
}
