import SwiftUI

/// "今天 14:05", "昨天 09:12", "3月2日 18:00" or with the year when it is not this year.
func friendlyTime(_ millis: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    let calendar = Calendar.current
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    if calendar.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
        return "今天 " + formatter.string(from: date)
    }
    if calendar.isDateInYesterday(date) {
        formatter.dateFormat = "HH:mm"
        return "昨天 " + formatter.string(from: date)
    }
    formatter.dateFormat = calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
    return formatter.string(from: date)
}

/// "3 天前", "2 个月前" — for how long ago a repository was updated.
func agoText(_ millis: Int64) -> String {
    let days = Int((Date().timeIntervalSince1970 * 1000 - Double(millis)) / 86_400_000)
    switch days {
    case ..<1: return "今天"
    case 1: return "昨天"
    case ..<30: return "\(days) 天前"
    case ..<365: return "\(days / 30) 个月前"
    default: return "\(days / 365) 年前"
    }
}

/// A one-line text prompt as a sheet. [onSubmit] returns an error message to keep it open.
struct TextPrompt: View {
    let title: String
    let label: String
    var initial = ""
    var confirm = "确定"
    let onCancel: () -> Void
    let onSubmit: (String) -> String?

    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(submit)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(confirm, action: submit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { text = initial }
    }

    private func submit() {
        error = onSubmit(text)
    }
}

/// A short notice at the bottom of the window that goes away by itself.
struct Toast: View {
    let text: String
    let ok: Bool

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.icloud" : "exclamationmark.icloud")
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .foregroundStyle(ok ? Color.primary : Color.red)
            .shadow(radius: 4)
            .padding(.bottom, 16)
    }
}

struct Waiting: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sync status shown under a notebook: "已同步 · 今天 14:05", errors in red.
struct SyncStatusLine: View {
    let notebook: Notebook
    let syncing: Bool

    var body: some View {
        let (icon, text, isError): (String, String, Bool) = {
            if syncing { return ("arrow.triangle.2.circlepath", "正在同步…", false) }
            if let error = notebook.lastSyncError { return ("exclamationmark.icloud", "同步没有成功：\(error)", true) }
            if let at = notebook.lastSyncAt { return ("checkmark.icloud", "已同步 · \(friendlyTime(at))", false) }
            return ("icloud.slash", "还没有同步过", false)
        }()
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .lineLimit(2)
    }
}
