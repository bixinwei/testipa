import SwiftUI
import UIKit

// This file intentionally keeps the view hierarchy from OldOS/Notes.swift.
// Only the Core Data bindings are adapted to AppViewModel, and the original
// mail toolbar action is replaced by this app's local Wi-Fi share action.

struct OldOSNotesRootView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var showingDeleteConfirmation: Bool
    @State private var forwardOrBackward = false
    @State private var isEditingNote = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                OldOSNotesTitleBar(
                    title: viewModel.showingList ? "Notes (\(viewModel.notes.filter { !$0.text.isEmpty }.count))" : viewModel.currentNote.title,
                    isDestination: !viewModel.showingList,
                    isEditingNote: isEditingNote,
                    forwardOrBackward: forwardOrBackward,
                    backAction: {
                        isEditingNote = false
                        forwardOrBackward = true
                        withAnimation(.linear(duration: 0.28)) {
                            viewModel.showingList = true
                        }
                    },
                    newAction: {
                        forwardOrBackward = false
                        withAnimation(.linear(duration: 0.28)) {
                            viewModel.createNote()
                        }
                    }
                )
                .frame(
                    minWidth: geometry.size.width,
                    maxWidth: geometry.size.width,
                    minHeight: 60,
                    maxHeight: 60
                )
                .zIndex(1)

                if viewModel.showingList {
                    OldOSNotesMainView(
                        viewModel: viewModel,
                        openNote: { note in
                            forwardOrBackward = false
                            withAnimation(.linear(duration: 0.28)) {
                                viewModel.select(note)
                            }
                        }
                    )
                    .frame(width: geometry.size.width)
                    .transition(.asymmetric(
                        insertion: .move(edge: forwardOrBackward ? .leading : .trailing),
                        removal: .move(edge: forwardOrBackward ? .trailing : .leading)
                    ))
                    .clipped()
                } else {
                    OldOSNotesDestinationView(
                        viewModel: viewModel,
                        isEditingNote: $isEditingNote,
                        showingDeleteConfirmation: $showingDeleteConfirmation
                    )
                    .frame(width: geometry.size.width)
                    .transition(.asymmetric(
                        insertion: .move(edge: forwardOrBackward ? .leading : .trailing),
                        removal: .move(edge: forwardOrBackward ? .trailing : .leading)
                    ))
                    .clipped()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .compositingGroup()
        .clipped()
    }
}

struct OldOSNotesMainView: View {
    @ObservedObject var viewModel: AppViewModel
    let openNote: (Note) -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "M/d/yy"
        return formatter
    }()

    private var notes: [Note] {
        viewModel.notes
            .filter { !$0.text.isEmpty }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        Spacer().frame(height: 5)
                        ForEach(notes) { note in
                            Button(action: { openNote(note) }) {
                                VStack(spacing: 0) {
                                    Spacer()
                                    HStack {
                                        Text(note.title)
                                            .font(.custom("Noteworthy-Bold", fixedSize: 18))
                                            .foregroundColor(Color(red: 160/255, green: 92/255, blue: 62/255))
                                            .lineLimit(1)
                                            .padding(.leading, 12)
                                        Spacer()
                                        Text(Self.dateFormatter.string(from: note.modifiedAt))
                                            .font(.custom("Helvetica Neue Regular", fixedSize: 14))
                                            .foregroundColor(Color(red: 99/255, green: 115/255, blue: 142/255))
                                            .padding(.trailing, 12)
                                        Image("UITableNext")
                                            .padding(.trailing, 12)
                                    }
                                    Spacer()
                                    Rectangle()
                                        .fill(Color(red: 78/255, green: 90/255, blue: 130/255).opacity(0.3))
                                        .frame(width: geometry.size.width, height: 1)
                                }
                                .frame(height: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
            .overlay(
                VStack {
                    Image("NotesEdgeTop")
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width)
                        .clipped()
                    Spacer()
                    Image("NotesEdgeBottom")
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width)
                        .clipped()
                }
            )
            .frame(width: geometry.size.width)
        }
        .background(Image("NotesBody").resizable().scaledToFill())
    }
}

struct OldOSNotesDestinationView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isEditingNote: Bool
    @Binding var showingDeleteConfirmation: Bool
    @ObservedObject private var keyboard = OldOSKeyboardResponder()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    OldOSNotesMultilineTextView(
                        text: Binding(
                            get: { viewModel.text },
                            set: { viewModel.text = $0 }
                        ),
                        metadata: metadata,
                        isEditing: $isEditingNote
                    )
                    .padding(.bottom, keyboard.currentHeight)
                    .edgesIgnoringSafeArea(.bottom)
                }
                .overlay(
                    VStack {
                        Image("edgeTopMarginThin")
                            .resizable()
                            .scaledToFit()
                            .frame(width: geometry.size.width + 4)
                            .clipped()
                        Spacer()
                        Image("gradBottomMarginThin")
                            .resizable()
                            .scaledToFit()
                            .frame(width: geometry.size.width + 4)
                            .clipped()
                    }
                )
                .overlay(
                    VStack {
                        Spacer()
                        HStack(spacing: 0) {
                            Spacer()
                            Button(action: { viewModel.moveSelection(by: -1) }) {
                                Image("arrow left")
                                    .opacity(viewModel.canMovePrevious ? 1 : 0.5)
                            }
                            .disabled(!viewModel.canMovePrevious)
                            Spacer()
                            Button(action: {
                                if viewModel.server.isSharingEnabled {
                                    viewModel.stopSharing()
                                } else {
                                    viewModel.startSharing()
                                }
                            }) {
                                Image(systemName: viewModel.server.isSharingEnabled ? "wifi.slash" : "wifi")
                                    .font(.system(size: 24, weight: .regular))
                                    .foregroundColor(Color(red: 113/255, green: 93/255, blue: 81/255))
                                    .frame(width: 32, height: 32)
                            }
                            Spacer()
                            Button(action: { showingDeleteConfirmation = true }) {
                                Image("trash")
                            }
                            Spacer()
                            Button(action: { viewModel.moveSelection(by: 1) }) {
                                Image("arrow right")
                                    .opacity(viewModel.canMoveNext ? 1 : 0.5)
                            }
                            .disabled(!viewModel.canMoveNext)
                            Spacer()
                        }
                        .padding(.bottom, 15)
                    }
                )
            }
        }
        .background(Image("bodyMarginThin-568h").resizable().scaledToFill())
    }

    private var metadata: OldOSDestinationMetadata {
        let date = viewModel.currentNote.modifiedAt
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        let relativeDate: String
        if days == 0 {
            relativeDate = "Today"
        } else if days == 1 {
            relativeDate = "1 day ago"
        } else {
            relativeDate = "\(days) days ago"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d  h:mm a"
        return OldOSDestinationMetadata(relativeDate: relativeDate, timestamp: formatter.string(from: date))
    }
}

struct OldOSDestinationMetadata: Equatable {
    let relativeDate: String
    let timestamp: String
}

struct OldOSDestinationHeader: View {
    let metadata: OldOSDestinationMetadata

    var body: some View {
        HStack {
            Text(metadata.relativeDate)
                .font(.custom("Helvetica Neue Bold", fixedSize: 14))
                .foregroundColor(Color(red: 161/255, green: 93/255, blue: 68/255))
                .padding(.leading, 32)
            Spacer()
            Text(metadata.timestamp)
                .font(.custom("Helvetica Neue Regular", fixedSize: 14))
                .foregroundColor(Color(red: 161/255, green: 93/255, blue: 68/255))
                .padding(.trailing, 8)
        }
        .padding(.top, 10)
        .padding(.bottom, 15)
        .background(Color.clear)
    }
}

struct OldOSNotesMultilineTextView: UIViewRepresentable {
    @Binding var text: String
    let metadata: OldOSDestinationMetadata
    @Binding var isEditing: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isEditing: $isEditing)
    }

    func makeUIView(context: Context) -> DALinedTextView {
        let view = DALinedTextView()
        view.isScrollEnabled = true
        view.isEditable = true
        view.isUserInteractionEnabled = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.isOpaque = false
        view.overrideUserInterfaceStyle = .light
        view.font = UIFont(name: "Noteworthy-Bold", size: 19)
        view.textColor = .black
        view.delegate = context.coordinator
        view.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        view.tintColor = UIColor(red: 113/255, green: 93/255, blue: 81/255, alpha: 1)
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false

        let headerController = UIHostingController(rootView: OldOSDestinationHeader(metadata: metadata))
        let header = headerController.view!
        header.translatesAutoresizingMaskIntoConstraints = false
        header.backgroundColor = .clear
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leftAnchor.constraint(equalTo: view.leftAnchor),
            header.widthAnchor.constraint(equalTo: view.widthAnchor)
        ])
        context.coordinator.headerController = headerController

        view.textContainerInset = UIEdgeInsets(top: 40, left: 28, bottom: 30, right: 3)
        view.text = text
        return view
    }

    func updateUIView(_ uiView: DALinedTextView, context: Context) {
        context.coordinator.headerController?.rootView = OldOSDestinationHeader(metadata: metadata)
        if uiView.text != text {
            uiView.text = text
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var isEditing: Bool
        var headerController: UIHostingController<OldOSDestinationHeader>?

        init(text: Binding<String>, isEditing: Binding<Bool>) {
            _text = text
            _isEditing = isEditing
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            scrollView.setNeedsDisplay()
        }
    }
}

struct OldOSNotesTitleBar: View {
    let title: String
    let isDestination: Bool
    let isEditingNote: Bool
    let forwardOrBackward: Bool
    let backAction: () -> Void
    let newAction: () -> Void

    var body: some View {
        ZStack {
            Image("NotesTopBar").resizable()

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(title)
                        .font(.custom("Helvetica Neue Bold", fixedSize: 22))
                        .foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.21), radius: 0, x: 0, y: -1)
                        .lineLimit(1)
                        .id(title)
                        .frame(maxWidth: isDestination ? 200 : .infinity)
                    Spacer()
                }
                Spacer()
            }

            if isDestination {
                VStack {
                    Spacer()
                    HStack {
                        Button(action: backAction) {
                            ZStack {
                                Image("NotesBack")
                                    .frame(width: 55, height: 33)
                                    .scaledToFill()
                                HStack(alignment: .center) {
                                    Text("Notes")
                                        .foregroundColor(.white)
                                        .font(.custom("Helvetica Neue Bold", fixedSize: 13))
                                        .shadow(color: Color.black.opacity(0.45), radius: 0, x: 0, y: -0.6)
                                        .padding(.leading, 5)
                                        .offset(y: -1.1)
                                }
                            }
                            .padding(.leading, 5)
                        }
                        Spacer()
                    }
                    Spacer()
                }
            }

            HStack {
                Spacer()
                if isEditingNote {
                    OldOSNotesHeaderTextButton(title: "Done", action: dismissKeyboard)
                        .padding(.trailing, 5)
                } else {
                    OldOSNotesHeaderImageButton(imageName: "UIButtonBarPlus", action: newAction)
                        .padding(.trailing, 5)
                }
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

struct OldOSNotesHeaderImageButton: View {
    let imageName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image("header button")
                    .frame(width: 32, height: 32)
                    .scaledToFill()
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13)
                    .padding(.horizontal, 11)
            }
        }
        .frame(width: 32, height: 32)
    }
}

struct OldOSNotesHeaderTextButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image("header button")
                    .frame(width: 60, height: 32)
                    .scaledToFill()
                Text(title)
                    .font(.custom("Helvetica Neue Bold", fixedSize: 13.25))
                    .foregroundColor(.white)
                    .shadow(color: Color.black.opacity(0.75), radius: 1, x: 0, y: -0.25)
                    .padding(.horizontal, 11)
            }
        }
        .frame(width: 60, height: 32)
    }
}

struct OldOSNotesShareTitleBar: View {
    let closeAction: () -> Void

    var body: some View {
        ZStack {
            Image("NotesTopBar").resizable()
            Text("共享地址")
                .font(.custom("Helvetica Neue Bold", fixedSize: 22))
                .foregroundColor(.white)
                .shadow(color: Color.black.opacity(0.21), radius: 0, x: 0, y: -1)
            HStack {
                Spacer()
                OldOSNotesHeaderTextButton(title: "完成", action: closeAction)
                    .padding(.trailing, 5)
            }
        }
        .frame(height: 60)
    }
}

final class OldOSKeyboardResponder: ObservableObject {
    @Published private(set) var currentHeight: CGFloat = 0
    private let notificationCenter: NotificationCenter

    init(center: NotificationCenter = .default) {
        notificationCenter = center
        center.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    @objc private func keyboardWillShow(notification: Notification) {
        if let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            currentHeight = frame.height
        }
    }

    @objc private func keyboardWillHide(notification: Notification) {
        currentHeight = 0
    }
}
