import SwiftUI

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
    }

    // MARK: - Боковая навигация по чатам

    private var sidebar: some View {
        List(selection: $vm.selectedChatID) {
            ForEach(vm.chats) { chat in
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left")
                        .foregroundColor(.secondary)
                    Text(chat.title)
                        .lineLimit(1)
                    Spacer()
                    if chat.isLoading {
                        ProgressView().controlSize(.mini)
                    }
                }
                .tag(chat.id)
                .contextMenu {
                    Button(role: .destructive) {
                        vm.deleteChat(chat.id)
                    } label: {
                        Label("Удалить чат", systemImage: "trash")
                    }
                }
            }
            .onDelete(perform: vm.deleteChats)
        }
        .navigationTitle("Чаты")
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItem {
                Button(action: vm.newChat) {
                    Label("Новый чат", systemImage: "square.and.pencil")
                }
                .help("Новый чат")
            }
        }
    }

    // MARK: - Детальная область

    @ViewBuilder
    private var detail: some View {
        if vm.selectedChat != nil {
            ChatDetailView(vm: vm)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Нет выбранного чата")
                    .foregroundColor(.secondary)
                Button("Создать чат", action: vm.newChat)
            }
            .frame(minWidth: 480, minHeight: 600)
        }
    }
}

/// Область одного чата: список сообщений + поле ввода.
struct ChatDetailView: View {
    @ObservedObject var vm: ChatViewModel

    private var messages: [ChatMessage] { vm.selectedChat?.messages ?? [] }
    private var isLoading: Bool { vm.selectedChat?.isLoading ?? false }
    private var errorText: String? { vm.selectedChat?.errorText }

    var body: some View {
        VStack(spacing: 0) {
            messagesList
            Divider()
            errorBar
            inputBar
        }
        .frame(minWidth: 480, minHeight: 600)
        .navigationTitle(vm.selectedChat?.title ?? "Чат")
    }

    // MARK: - Список сообщений

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        Text("Напиши сообщение, чтобы начать диалог с DeepSeek.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("DeepSeek печатает…")
                                .foregroundColor(.secondary)
                                .font(.callout)
                        }
                        .id("loading")
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: isLoading) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: vm.selectedChatID) { _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if isLoading {
                proxy.scrollTo("loading", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Строка ошибки

    @ViewBuilder
    private var errorBar: some View {
        if let error = errorText {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(error)
                    .font(.callout)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
        }
    }

    // MARK: - Поле ввода

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Сообщение…", text: $vm.input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(vm.send)

            Button(action: vm.send) {
                Image(systemName: "paperplane.fill")
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!vm.canSend)
        }
        .padding()
    }
}

/// «Пузырь» одного сообщения: user — справа, assistant — слева.
struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(message.content)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isUser ? Color.accentColor.opacity(0.9) : Color(nsColor: .windowBackgroundColor))
                .foregroundColor(isUser ? .white : .primary)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(isUser ? 0 : 0.25), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}
