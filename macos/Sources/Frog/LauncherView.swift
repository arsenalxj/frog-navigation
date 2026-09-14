import AppKit
import FrogCore
import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var store: BookmarkStore

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                backdrop
                    .contentShape(Rectangle()).onTapGesture { model.backgroundClicked() }
                    .zIndex(-1)
                rootContent
                    .scaleEffect(model.presented ? 1 : (model.reduceMotion ? 1 : 1.08))
                    .opacity(model.presented ? 1 : 0)
                    .allowsHitTesting(model.visible)
                    .accessibilityHidden(!model.visible)
                    .zIndex(0)
                folderBackdrop.zIndex(1)
                searchBar
                    .padding(.top, max(35, model.metrics.size.height * 0.045))
                    .frame(width: model.metrics.size.width, height: model.metrics.size.height, alignment: .top)
                    .opacity(model.presented ? 1 : 0)
                    .allowsHitTesting(model.visible)
                    .accessibilityHidden(!model.visible)
                    .zIndex(10)
                if model.visible {
                    if let group = expandedFolder {
                        folder(group)
                            .transition(.asymmetric(insertion: .scale(scale: model.reduceMotion ? 1 : 0.12, anchor: UnitPoint(x: model.folderOrigin.x, y: model.folderOrigin.y)).combined(with: .opacity), removal: .scale(scale: model.reduceMotion ? 1 : 0.6).combined(with: .opacity)))
                            .zIndex(2)
                    }
                    if let item = model.dragItem {
                        BookmarkTile(item: item, model: model, iconSize: model.metrics.icon, requestIcons: false, floating: true)
                            .frame(width: model.metrics.cellWidth, height: model.metrics.icon + 50)
                            .scaleEffect(1.12).opacity(0.96)
                            .position(x: model.dragPoint.x, y: model.dragPoint.y + 16)
                            .allowsHitTesting(false).zIndex(20)
                    }
                    notices.zIndex(40)
                }
                // 随原生窗口一起隐藏，保留表单挂载及焦点；不单独切换 SwiftUI 的可见性。
                panelLayers.zIndex(30)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "launcher")
            .clipped()
            .onAppear { model.layoutChanged(geometry.size) }
            .onChange(of: geometry.size) { _, size in model.layoutChanged(size) }
            .onChange(of: model.query) { _, _ in model.queryChanged() }
            .onPreferenceChange(TileFramesKey.self) { model.frames = $0 }
        }
    }

    private var expandedFolder: BookmarkGroup? {
        guard model.visible, !model.searching, let folderID = model.folderID else { return nil }
        return model.document.groups.first(where: { $0.id == folderID })
    }

    private var folderIsOpen: Bool { expandedFolder != nil }

    private var folderBackdrop: some View {
        Color.black.opacity(folderIsOpen ? 0.1 : 0)
            .contentShape(Rectangle())
            .onTapGesture { model.backgroundClicked() }
            .allowsHitTesting(folderIsOpen)
            .accessibilityHidden(true)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }

    @ViewBuilder private var backdrop: some View {
        ZStack {
            if model.reduceTransparency { Color(nsColor: .windowBackgroundColor).overlay(.black.opacity(0.4)) }
            else if let image = model.wallpaper {
                GeometryReader { geometry in
                    Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                Color.black.opacity(0.22)
                Color.white.opacity(0.04)
            } else {
                NativeMaterial(material: .underWindowBackground)
                Color.black.opacity(0.22)
            }
        }.opacity(model.presented ? 1 : 0)
    }

    private var rootContent: some View {
        ZStack(alignment: .top) {
            if !model.searching || !model.searchPages[0].isEmpty {
                pageStack(pages: model.searching ? model.searchPages : model.rootPages, page: model.searching ? model.searchPage : model.rootPage, folder: false)
                    .frame(height: model.metrics.height)
                    .offset(y: model.metrics.top)
                    .opacity(folderIsOpen ? 0.16 : 1)
                    .blur(radius: folderIsOpen && !model.reduceMotion ? 3 : 0)
                    .animation(nil, value: folderIsOpen)
                    .allowsHitTesting(!folderIsOpen)
            } else {
                VStack(spacing: 9) {
                    Text("没有匹配的书签").font(.system(size: 21, weight: .light))
                    Text("按回车键打开网址或搜索 Google").font(.system(size: 13)).foregroundStyle(.white.opacity(0.68))
                }.foregroundStyle(.white).frame(maxWidth: .infinity).offset(y: model.metrics.size.height * 0.35)
            }
            PageDots(count: model.activePageCount, current: model.activePage) { model.setPage($0) }
                .position(x: model.metrics.centerX, y: model.metrics.dotsY)
                .opacity(folderIsOpen ? 0 : 1)
                .animation(nil, value: folderIsOpen)
                .allowsHitTesting(!folderIsOpen)
                .accessibilityHidden(folderIsOpen)
        }.frame(width: model.metrics.size.width, height: model.metrics.size.height, alignment: .top)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                InitialFocusTextField(placeholder: "搜索", text: $model.query, label: "搜索书签",
                                      font: .systemFont(ofSize: 13), color: .white, onSubmit: { model.submitSearch() },
                                      focusToken: model.modalVisible ? nil : model.focusRequest)
                    .fixedSize(horizontal: false, vertical: true)
                    .disabled(model.modalVisible)
                    .accessibilityLabel("搜索书签")
                if !model.query.isEmpty {
                    Button { model.query = ""; model.focusRequest += 1 } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.65)) }
                        .buttonStyle(.plain).accessibilityLabel("清空搜索")
                }
            }
            .padding(.horizontal, 10).frame(width: 240, height: 29)
            .background(.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.26), lineWidth: 0.65))
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            Button { model.showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white.opacity(0.86)).frame(width: 29, height: 29)
            }.buttonStyle(.plain).help("设置（⌘,）").accessibilityLabel("设置")
            Button { model.addBookmark() } label: {
                Image(systemName: "plus").font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white.opacity(0.86)).frame(width: 29, height: 29)
            }.buttonStyle(.plain).help("添加书签（⌘N）").accessibilityLabel("添加书签")
        }
        .offset(x: model.metrics.centerX - model.metrics.size.width / 2 + 39)
    }

    @ViewBuilder private func pageStack(pages: [[LaunchItem]], page: Int, folder: Bool) -> some View {
        let viewport = folder ? min(620, model.metrics.usableWidth - 80) : model.metrics.size.width
        let window = PageWindow(requestedPage: page, pageCount: pages.count)
        ZStack(alignment: .top) {
            ForEach(Array(window.indices), id: \.self) { index in
                grid(items: pages[index], folder: folder, visible: index == window.current)
                    .frame(width: viewport)
                    .offset(x: CGFloat(index - window.current) * viewport + ((folder || model.folderID == nil || model.searching) ? model.pageOffset : 0) + (folder ? 0 : model.metrics.centerX - model.metrics.size.width / 2))
                    .accessibilityHidden(index != window.current)
            }
        }
        .frame(width: viewport)
        .padding(.vertical, 12)
        .clipped()
        .padding(.vertical, -12)
    }

    private func grid(items: [LaunchItem], folder: Bool, visible: Bool) -> some View {
        let columns = folder ? 3 : model.metrics.columns
        let cellWidth = folder ? min(620, model.metrics.usableWidth - 80) / 3 : model.metrics.cellWidth
        let cellHeight = folder ? min(146, (model.metrics.usableHeight - 300) / 3) : model.metrics.cellHeight
        let rows = folder ? 3 : model.metrics.rows
        return ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { model.backgroundClicked() }
            ForEach(items) { item in
                let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
                cell(item, folder: folder, requestIcons: visible)
                    .frame(width: cellWidth, height: cellHeight, alignment: .top)
                    .position(x: (CGFloat(index % columns) + 0.5) * cellWidth,
                              y: (CGFloat(index / columns) + 0.5) * cellHeight)
            }
        }
        .frame(width: cellWidth * CGFloat(columns), height: cellHeight * CGFloat(rows), alignment: .topLeading)
    }

    @ViewBuilder private func cell(_ item: LaunchItem, folder: Bool, requestIcons: Bool) -> some View {
        let iconSize = folder ? min(84, model.metrics.icon) : model.metrics.icon
        Button { model.activate(item) } label: {
            BookmarkTile(item: item, model: model, iconSize: iconSize, requestIcons: requestIcons)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(model.dragItem?.id == item.id ? 0 : 1)
        .accessibilityLabel(item.title)
        .contextMenu { BookmarkContextMenu(item: item, model: model) }
        .overlay(alignment: .top) {
            if model.editing && item.movable && model.dragItem?.id != item.id {
                Button { model.requestDelete(item) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(white: 0.25)).frame(width: 23, height: 23)
                        .background(.white.opacity(0.93), in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                }.buttonStyle(.plain).offset(x: -iconSize / 2, y: -3).accessibilityLabel("删除\(item.title)")
            }
        }
        .background(frameReader(item, folder: folder))
    }
    private func frameReader(_ item: LaunchItem, folder: Bool) -> some View {
        GeometryReader { proxy in Color.clear.preference(key: TileFramesKey.self, value: ["\(folder ? "folder" : "root")::\(item.id)": proxy.frame(in: .named("launcher"))]) }
    }

    private func folder(_ group: BookmarkGroup) -> some View {
        let width = min(620, model.metrics.usableWidth - 80)
        let height = min(438, model.metrics.usableHeight - 300)
        return ZStack {
            VStack(spacing: 20) {
                if model.renamingID == group.id {
                    VStack(spacing: 6) {
                        InitialFocusTextField(placeholder: "文件夹名称", text: $model.renameText, label: "文件夹名称",
                                              font: .systemFont(ofSize: 29, weight: .light), color: .white, alignment: .center,
                                              onSubmit: { model.saveRename() }, focusToken: model.renameFocusToken)
                            .disabled(model.renameFocusToken == nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: min(350, width - 40)).padding(.vertical, 4)
                            .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
                            .accessibilityLabel("文件夹名称")
                        if let error = model.renameError { Text(error).font(.system(size: 12)).foregroundStyle(.white) }
                    }
                } else {
                    Button { model.rename(group) } label: {
                        Text(group.name).font(.system(size: 29, weight: .light)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                            .lineLimit(1).padding(.horizontal, 20)
                    }.buttonStyle(.plain).help("重命名文件夹")
                }
                VStack(spacing: 8) {
                    pageStack(pages: model.folderPages, page: model.folderPage, folder: true).frame(height: height)
                    PageDots(count: model.folderPages.count, current: model.folderPage) { model.setPage($0) }
                        .padding(.bottom, 17)
                }
                .padding(.top, 26)
                .frame(width: width)
                .background {
                    if model.reduceTransparency { RoundedRectangle(cornerRadius: 30).fill(Color(white: 0.3)) }
                    else { RoundedRectangle(cornerRadius: 30).fill(.regularMaterial).environment(\.colorScheme, .dark) }
                }
                .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(0.18), lineWidth: 0.7))
                .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { model.folderFrame = proxy.frame(in: .named("launcher")) }
                        .onChange(of: proxy.frame(in: .named("launcher"))) { _, frame in model.folderFrame = frame }
                })
            }.offset(x: model.metrics.centerX - model.metrics.size.width / 2, y: -12 - model.metrics.dockInsets.bottom / 2)
        }
        // 保持屏幕坐标中的展开锚点；全屏遮罩由独立层立即切换。
        .frame(width: model.metrics.size.width, height: model.metrics.size.height)
    }

    @ViewBuilder private var panelLayers: some View {
        if model.showSettings || model.showEditor || model.deleteTarget != nil || (model.renamingID != nil && model.renamingID != model.folderID) {
            Color.black.opacity(0.28).contentShape(Rectangle()).onTapGesture {}
            if model.showSettings { SettingsPanel(model: model, store: store, login: model.login) }
            if model.showEditor { BookmarkEditorPanel(model: model, store: store) }
            if let target = model.deleteTarget { DeletePanel(model: model, target: target, busy: store.isBusy) }
            if model.renamingID != nil && model.renamingID != model.folderID { RenamePanel(model: model, busy: store.isBusy) }
        }
    }
    @ViewBuilder private var notices: some View {
        VStack {
            if let issue = store.issue {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(issue).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Button("重试") { Task { await store.reloadIfChanged() } }.disabled(store.isBusy)
                    Button("设置") { model.showSettings = true }
                }.padding(12).frame(maxWidth: 650).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
                    .padding(.top, 76)
            }
            Spacer()
            if let toast = model.toast {
                Text(toast).font(.system(size: 13)).multilineTextAlignment(.center)
                    .padding(.horizontal, 20).padding(.vertical, 11).frame(maxWidth: 650)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .padding(.bottom, 144)
            }
        }.allowsHitTesting(store.issue != nil)
    }
}

struct PageDots: View {
    let count: Int
    let current: Int
    let select: (Int) -> Void
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(1, count), id: \.self) { index in
                Button { select(index) } label: {
                    Circle().fill(.white.opacity(index == current ? 0.95 : 0.34)).frame(width: 7, height: 7).frame(width: 19, height: 23)
                }.buttonStyle(.plain).accessibilityLabel("第 \(index + 1) 页，共 \(count) 页").accessibilityAddTraits(index == current ? .isSelected : [])
            }
        }
    }
}

struct NativeMaterial: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = material; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}
