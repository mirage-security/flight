import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState

    private var selectedWorktree: Worktree? {
        guard let id = state.selectedWorktreeID else { return nil }
        for project in state.projects {
            if let wt = project.worktrees.first(where: { $0.id == id }) {
                return wt
            }
        }
        return nil
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .frame(minWidth: 200)
        } detail: {
            Group {
                if let worktree = selectedWorktree {
                    ChatView(state: state, worktree: worktree)
                } else {
                    ContentUnavailableView(
                        "No Worktree Selected",
                        systemImage: "arrow.triangle.branch",
                        description: Text("Add a repo and create a worktree to get started.")
                    )
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .alert("Error", isPresented: $state.showingError) {
            Button("OK") {}
        } message: {
            Text(state.errorMessage ?? "An unknown error occurred.")
        }
        .fileImporter(
            isPresented: $state.showingAddRepo,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                state.addProject(path: url.path)
            }
        }
    }
}

