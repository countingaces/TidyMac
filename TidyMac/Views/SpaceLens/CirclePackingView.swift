import SwiftUI

struct CirclePackingView: View {
    let node: FileNode
    let selectedItems: Set<FileNode.ID>
    let onNodeTapped: (FileNode) -> Void

    private let maxCircles = 48

    var body: some View {
        GeometryReader { geo in
            let displayChildren = Array(node.children.prefix(maxCircles))
            let layout = computeLayout(children: displayChildren, in: geo.size)

            ZStack {
                ForEach(layout, id: \.node.id) { item in
                    CircleChip(
                        node: item.node,
                        radius: item.radius,
                        isSelected: selectedItems.contains(item.node.id),
                        onTap: { onNodeTapped(item.node) }
                    )
                    .position(item.center)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private struct PackedNode {
        let node: FileNode
        let center: CGPoint
        let radius: CGFloat
    }

    private func computeLayout(children: [FileNode], in size: CGSize) -> [PackedNode] {
        guard !children.isEmpty, size.width > 0, size.height > 0 else { return [] }

        let totalSize = max(Int64(1), children.reduce(Int64(0)) { $0 + max($1.size, 1) })

        let minDim = min(size.width, size.height)
        let maxPackRadius = minDim / 2 * 0.9
        let targetArea = .pi * maxPackRadius * maxPackRadius * 0.72

        let k = sqrt(targetArea / (.pi * CGFloat(totalSize)))
        let minRadius: CGFloat = 8

        let radii: [CGFloat] = children.map { child in
            max(minRadius, k * sqrt(CGFloat(max(child.size, 1))))
        }

        let sortedIndices = (0..<children.count).sorted { radii[$0] > radii[$1] }
        let sortedRadii = sortedIndices.map { radii[$0] }
        let packed = CirclePacker.pack(radii: sortedRadii)

        var minX = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var minY = CGFloat.infinity
        var maxY = -CGFloat.infinity
        for p in packed {
            minX = min(minX, p.center.x - p.radius)
            maxX = max(maxX, p.center.x + p.radius)
            minY = min(minY, p.center.y - p.radius)
            maxY = max(maxY, p.center.y + p.radius)
        }

        let spanX = max(0.001, maxX - minX)
        let spanY = max(0.001, maxY - minY)
        let fitScale = min(
            (size.width * 0.96) / spanX,
            (size.height * 0.96) / spanY
        )

        let packCenterX = (minX + maxX) / 2
        let packCenterY = (minY + maxY) / 2
        let targetCenterX = size.width / 2
        let targetCenterY = size.height / 2

        var result: [PackedNode] = []
        result.reserveCapacity(children.count)

        for (sortedIdx, originalIdx) in sortedIndices.enumerated() {
            let p = packed[sortedIdx]
            let center = CGPoint(
                x: (p.center.x - packCenterX) * fitScale + targetCenterX,
                y: (p.center.y - packCenterY) * fitScale + targetCenterY
            )
            result.append(PackedNode(
                node: children[originalIdx],
                center: center,
                radius: p.radius * fitScale
            ))
        }

        return result
    }
}

private struct CircleChip: View {
    let node: FileNode
    let radius: CGFloat
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(fillGradient)
                    .overlay(
                        Circle()
                            .stroke(
                                isSelected ? Color.accentColor : Color.white.opacity(0.35),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                    .shadow(
                        color: .black.opacity(isHovered ? 0.14 : 0.06),
                        radius: isHovered ? 6 : 3,
                        y: 2
                    )

                if radius > 22 {
                    VStack(spacing: 2) {
                        Text(displayName)
                            .font(.system(size: min(13, radius * 0.22), weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if radius > 42 {
                            Text(node.humanReadableSize)
                                .font(.system(size: min(11, radius * 0.16)))
                                .opacity(0.9)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, radius * 0.18)
                }
            }
            .frame(width: radius * 2, height: radius * 2)
            .scaleEffect(isHovered ? 1.025 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHovered)
        .help("\(displayName) — \(node.humanReadableSize)")
    }

    private var displayName: String {
        node.name.isEmpty ? node.url.lastPathComponent : node.name
    }

    private var fillGradient: LinearGradient {
        let base: Color = node.isDirectory
            ? ColorTheme.storage.primary
            : Color(red: 0.95, green: 0.55, blue: 0.33)
        return LinearGradient(
            colors: [base.opacity(0.85), base.opacity(0.55)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// Front-chain style circle packer. Places each new circle tangent to two
// existing circles at the position closest to the origin, skipping any
// placement that would overlap other circles. Falls back to a phyllotactic
// spiral if no tangent position is available.
private enum CirclePacker {
    struct Packed {
        var center: CGPoint
        var radius: CGFloat
    }

    static func pack(radii: [CGFloat]) -> [Packed] {
        guard !radii.isEmpty else { return [] }

        var circles: [Packed] = []

        circles.append(Packed(center: .zero, radius: radii[0]))
        guard radii.count > 1 else { return circles }

        circles.append(Packed(
            center: CGPoint(x: radii[0] + radii[1], y: 0),
            radius: radii[1]
        ))
        guard radii.count > 2 else { return circles }

        for i in 2..<radii.count {
            let r = radii[i]
            var best: (center: CGPoint, dist: CGFloat)?

            for a in 0..<circles.count {
                for b in (a + 1)..<circles.count {
                    guard let candidates = tangentCandidates(a: circles[a], b: circles[b], r: r) else { continue }

                    for candidate in candidates {
                        var overlap = false
                        for (idx, other) in circles.enumerated() where idx != a && idx != b {
                            let d = hypot(candidate.x - other.center.x, candidate.y - other.center.y)
                            if d + 0.001 < other.radius + r {
                                overlap = true
                                break
                            }
                        }
                        if overlap { continue }

                        let dist = hypot(candidate.x, candidate.y)
                        if best == nil || dist < best!.dist {
                            best = (candidate, dist)
                        }
                    }
                }
            }

            if let best {
                circles.append(Packed(center: best.center, radius: r))
            } else {
                let angle = CGFloat(i) * 2.399963229
                let avg = radii.reduce(0, +) / CGFloat(radii.count)
                let dist = avg * (2 + CGFloat(i) / 6)
                circles.append(Packed(
                    center: CGPoint(x: cos(angle) * dist, y: sin(angle) * dist),
                    radius: r
                ))
            }
        }

        return circles
    }

    private static func tangentCandidates(a: Packed, b: Packed, r: CGFloat) -> [CGPoint]? {
        let da = a.radius + r
        let db = b.radius + r
        let dx = b.center.x - a.center.x
        let dy = b.center.y - a.center.y
        let dab = hypot(dx, dy)

        guard dab > 0.0001 else { return nil }
        guard dab <= da + db else { return nil }
        guard dab >= abs(da - db) else { return nil }

        let cosA = (da * da + dab * dab - db * db) / (2 * da * dab)
        let clamped = max(-1, min(1, cosA))
        let sinA = sqrt(max(0, 1 - clamped * clamped))

        let ux = dx / dab
        let uy = dy / dab
        let px = -uy
        let py = ux

        let c1 = CGPoint(
            x: a.center.x + da * (clamped * ux + sinA * px),
            y: a.center.y + da * (clamped * uy + sinA * py)
        )
        let c2 = CGPoint(
            x: a.center.x + da * (clamped * ux - sinA * px),
            y: a.center.y + da * (clamped * uy - sinA * py)
        )

        return [c1, c2]
    }
}
