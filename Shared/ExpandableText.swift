import SwiftUI

/// Apple-Music–style expandable description.
///
/// Renders text clamped to `collapsedLineLimit` with a small uppercase
/// "MORE" toggle in the trailing-bottom corner. Tapping MORE opens a sheet
/// that shows the full text in a scrollable view, with an X close button
/// and the surfacing screen's `title` at the top — same pattern Apple Music
/// uses for album / artist editorial copy.
///
/// Only shows the toggle when truncation actually occurs (probed via a hidden
/// reference layout), so short blurbs render cleanly without dangling chrome.
struct ExpandableText: View {
    let text: String
    /// Used as the sheet's navigation title (typically the playlist / album
    /// / artist name the description is describing).
    var title: String = ""
    var collapsedLineLimit: Int = 3
    var font: Font = .subheadline
    var textColor: Color = .white.opacity(0.7)
    var toggleColor: Color = .white

    @State private var isPresented = false
    @State private var truncationDetected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                Text(text)
                    .font(font)
                    .foregroundStyle(textColor)
                    .lineLimit(collapsedLineLimit)
                    .multilineTextAlignment(.leading)

                // Hidden probe that detects if the text would overflow when
                // clamped — by comparing the height of an unclamped vs
                // clamped copy of the same string.
                Text(text)
                    .font(font)
                    .lineLimit(collapsedLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { clamped in
                            Text(text)
                                .font(font)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .background(
                                    GeometryReader { full in
                                        Color.clear.onAppear {
                                            truncationDetected = full.size.height > clamped.size.height + 1
                                        }
                                    }
                                )
                                .hidden()
                        }
                    )
                    .hidden()
            }

            if truncationDetected {
                HStack {
                    Spacer()
                    Button {
                        isPresented = true
                    } label: {
                        Text("MORE")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(toggleColor)
                            .kerning(0.5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $isPresented) {
            ExpandedTextSheet(text: text, title: title)
        }
    }
}

/// The modal Apple-Music–style fullscreen reader presented when the user
/// taps "MORE". Scrollable body with a top bar carrying an X dismiss button
/// and (optional) title.
private struct ExpandedTextSheet: View {
    let text: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(8)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
