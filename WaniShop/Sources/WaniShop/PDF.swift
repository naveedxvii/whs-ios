import UIKit

@MainActor
enum Printables {
    /// Bill PDF sized to the paper width in Settings. Share it, then choose Print to use AirPrint.
    static func billPDF(_ sale: Sale, store: ShopStore) -> URL? {
        let mm: CGFloat = 72 / 25.4
        let paperMM = CGFloat(Double(store.setting("paper_mm")) ?? 80)
        let width = paperMM * mm
        let hasCustomer = !sale.cust.isEmpty || !sale.contact.isEmpty
        let height = (95 + 9 * CGFloat(sale.lines.count) + (hasCustomer ? 6 : 0)) * mm
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        let bold = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let body = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let small = UIFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        let total = sale.lines.reduce(0.0) { $0 + $1.p * Double($1.q) }
        let date = Date(timeIntervalSince1970: sale.t).formatted(date: .abbreviated, time: .shortened)

        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            var y: CGFloat = 8 * mm

            func draw(_ s: String, _ font: UIFont, _ align: NSTextAlignment) {
                let p = NSMutableParagraphStyle()
                p.alignment = align
                (s as NSString).draw(
                    in: CGRect(x: 3 * mm, y: y, width: width - 6 * mm, height: font.lineHeight + 2),
                    withAttributes: [.font: font, .paragraphStyle: p])
            }

            draw(store.setting("shop_name"), bold, .center); y += 6 * mm
            draw("Bill #\(sale.no)", small, .center); y += 4 * mm
            draw(date, small, .center); y += 4 * mm
            if !sale.cust.isEmpty { draw(sale.cust, small, .center); y += 4 * mm }
            if !sale.contact.isEmpty { draw(sale.contact, small, .center); y += 4 * mm }
            y += 3 * mm

            for line in sale.lines {
                draw(String(line.n.prefix(30)), body, .left); y += 4 * mm
                draw("\(line.q) x \(store.money(line.p))", body, .left)
                draw(store.money(line.p * Double(line.q)), body, .right); y += 5 * mm
            }
            y += 2 * mm

            draw("Subtotal", body, .left)
            draw(store.money(total), body, .right); y += 4 * mm
            if sale.disc > 0 {
                draw("Discount", body, .left)
                draw("-" + store.money(sale.disc), body, .right); y += 4 * mm
            }
            draw("Total", bold, .left)
            draw(store.money(sale.total), bold, .right); y += 8 * mm
            draw(store.setting("footer"), small, .center)
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bill-\(sale.no).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// A4 sheet of price labels with barcodes, 4 across and 11 down.
    static func labelsPDF(_ item: Item, count: Int, store: ShopStore) -> URL? {
        guard let code = validEAN(item.barcode) else { return nil }
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let labelW: CGFloat = 50 / 25.4 * 72
        let labelH: CGFloat = 26 / 25.4 * 72
        let cols = 4
        let perPage = cols * 11
        let barcode = eanImage(code)

        let nameFont = UIFont.systemFont(ofSize: 8, weight: .bold)
        let priceFont = UIFont.systemFont(ofSize: 9, weight: .regular)
        let center = NSMutableParagraphStyle()
        center.alignment = .center

        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let data = renderer.pdfData { ctx in
            for i in 0..<max(count, 1) {
                if i % perPage == 0 { ctx.beginPage() }
                let idx = i % perPage
                let col = CGFloat(idx % cols)
                let row = CGFloat(idx / cols)
                let cell = CGRect(x: 10 + col * labelW, y: 10 + row * labelH,
                                  width: labelW, height: labelH).insetBy(dx: 4, dy: 4)

                (item.name as NSString).draw(
                    in: CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: 11),
                    withAttributes: [.font: nameFont, .paragraphStyle: center])
                (store.money(item.price) as NSString).draw(
                    in: CGRect(x: cell.minX, y: cell.minY + 11, width: cell.width, height: 12),
                    withAttributes: [.font: priceFont, .paragraphStyle: center])

                let ih = cell.height - 26
                let iw = min(cell.width, ih * 240 / 140)
                barcode.draw(in: CGRect(x: cell.midX - iw / 2, y: cell.minY + 24, width: iw, height: ih))
            }
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("labels-\(item.barcode).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
