// RoutinesPanelView.swift — переиспользуемые вью вкладки «Рутины»: строка списка,
// детальная панель рутины (промпт/расписание/действия/история/диалог), строка
// прогона и лист прогона. Вкладка собирается в ContentView (сайдбар = список,
// detail = RoutineDetailPane). Источник истины — VPS (см. RoutinesViewModel).

import SwiftUI

// MARK: - Строка списка рутин

struct RoutineRowView: View {
    @ObservedObject var vm: RoutinesViewModel
    let routine: Routine

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(routine.enabled ? Color.green : Color.gray).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.name.isEmpty ? "(без имени)" : routine.name)
                    .fontWeight(.medium).lineLimit(1)
                Text(routine.cronHuman.isEmpty ? routine.cron : routine.cronHuman)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .tag(routine.id)
        .contextMenu {
            Button { Task { await vm.trigger(id: routine.id) } } label: {
                Label("Запустить сейчас", systemImage: "play.fill")
            }
            Button(role: .destructive) { Task { await vm.delete(id: routine.id) } } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }
}

// MARK: - Детали рутины (правая панель вкладки)

struct RoutineDetailPane: View {
    @ObservedObject var vm: RoutinesViewModel
    let routineID: String
    var onEdit: (Routine) -> Void

    @State private var askText = ""
    @State private var askHistory: [AgentChatMessage] = []
    @State private var asking = false
    @State private var selectedRun: RunRecord? = nil

    private var routine: Routine? { vm.routines.first { $0.id == routineID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let r = routine {
                    headerBlock(r)
                    Divider()
                    runsSection
                    Divider()
                    askSection(r)
                } else {
                    Text("Рутина не найдена").foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .task(id: routineID) { await vm.loadRuns(routineId: routineID, reset: true) }
        .sheet(item: $selectedRun) { run in RunDetailView(run: run) }
    }

    private func headerBlock(_ r: Routine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(r.name).font(.title3.bold())
                if !r.enabled {
                    Text("выключена").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.gray.opacity(0.2)).cornerRadius(4)
                }
            }
            Text(r.prompt).font(.callout).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                chip("calendar", r.cronHuman.isEmpty ? r.cron : r.cronHuman)
                if let next = r.nextRunAt { chip("arrow.right.circle", "след. \(shortTime(next))") }
                chip("globe", r.timezone)
            }

            HStack(spacing: 8) {
                Button { Task { await vm.trigger(id: r.id) } } label: {
                    Label("Запустить сейчас", systemImage: "play.fill")
                }.buttonStyle(.borderedProminent).disabled(vm.isWorking)
                Button { onEdit(r) } label: { Label("Изменить", systemImage: "pencil") }
                Button { Task { await vm.setEnabled(id: r.id, !r.enabled) } } label: {
                    Label(r.enabled ? "Выключить" : "Включить",
                          systemImage: r.enabled ? "pause.circle" : "play.circle")
                }
                Spacer()
                Button(role: .destructive) { Task { await vm.delete(id: r.id) } } label: {
                    Image(systemName: "trash")
                }.help("Удалить рутину")
            }
        }
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary.opacity(0.5)).cornerRadius(6)
    }

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("История прогонов").font(.headline)
            if vm.runs.isEmpty {
                Text("Прогонов ещё не было. Нажми «Запустить сейчас».")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(vm.runs) { run in
                    Button { Task { selectedRun = await vm.fullRun(run.id) ?? run } } label: {
                        RunRowView(run: run)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                if vm.runsNextCursor != nil {
                    Button("Показать ещё") { Task { await vm.loadRuns(routineId: routineID, reset: false) } }
                        .font(.callout)
                }
            }
        }
    }

    private func askSection(_ r: Routine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Диалог с агентом").font(.headline)
            Text("Спроси про результат последнего прогона.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(askHistory.enumerated()), id: \.offset) { _, m in
                HStack(alignment: .top, spacing: 6) {
                    Text(m.role == "user" ? "Вы" : "Агент").bold()
                        .frame(width: 44, alignment: .leading)
                    Text(MarkdownText.attributed(m.content)).textSelection(.enabled)
                    Spacer(minLength: 0)
                }.font(.callout)
            }
            HStack(spacing: 8) {
                TextField("Вопрос агенту…", text: $askText, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4)
                    .padding(8).background(.quaternary.opacity(0.5)).cornerRadius(8)
                Button {
                    let q = askText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !q.isEmpty else { return }
                    askText = ""; asking = true
                    Task {
                        let reply = await vm.ask(routineId: r.id, runId: vm.runs.first?.id,
                                                 message: q, history: askHistory)
                        askHistory.append(AgentChatMessage(role: "user", content: q))
                        if let reply { askHistory.append(AgentChatMessage(role: "assistant", content: reply.reply)) }
                        asking = false
                    }
                } label: {
                    if asking { ProgressView().controlSize(.small) }
                    else { Image(systemName: "paperplane.fill") }
                }.disabled(asking)
            }
        }
    }
}

struct RunRowView: View {
    let run: RunRecord
    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(shortTime(run.startedAt)).font(.callout)
                HStack(spacing: 6) {
                    Text(run.status.title)
                    if run.usage.totalTokens > 0 { Text("· \(run.usage.totalTokens) ток.") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    private var statusDot: some View {
        let color: Color = {
            switch run.status {
            case .ok: return .green
            case .running: return .blue
            case .error, .timeout: return .red
            case .skippedOverlap, .missed: return .orange
            case .unknown: return .gray
            }
        }()
        return Circle().fill(color).frame(width: 8, height: 8)
    }
}

// MARK: - Детали прогона (лист)

struct RunDetailView: View {
    let run: RunRecord
    @Environment(\.dismiss) private var dismiss

    private var statusColor: Color {
        switch run.status {
        case .ok: return .green
        case .running: return .blue
        case .error, .timeout: return .red
        case .skippedOverlap, .missed: return .orange
        case .unknown: return .gray
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Прогон").font(.headline)
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Шапка: статус-пилюля + метаданные
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Circle().fill(statusColor).frame(width: 8, height: 8)
                            Text(run.status.title).font(.callout.weight(.medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(statusColor.opacity(0.12)).cornerRadius(8)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(shortTime(run.startedAt)).font(.callout)
                            HStack(spacing: 6) {
                                if run.usage.totalTokens > 0 { Text("\(run.usage.totalTokens) ток.") }
                                if let cost = run.usage.costUsd { Text(String(format: "· $%.4f", cost)) }
                                Label("локально", systemImage: "internaldrive")
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    if let err = run.error, !err.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text(err).font(.callout)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08)).cornerRadius(10)
                    }

                    // Результат
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Результат").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        if run.outputMarkdown.isEmpty {
                            Text("Результата нет.").foregroundStyle(.secondary).italic()
                        } else {
                            Text(MarkdownText.attributed(run.outputMarkdown))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))

                    if !run.toolTranscript.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Инструменты (\(run.toolTranscript.count))")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(Array(run.toolTranscript.enumerated()), id: \.offset) { _, t in
                                HStack(spacing: 6) {
                                    Image(systemName: t.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(t.ok ? .green : .red).font(.caption)
                                    Text(t.name).font(.caption.monospaced())
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .padding()
            }
        }
        .frame(width: 640, height: 580)
    }
}

// MARK: - Утилиты

/// Короткое локальное время из ISO-8601 (для UI).
func shortTime(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    guard let date else { return iso }
    let out = DateFormatter()
    out.dateFormat = "dd.MM HH:mm"
    return out.string(from: date)
}
