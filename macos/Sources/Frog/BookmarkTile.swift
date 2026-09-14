import AppKit
import FrogCore
import FrogIcons
import SwiftUI

struct TileFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}

struct BookmarkTile: View {
    let item: LaunchItem
    @ObservedObject var model: LauncherModel
    let iconSize: CGFloat
    let requestIcons: Bool
    var floating = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !model.editing || model.reduceMotion || !model.visible || !item.movable || floating || !requestIcons)) { context in
            let angle = model.editing && !model.reduceMotion && item.movable && !floating && requestIcons ? sin(context.date.timeIntervalSinceReferenceDate * 24 + Double(item.id.utf8.first ?? 0)) * 1.5 : 0
            VStack(spacing: 9) {
                icon
                    .frame(width: iconSize, height: iconSize)
                    .rotationEffect(.degrees(angle))
                    .scaleEffect(model.mergeTarget == item.id ? 1.13 : 1)
                    .overlay {
                        if model.mergeTarget == item.id {
                            RoundedRectangle(cornerRadius: iconSize * 0.24)
                                .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                                .padding(-7)
                        }
                    }
                Text(item.title).font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.75), radius: 2, y: 1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(model.selection == item.id ? Color.white.opacity(0.23) : .clear, in: RoundedRectangle(cornerRadius: 4))
                if model.searching, case .bookmark(let bookmark) = item,
                   let group = model.document.groups.first(where: { $0.id == bookmark.groupId }) {
                    Text(group.name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        .padding(.top, -5)
                }
            }
        }
        .padding(.top, 5)
        .contentShape(Rectangle())
        .accessibilityHidden(floating)
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .bookmark(let bookmark):
            if model.mergeTarget == bookmark.id, case .bookmark(let source) = model.dragItem {
                folderPreview([bookmark, source])
            } else {
                WebsiteIcon(bookmark: bookmark, icons: model.icons, size: iconSize, shouldLoad: requestIcons && model.visible)
            }
        case .folder(let group):
            let bookmarks = Array(model.document.bookmarks(in: group.id).prefix(9))
            folderPreview(bookmarks)
        case .add:
            RoundedRectangle(cornerRadius: iconSize * 0.22)
                .fill(.white.opacity(model.reduceTransparency ? 0.6 : 0.26))
                .overlay(RoundedRectangle(cornerRadius: iconSize * 0.22).stroke(.white.opacity(0.35), lineWidth: 0.7))
                .overlay(Image(systemName: "plus").font(.system(size: iconSize * 0.43, weight: .thin)).foregroundStyle(.white.opacity(0.95)))
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        }
    }

    private func folderPreview(_ bookmarks: [Bookmark]) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: iconSize * 0.22)
                .fill(.white.opacity(model.reduceTransparency ? 0.6 : 0.32))
                .overlay(RoundedRectangle(cornerRadius: iconSize * 0.22).stroke(.white.opacity(0.38), lineWidth: 0.7))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: iconSize * 0.055), count: 3), spacing: iconSize * 0.055) {
                ForEach(0..<9, id: \.self) { index in
                    if index < bookmarks.count {
                        WebsiteIcon(bookmark: bookmarks[index], icons: model.icons, size: iconSize * 0.225, shouldLoad: requestIcons && model.visible)
                    } else { Color.clear.frame(width: iconSize * 0.225, height: iconSize * 0.225) }
                }
            }.padding(iconSize * 0.115)
        }.shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

struct WebsiteIcon: View {
    let bookmark: Bookmark
    @ObservedObject var icons: IconStore
    let size: CGFloat
    let shouldLoad: Bool
    @StateObject private var visibleIcon = VisibleIcon()

    private var tint: Color {
        let value = bookmark.url.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xffff }
        return Color(hue: Double(value % 360) / 360, saturation: 0.56, brightness: 0.74)
    }
    var body: some View {
        let _ = icons.revision
        ZStack {
            if let image = visibleIcon.image(for: bookmark.url) ?? icons.image(for: bookmark.url) {
                RoundedRectangle(cornerRadius: size * 0.22).fill(.white.opacity(0.95))
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22).fill(LinearGradient(colors: [tint.opacity(0.82), tint], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(String(bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .medium, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .shadow(color: .black.opacity(size > 30 ? 0.16 : 0), radius: 3, y: 2)
        .task(id: "\(bookmark.url)|\(shouldLoad)") { await visibleIcon.load(bookmark.url, from: icons, visible: shouldLoad) }
        .onDisappear { visibleIcon.release() }
    }
}

struct BookmarkContextMenu: View {
    let item: LaunchItem
    @ObservedObject var model: LauncherModel
    var body: some View {
        switch item {
        case .bookmark(let bookmark):
            Button("打开") { model.openURL(bookmark.url) }
            Button("复制链接") { model.copy(bookmark) }
            Divider()
            Button("编辑…") { model.edit(bookmark) }
            Button("刷新图标") { model.refreshIcon(bookmark) }
            Menu("移动到") {
                if bookmark.groupId != nil { Button("根目录") { model.move(bookmark, to: nil) }; Divider() }
                ForEach(model.document.groups.filter { $0.id != bookmark.groupId }.sorted { $0.order < $1.order }) { group in
                    Button(group.name) { model.move(bookmark, to: group.id) }
                }
                Button("新建文件夹…") { model.edit(bookmark); model.draft.location = "__new__" }
            }
            Divider()
            Button("整理书签") { model.editing = true }
            Button("删除…", role: .destructive) { model.requestDelete(item) }
        case .folder(let group):
            Button("打开文件夹") { model.openFolder(group) }
            Button("重命名…") { model.rename(group) }
            Button("整理书签") { model.editing = true }
            Divider()
            Button("删除文件夹…", role: .destructive) { model.requestDelete(item) }
                .disabled(!model.document.bookmarks(in: group.id).isEmpty)
        default: EmptyView()
        }
    }
}
