//
//  SelectVideoViewController.swift
//  iina+
//
//  Created by xjbeta on 2018/8/21.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Cocoa

class SelectVideoViewController: NSViewController {

    @IBOutlet var outlineView: NSOutlineView!
    var currentItem = 0 {
        didSet {
            guard oldValue != currentItem else { return }
            rootItems = buildRootItems()
            outlineView.reloadData()
            expandDefault()
        }
    }

    private var rootItems: [VideoTreeNode] = []

    var videoTreeNodes: [VideoTreeNode] = [] {
        didSet {
            videoInfos = videoTreeNodes.flattened
        }
    }

    private var videoInfos: [VideoTreeNode] = [] {
        didSet {
            rootItems = buildRootItems()
            outlineView.reloadData()
            expandDefault()
        }
    }

    var videoId = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
    }

    private func buildRootItems() -> [VideoTreeNode] {
        var items: [VideoTreeNode] = []
        if currentItem > 0, currentItem < leafItems.count {
            items.append(leafItems[currentItem])
        }
        items.append(contentsOf: videoInfos)
        return items
    }

    private func expandDefault() {
        let sections = rootItems.filter { !$0.isLeaf }

        if sections.count <= 1 {
            for item in sections {
                outlineView.expandItem(item)
            }
            return
        }

        guard currentItem > 0, currentItem < leafItems.count else {
            return
        }

        var offset = 0
        for section in sections {
            let count = section.children.filter(\.isLeaf).count
            if currentItem >= offset, currentItem < offset + count {
                outlineView.expandItem(section)
                return
            }
            offset += count
        }

        outlineView.expandItem(sections.first!)
    }

    var leafItems: [VideoTreeNode] {
        videoInfos.flatMap { $0.children.filter(\.isLeaf) }
    }

    private func displayString(for node: VideoTreeNode) -> String {
        var s = ""
        switch node.site {
        case .bilibili:
            if node.isCollection {
                s = node.title
            } else {
                s = "\(node.index)  \(node.title)"
            }
        case .bangumi:
            s = node.title
            if !node.longTitle.isEmpty {
                s += "  \(node.longTitle)"
            }
        case .douyu, .douyuVod, .huya, .biliLive, .cc163:
            s = (node.isLiving ? "🔥" : "") + node.title
        default:
            break
        }
        return s
    }
}

extension SelectVideoViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return rootItems.count
        } else if let node = item as? VideoTreeNode, !node.isLeaf {
            return node.children.filter(\.isLeaf).count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootItems[index]
        } else if let node = item as? VideoTreeNode, !node.isLeaf {
            return node.children.filter(\.isLeaf)[index]
        }
        return VideoTreeNode(title: "", id: "")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? VideoTreeNode else { return false }
        return !node.isLeaf
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? VideoTreeNode else { return nil }

        if node.isLeaf {
            let identifier = NSUserInterfaceItemIdentifier("SelectVideoCellView")
            guard let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView else {
                return nil
            }
            let s = displayString(for: node)
            cell.textField?.stringValue = s
            cell.textField?.toolTip = s
            return cell
        } else {
            let identifier = NSUserInterfaceItemIdentifier("SelectVideoGroupHeader")
            guard let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView else {
                return nil
            }
            cell.textField?.stringValue = node.title
            cell.textField?.toolTip = node.title
            return cell
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? VideoTreeNode else { return 24 }
        return node.isLeaf ? 34 : 32
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? VideoTreeNode, !node.isLeaf else { return true }
        if outlineView.isItemExpanded(item) {
            outlineView.animator().collapseItem(item)
        } else {
            outlineView.animator().expandItem(item)
        }
        return false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? VideoTreeNode,
              item.isLeaf else { return }

        guard let main = self.parent as? MainViewController else { return }

        main.selectTabItem(.search)

        var u = ""
        switch item.site {
        case .bilibili:
            if item.isCollection {
                u = "https://www.bilibili.com/video/\(item.bvid)"
            } else {
                u = "https://www.bilibili.com/video/\(item.bvid)?p=\(item.index)"
            }
        case .douyu, .douyuVod, .huya, .biliLive:
            u = item.url
        case .bangumi:
            u = "https://www.bilibili.com/bangumi/play/ep\(item.id)"
        case .cc163:
            u = item.url
            main.searchField.stringValue = u
            main.searchField.becomeFirstResponder()
            main.startSearchingUrl(u, directly: false)
            outlineView.deselectRow(row)
            return
        default:
            break
        }
        main.searchField.stringValue = u
        main.searchField.becomeFirstResponder()
        main.startSearchingUrl(u, directly: true)
        outlineView.deselectRow(row)
    }
}
