import StudioCore
import SwiftUI

struct QueueView: View {
    @Environment(AppModel.self) private var app

    var queue: JobQueue { app.queue }

    var body: some View {
        Group {
            if queue.jobs.isEmpty {
                EmptyStateView(title: "Nenhum trabalho na fila",
                               message: "Selecione episódios na Biblioteca para traduzir uma temporada inteira. A fila continua de onde parou se o app for fechado.",
                               systemImage: "list.bullet.clipboard") {
                    Button("Ir para a Biblioteca") { app.selection = .library }
                }
            } else {
                List {
                    if queue.interruptedCount > 0 {
                        InlineMessage(kind: .warning, text: "\(queue.interruptedCount) trabalhos foram interrompidos quando o app fechou. Retome para continuar dos checkpoints salvos.")
                            .listRowSeparator(.hidden)
                    }
                    ForEach(queue.jobs.reversed()) { job in JobRow(job: job) }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Fila")
        .navigationSubtitle(queue.pendingCount > 0 ? "\(queue.pendingCount) em andamento ou aguardando" : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Retomar interrompidos", systemImage: "arrow.clockwise.circle") { queue.resumeInterrupted() }
                    .disabled(!queue.jobs.contains { [.interrupted, .failed, .cancelled].contains($0.status) })
                Button("Cancelar todos", systemImage: "stop.circle") { queue.cancelAll() }
                    .disabled(queue.pendingCount == 0)
                Button("Limpar concluídos", systemImage: "trash") { queue.removeFinished() }
                    .disabled(!queue.jobs.contains { $0.status.isFinished })
            }
        }
        .onChange(of: queue.isRunning) { app.library.refreshStatuses(); app.refreshRecents() }
    }
}

private struct JobRow: View {
    let job: Job
    @Environment(AppModel.self) private var app
    @State private var showLog = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 28)
                .symbolEffect(.pulse, isActive: job.status == .running)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack {
                    Text(job.title).font(.headline).lineLimit(1)
                    Tag(text: job.kind.label)
                    Spacer()
                    Text(job.status.label).font(.callout).foregroundStyle(color)
                }
                if job.status == .running {
                    ProgressView(value: job.progress)
                }
                Text(job.message).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                if showLog {
                    Text(job.log.joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                if !job.status.isFinished {
                    Button("Cancelar") { app.queue.cancel(job.id) }
                } else if job.status != .done {
                    Button("Tentar de novo") { app.queue.retry(job.id) }
                }
                if let output = job.outputPath {
                    Button("Mostrar") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output)]) }
                }
                Button(showLog ? "Ocultar registro" : "Registro") { showLog.toggle() }.buttonStyle(.link).font(.caption)
            }
            .controlSize(.small)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contextMenu { Button("Abrir no estúdio") { app.open(URL(fileURLWithPath: job.mediaPath)) } }
    }

    private var icon: String {
        switch job.status {
        case .pending: "clock"
        case .running: "gearshape.2.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .interrupted: "pause.circle.fill"
        }
    }

    private var color: Color {
        switch job.status {
        case .pending: .secondary
        case .running: .accentColor
        case .done: Theme.translated
        case .failed: Theme.failure
        case .cancelled: .secondary
        case .interrupted: Theme.warning
        }
    }
}
