//
//  DNSListView.swift
//  Orange Cloud
//
//  DNS 记录列表：@Query 读缓存、下拉刷新、滑动编辑/删除、Sheet 表单增改。
//

import SwiftUI
#if canImport(TipKit)
import TipKit
#endif

struct DNSListView: View {

    let zoneId: String
    let zoneName: String

    @EnvironmentObject private var auth: AuthManager
    /// 取代原 SwiftData `@Query`：DNS 缓存按 zoneId 过滤后由 Store 发布。
    @EnvironmentObject private var dnsCache: DNSCache

    @State private var viewModel: DNSListViewModel
    @State private var searchText = ""
    @State private var formMode: DNSFormMode?
    @State private var recordToDelete: CachedDNSRecord?
    @State private var deniedScope: String?       // 权限不足时非空，触发提示

    init(zoneId: String, zoneName: String, session: SessionStore) {
        self.zoneId = zoneId
        self.zoneName = zoneName
        _viewModel = State(initialValue: DNSListViewModel(dnsService: session.dnsService, zoneId: zoneId, zoneName: zoneName))
    }

    /// 原 `@Query` 的 `sort: [type, name]` 在这里显式复现。
    private var records: [CachedDNSRecord] {
        dnsCache.records.sorted {
            let byType = $0.type.localizedCaseInsensitiveCompare($1.type)
            return byType != .orderedSame
                ? byType == .orderedAscending
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var filteredRecords: [CachedDNSRecord] {
        guard !searchText.isEmpty else { return records }
        return records.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.content.localizedCaseInsensitiveContains(searchText)
                || $0.type.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - 权限检查

    private var canWrite: Bool { auth.hasScope("dns.write") }

    /// dns.write 存在则执行 action，否则弹出权限提示
    private func requireWrite(_ action: () -> Void) {
        if canWrite { action() } else { deniedScope = "dns.write" }
    }

    // MARK: - body

    var body: some View {
        Group {
            if records.isEmpty && viewModel.isLoading {
                SkeletonList(rows: 10, icon: .rounded(width: 52, height: 24), trailing: true)
            } else if records.isEmpty {
                OCEmptyStateView {
                    Label("没有 DNS 记录", systemImage: "network.slash")
                } description: {
                    Text(canWrite ? String(localized: "点击右上角 + 添加第一条记录") : String(localized: "当前授权仅限读取，无法添加记录"))
                } actions: {
                    if canWrite {
                        Button("添加记录") { formMode = .add }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.ocOrangePressed)
                            .fontWeight(.bold)
                    }
                }
            } else if filteredRecords.isEmpty {
                OCSearchEmptyStateView(text: searchText)
            } else {
                recordList
            }
        }
        .background { SkyBackground() }
        .navigationTitle(zoneName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索记录")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加", systemImage: "plus") { requireWrite { formMode = .add } }
            }
        }
        .sheet(item: $formMode) { mode in
            DNSRecordFormView(mode: mode, viewModel: viewModel)
        }
        .confirmationDialog(
            "删除 DNS 记录",
            isPresented: .init(
                get: { recordToDelete != nil },
                set: { if !$0 { recordToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let record = recordToDelete {
                Button("删除 \(record.name)", role: .destructive) {
                    Task {
                        await viewModel.delete(recordId: record.id)
                    }
                }
            }
        } message: {
            Text("此操作不可撤销，DNS 解析将立即生效变更。")
        }
        .task {
            // 取代原 `@Query` 的谓词：把 DNS 缓存切到当前域名，Store 随即发布该域名的记录。
            DNSCache.shared.activate(zoneId: zoneId)
            await viewModel.refresh()
        }
        .ocSensoryFeedback(.success, trigger: viewModel.didSave)
        // 权限不足提示
        .alert("权限不足", isPresented: .init(
            get: { deniedScope != nil },
            set: { if !$0 { deniedScope = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text("当前授权未包含 DNS 编辑权限（\(deniedScope ?? "dns.write")）。\n请在设置中退出登录后重新授权以启用此功能。")
        }
        // API 错误提示（仅在表单未显示时展示，避免与表单内错误重叠）
        .alert("出错了", isPresented: .init(
            get: { viewModel.error != nil && formMode == nil && deniedScope == nil },
            set: { if !$0 { viewModel.error = nil } }
        )) {
            apiErrorDocButton(for: viewModel.error)
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.error ?? "")
        }
    }

    private var recordList: some View {
        List {
            if canWrite {
#if canImport(TipKit)
                tipViewCompat(tip: DNSSwipeTip())
#else
                // iOS 16：TipKit 不可用，等价横幅由 AppTips.swift 的 `dnsSwipeTip` 渲染。
                tipViewCompat(tip: dnsSwipeTip)
#endif
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(filteredRecords) { record in
                DNSRecordRow(record: record)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            requireWrite { recordToDelete = record }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            requireWrite { formMode = .edit(record) }
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        requireWrite { formMode = .edit(record) }
                    }
                    .glassRow()
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable {
            await viewModel.refresh(force: true)
        }
    }
}

// MARK: - 表单模式

enum DNSFormMode: Identifiable {
    case add
    case edit(CachedDNSRecord)

    var id: String {
        switch self {
        case .add:               "add"
        case .edit(let record):  record.id
        }
    }
}

// MARK: - 记录行

struct DNSRecordRow: View {
    let record: CachedDNSRecord

    var body: some View {
        HStack(spacing: 12) {
            Text(record.type)
                .font(.caption.bold().monospaced())
                .frame(width: 52)
                .padding(.vertical, 4)
                .background(Color.ocOrange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Color.ocOrangeText)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(record.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // NS 委派记录：遮蔽了同名下多少条记录
                if record.type == "NS", record.shadowedRecordsCount > 0 {
                    Text("遮蔽了 \(record.shadowedRecordsCount) 条记录")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if record.isShadowed {
                // 被 NS 委派遮蔽：Cloudflare 不会响应这条记录（详情见编辑页说明）
                Label("已被遮蔽", systemImage: "eye.slash")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                    .fixedSize()
            }

            ProxiedBadge(proxied: record.proxied)
        }
        .padding(.vertical, 2)
    }
}
