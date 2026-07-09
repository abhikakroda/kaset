import SwiftUI

/// Shared bottom area for both sidebars: source toggle above the profile section.
///
/// Used by `Sidebar` (YouTube Music) and `YouTubeSidebar` so the toggle and
/// account control render identically in both experiences.
struct SidebarFooterView: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.5)

            SourceToggleView()
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            SidebarProfileView()
                .padding(.bottom, 4)
        }
    }
}

#Preview {
    SidebarFooterView()
        .frame(width: 220)
}
